#!/usr/bin/env python3
"""
Always-On Background Voice Dictation with Silero VAD + Groq Whisper API
=======================================================================

Continuously listens to your microphone using Silero VAD (Voice Activity Detection)
to detect when you start and stop speaking. Speech segments are transcribed via
Groq's hosted Whisper-large-v3-turbo, which typically returns in ~150-300 ms per
clip — substantially faster than OpenAI's transcription endpoints.

Requires a free Groq API key from https://console.groq.com — set GROQ_API_KEY in
your environment, drop it into a .env file, or pass --api-key.

Usage:
    uv run voice_dictate_bg.py                         # start with defaults
    uv run voice_dictate_bg.py --list-devices          # see available mics
    uv run voice_dictate_bg.py --vad-threshold 0.7     # stricter detection
    uv run voice_dictate_bg.py --model whisper-large-v3
    uv run voice_dictate_bg.py --language fr           # transcribe French
    uv run voice_dictate_bg.py --no-paste              # clipboard only
"""

import os
import sys
import time
import wave
import signal
import subprocess
import threading
import argparse
import collections
import tempfile
import numpy as np
from queue import Queue, Empty
from pathlib import Path
from datetime import datetime
from typing import Optional

# Try to load .env file if it exists
try:
    from dotenv import load_dotenv

    env_path = Path(__file__).parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)
except ImportError:
    pass

from openai import OpenAI
import pyperclip
import torch
import sounddevice as sd
from silero_vad import load_silero_vad

GROQ_BASE_URL = "https://api.groq.com/openai/v1"

# Audio format constants (must match Silero VAD requirements)
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "float32"

# Silero VAD chunk size: 512 samples at 16kHz = 32ms per chunk
VAD_CHUNK_SAMPLES = 512

# Defaults
DEFAULT_VAD_THRESHOLD = 0.5
DEFAULT_SILENCE_TIMEOUT = 0.4  # how much trailing silence ends an utterance
DEFAULT_MIN_SPEECH_DURATION = 0.3
DEFAULT_PRE_SPEECH_BUFFER = 0.5
# whisper-large-v3-turbo on Groq: ~150-300 ms per short clip, very accurate.
# Alternative: "whisper-large-v3" (slightly slower, marginally better accuracy).
DEFAULT_MODEL = "whisper-large-v3-turbo"
DEFAULT_LANGUAGE = "en"


class VADConfig:
    """Configuration for the VAD pipeline."""

    def __init__(
        self,
        vad_threshold: float = DEFAULT_VAD_THRESHOLD,
        silence_timeout: float = DEFAULT_SILENCE_TIMEOUT,
        min_speech_duration: float = DEFAULT_MIN_SPEECH_DURATION,
        pre_speech_buffer: float = DEFAULT_PRE_SPEECH_BUFFER,
        model: str = DEFAULT_MODEL,
        device_index: Optional[int] = None,
        auto_paste: bool = True,
        language: Optional[str] = DEFAULT_LANGUAGE,
        prompt: Optional[str] = None,
    ):
        self.vad_threshold = vad_threshold
        self.silence_timeout = silence_timeout
        self.min_speech_duration = min_speech_duration
        self.pre_speech_buffer = pre_speech_buffer
        self.model = model
        self.device_index = device_index
        self.auto_paste = auto_paste
        self.language = language
        self.prompt = prompt


class BackgroundDictation:
    """Always-on background voice dictation using Silero VAD + Groq Whisper API."""

    def __init__(self, config: VADConfig, api_key: Optional[str] = None):
        self.config = config

        # Groq client (OpenAI-compatible)
        self.api_key = api_key or os.environ.get("GROQ_API_KEY")
        if not self.api_key:
            raise ValueError(
                "Groq API key not found. Set GROQ_API_KEY environment variable, "
                "add it to .env, or pass --api-key. Get a free key at https://console.groq.com."
            )
        self.client = OpenAI(api_key=self.api_key, base_url=GROQ_BASE_URL)

        # Temp directory for the WAV files we hand to the API
        self.temp_dir = Path(tempfile.gettempdir()) / "voice_dictate"
        self.temp_dir.mkdir(exist_ok=True)

        # Load Silero VAD
        self.vad_model = None
        self._load_vad_model()

        # Thread-safe queues
        self.audio_chunk_queue: Queue = Queue(maxsize=200)
        self.speech_segment_queue: Queue = Queue(maxsize=10)

        # Shutdown coordination
        self.shutdown_event = threading.Event()

        # Pause/resume support (for future hotkey integration)
        self.paused = threading.Event()

        # Stats
        self.segments_transcribed = 0

    def _load_vad_model(self):
        """Load Silero VAD model."""
        print("Loading Silero VAD model...")
        torch.set_num_threads(1)
        self.vad_model = load_silero_vad()
        print("Silero VAD model loaded.")

    def _audio_callback(self, indata, frames, time_info, status):
        """
        Called by sounddevice on the audio thread for each block of mic input.
        Must be fast — just copy data into the queue.
        """
        if status:
            print(f"[Audio] {status}", file=sys.stderr)

        if self.shutdown_event.is_set():
            raise sd.CallbackAbort

        if self.paused.is_set():
            return

        audio_chunk = indata[:, 0].copy()
        try:
            self.audio_chunk_queue.put_nowait(audio_chunk)
        except Exception:
            pass  # Drop chunk if queue full — never block the audio thread

    def _vad_processing_loop(self):
        """
        VAD processing thread.
        Reads audio chunks, runs Silero VAD, detects speech start/end,
        and enqueues complete speech segments for transcription.
        """
        pre_speech_maxlen = max(
            1, int(self.config.pre_speech_buffer * SAMPLE_RATE / VAD_CHUNK_SAMPLES)
        )
        pre_speech_buffer = collections.deque(maxlen=pre_speech_maxlen)

        speech_chunks = []
        in_speech = False
        silence_start = None
        speech_start = None

        # Residual buffer for chunk alignment (sounddevice may deliver
        # different block sizes than VAD_CHUNK_SAMPLES)
        residual = np.array([], dtype=np.float32)

        while not self.shutdown_event.is_set():
            try:
                chunk = self.audio_chunk_queue.get(timeout=0.1)
            except Empty:
                continue

            if chunk is None:
                break

            residual = np.concatenate([residual, chunk])

            while len(residual) >= VAD_CHUNK_SAMPLES:
                window = residual[:VAD_CHUNK_SAMPLES]
                residual = residual[VAD_CHUNK_SAMPLES:]

                tensor = torch.from_numpy(window)
                with torch.no_grad():
                    confidence = self.vad_model(tensor, SAMPLE_RATE).item()

                is_speech = confidence >= self.config.vad_threshold

                if not in_speech:
                    # IDLE state
                    pre_speech_buffer.append(window.copy())

                    if is_speech:
                        in_speech = True
                        speech_start = time.monotonic()
                        silence_start = None
                        speech_chunks = list(pre_speech_buffer)
                        pre_speech_buffer.clear()
                        speech_chunks.append(window.copy())
                        print("[VAD] Speech started")
                else:
                    # SPEECH state
                    speech_chunks.append(window.copy())

                    if not is_speech:
                        if silence_start is None:
                            silence_start = time.monotonic()
                        elif (time.monotonic() - silence_start) >= self.config.silence_timeout:
                            speech_duration = time.monotonic() - speech_start
                            print(f"[VAD] Speech ended ({speech_duration:.1f}s)")

                            if speech_duration >= self.config.min_speech_duration:
                                full_audio = np.concatenate(speech_chunks)
                                try:
                                    self.speech_segment_queue.put(full_audio, timeout=5.0)
                                except Exception:
                                    print(
                                        "[VAD] Transcription queue full, dropping segment"
                                    )
                            else:
                                print(
                                    f"[VAD] Too short ({speech_duration:.1f}s < "
                                    f"{self.config.min_speech_duration}s), discarding"
                                )

                            # Reset state
                            in_speech = False
                            speech_chunks = []
                            silence_start = None
                            speech_start = None
                            self.vad_model.reset_states()
                    else:
                        silence_start = None

        print("[VAD] Processing loop exiting.")

    def _transcription_loop(self):
        """
        Transcription thread.
        Reads speech segments, saves as WAV, transcribes via Groq, and pastes.
        """
        while not self.shutdown_event.is_set():
            try:
                audio_data = self.speech_segment_queue.get(timeout=0.5)
            except Empty:
                continue

            if audio_data is None:
                break

            try:
                wav_path = self._save_wav(audio_data)
                duration = len(audio_data) / SAMPLE_RATE
                print(f"[Transcribe] Processing {duration:.1f}s of audio...")

                t0 = time.monotonic()
                text = self._transcribe_audio(wav_path)
                latency = time.monotonic() - t0

                if text and text.strip():
                    print(f"\n{'=' * 40}")
                    print(f"  {text}")
                    print(f"{'=' * 40}")
                    print(f"[Transcribe] {latency * 1000:.0f} ms\n")

                    self._copy_to_clipboard(text + " ")

                    if self.config.auto_paste:
                        time.sleep(0.1)
                        self._simulate_paste()

                    self.segments_transcribed += 1
                else:
                    print("[Transcribe] Empty result, skipping.")

                # Periodic cleanup
                if self.segments_transcribed % 5 == 0:
                    self._cleanup_old_recordings()

            except Exception as e:
                print(f"[Transcribe] Error: {e}")

        print("[Transcribe] Transcription loop exiting.")

    def _transcribe_audio(self, audio_file: Path) -> str:
        """Transcribe an audio file via the Groq Whisper API (OpenAI-compatible)."""
        with open(audio_file, "rb") as f:
            params = {
                "model": self.config.model,
                "file": f,
                "temperature": 0.0,
                "response_format": "text",
            }
            if self.config.language:
                params["language"] = self.config.language
            if self.config.prompt:
                params["prompt"] = self.config.prompt
            response = self.client.audio.transcriptions.create(**params)
        # response_format="text" returns a plain string
        return response if isinstance(response, str) else response.text

    def _copy_to_clipboard(self, text: str) -> None:
        """Copy text to the system clipboard."""
        try:
            pyperclip.copy(text)
        except Exception:
            subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)

    def _simulate_paste(self) -> None:
        """Simulate Cmd+V to paste clipboard content."""
        try:
            applescript = '''
            tell application "System Events"
                keystroke "v" using command down
            end tell
            '''
            subprocess.run(
                ["osascript", "-e", applescript],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError:
            print("Warning: Could not auto-paste. Check Terminal accessibility permissions.")

    def _save_wav(self, audio_data: np.ndarray) -> Path:
        """Save float32 numpy audio as 16-bit PCM WAV (what the Whisper API expects)."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        wav_path = self.temp_dir / f"bg_recording_{timestamp}.wav"

        audio_int16 = np.clip(audio_data * 32767, -32768, 32767).astype(np.int16)

        with wave.open(str(wav_path), "wb") as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(2)  # 16-bit = 2 bytes
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(audio_int16.tobytes())

        return wav_path

    def _cleanup_old_recordings(self, keep_last: int = 10) -> None:
        """Clean up old recording files."""
        try:
            recordings = sorted(
                self.temp_dir.glob("bg_recording_*.wav"),
                key=lambda f: f.stat().st_mtime,
                reverse=True,
            )
            for recording in recordings[keep_last:]:
                recording.unlink()
        except Exception:
            pass

    def run(self):
        """Start the always-on background dictation pipeline. Blocks until Ctrl+C."""
        print("=" * 60)
        print("  Background Voice Dictation (Silero VAD + Groq Whisper)")
        print("=" * 60)
        print(f"  Model:            {self.config.model}")
        print(f"  Language:         {self.config.language}")
        print(f"  VAD threshold:    {self.config.vad_threshold}")
        print(f"  Silence timeout:  {self.config.silence_timeout}s")
        print(f"  Min speech:       {self.config.min_speech_duration}s")
        print(f"  Pre-speech buf:   {self.config.pre_speech_buffer}s")
        print(f"  Auto-paste:       {self.config.auto_paste}")
        print(f"  Audio device:     {self.config.device_index or 'system default'}")
        print("=" * 60)
        print("Listening... speak naturally. Press Ctrl+C to stop.\n")

        vad_thread = threading.Thread(
            target=self._vad_processing_loop,
            name="vad-processor",
            daemon=True,
        )
        transcription_thread = threading.Thread(
            target=self._transcription_loop,
            name="transcriber",
            daemon=True,
        )
        vad_thread.start()
        transcription_thread.start()

        try:
            with sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                blocksize=VAD_CHUNK_SAMPLES * 2,
                device=self.config.device_index,
                callback=self._audio_callback,
            ):
                while not self.shutdown_event.is_set():
                    self.shutdown_event.wait(timeout=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            self._shutdown(vad_thread, transcription_thread)

    def _shutdown(self, vad_thread, transcription_thread):
        """Gracefully shut down all threads."""
        print("\nShutting down...")
        self.shutdown_event.set()

        self.audio_chunk_queue.put(None)
        self.speech_segment_queue.put(None)

        vad_thread.join(timeout=3.0)
        transcription_thread.join(timeout=10.0)

        print(f"Done. Transcribed {self.segments_transcribed} segment(s) this session.")


def main():
    """Entry point for background voice dictation."""
    parser = argparse.ArgumentParser(
        description="Always-on background voice dictation with Silero VAD",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Start with defaults
  uv run voice_dictate_bg.py

  # More sensitive detection
  uv run voice_dictate_bg.py --vad-threshold 0.3

  # Longer pause before ending utterance
  uv run voice_dictate_bg.py --silence-timeout 2.5

  # Specific audio device
  uv run voice_dictate_bg.py --device 2

  # No auto-paste, just copy to clipboard
  uv run voice_dictate_bg.py --no-paste

  # List audio devices
  uv run voice_dictate_bg.py --list-devices
        """,
    )

    parser.add_argument(
        "--model",
        "-m",
        type=str,
        default=DEFAULT_MODEL,
        help=(
            f"Groq Whisper model (default: {DEFAULT_MODEL}). "
            "Options: whisper-large-v3-turbo, whisper-large-v3, distil-whisper-large-v3-en."
        ),
    )
    parser.add_argument(
        "--vad-threshold",
        type=float,
        default=DEFAULT_VAD_THRESHOLD,
        help=f"VAD confidence threshold 0.0-1.0 (default: {DEFAULT_VAD_THRESHOLD})",
    )
    parser.add_argument(
        "--silence-timeout",
        type=float,
        default=DEFAULT_SILENCE_TIMEOUT,
        help=f"Seconds of silence to end utterance (default: {DEFAULT_SILENCE_TIMEOUT})",
    )
    parser.add_argument(
        "--min-speech",
        type=float,
        default=DEFAULT_MIN_SPEECH_DURATION,
        help=f"Minimum speech duration in seconds (default: {DEFAULT_MIN_SPEECH_DURATION})",
    )
    parser.add_argument(
        "--pre-buffer",
        type=float,
        default=DEFAULT_PRE_SPEECH_BUFFER,
        help=f"Pre-speech buffer in seconds (default: {DEFAULT_PRE_SPEECH_BUFFER})",
    )
    parser.add_argument(
        "--device",
        type=int,
        default=None,
        help="Audio input device index (default: system default). Use --list-devices to see options.",
    )
    parser.add_argument(
        "--no-paste",
        action="store_true",
        help="Don't auto-paste, just copy to clipboard",
    )
    parser.add_argument(
        "--language",
        "-l",
        type=str,
        default=DEFAULT_LANGUAGE,
        help=(
            f"Language code for transcription (default: {DEFAULT_LANGUAGE}). "
            "Whisper supports ~99 languages; pass an ISO code like en, fr, de, es, ja."
        ),
    )
    parser.add_argument(
        "--prompt",
        "-p",
        type=str,
        default=None,
        help="Optional prompt to bias transcription (e.g., domain vocabulary)",
    )
    parser.add_argument(
        "--api-key",
        type=str,
        default=None,
        help="Groq API key (otherwise uses GROQ_API_KEY env var or .env file)",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List available audio input devices and exit",
    )

    args = parser.parse_args()

    if args.list_devices:
        print("Available audio input devices:")
        print("-" * 50)
        devices = sd.query_devices()
        for i, dev in enumerate(devices):
            if dev["max_input_channels"] > 0:
                marker = " (DEFAULT)" if i == sd.default.device[0] else ""
                print(
                    f"  [{i}] {dev['name']} "
                    f"({dev['max_input_channels']}ch, {int(dev['default_samplerate'])}Hz)"
                    f"{marker}"
                )
        print("\nUse --device <index> to select a device.")
        sys.exit(0)

    # Auto-prefer the MacBook's built-in mic when no explicit device was passed,
    # because the Bose QC35 over Bluetooth tends to pick up an obnoxious squeal.
    device_index = args.device
    if device_index is None:
        for i, dev in enumerate(sd.query_devices()):
            if dev["max_input_channels"] > 0 and "macbook" in dev["name"].lower():
                device_index = i
                print(f"Auto-selected built-in mic: [{i}] {dev['name']}")
                break

    config = VADConfig(
        vad_threshold=args.vad_threshold,
        silence_timeout=args.silence_timeout,
        min_speech_duration=args.min_speech,
        pre_speech_buffer=args.pre_buffer,
        model=args.model,
        device_index=device_index,
        auto_paste=not args.no_paste,
        language=args.language,
        prompt=args.prompt,
    )

    bg = None

    def signal_handler(sig, frame):
        if bg is not None:
            bg.shutdown_event.set()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        bg = BackgroundDictation(config=config, api_key=args.api_key)
        bg.run()
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
