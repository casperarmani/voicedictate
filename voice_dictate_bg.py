#!/usr/bin/env python3
"""
Always-On Background Voice Dictation with Silero VAD + OpenAI Transcribe
=========================================================================

Continuously listens to your microphone using Silero VAD (Voice Activity
Detection) to detect when you start and stop speaking. Speech segments are
transcribed with OpenAI's speech-to-text models. The default is
`gpt-4o-mini-transcribe` for a strong speed/accuracy balance; switch to
`gpt-4o-transcribe` if you want the higher-quality option.

Set `OPENAI_API_KEY` in your environment, drop it into a `.env` file, or pass
`--api-key`.

Usage:
    uv run voice_dictate_bg.py                         # start with defaults
    uv run voice_dictate_bg.py --list-devices          # see available mics
    uv run voice_dictate_bg.py --vad-threshold 0.7     # stricter detection
    uv run voice_dictate_bg.py --model gpt-4o-transcribe
    uv run voice_dictate_bg.py --language fr           # transcribe French
    uv run voice_dictate_bg.py --no-paste              # clipboard only
"""

import io
import os
import re
import sys
import time
import wave
import signal
import subprocess
import threading
import argparse
import collections
import numpy as np
from concurrent.futures import Future, ThreadPoolExecutor
from queue import Queue, Empty
from pathlib import Path
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

# Audio format constants (must match Silero VAD requirements)
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "float32"

# Silero VAD chunk size: 512 samples at 16kHz = 32ms per chunk
VAD_CHUNK_SAMPLES = 512

# Defaults
DEFAULT_VAD_THRESHOLD = 0.5
DEFAULT_SILENCE_TIMEOUT = 0.25  # how much trailing silence ends an utterance
DEFAULT_MIN_SPEECH_DURATION = 0.2
DEFAULT_PRE_SPEECH_BUFFER = 0.5
# Default to the faster OpenAI transcription model; use gpt-4o-transcribe for
# the more accurate option.
DEFAULT_MODEL = "gpt-4o-mini-transcribe"
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
    """Always-on background voice dictation using Silero VAD + OpenAI STT."""

    def __init__(self, config: VADConfig, api_key: Optional[str] = None):
        self.config = config

        self.api_key = api_key or os.environ.get("OPENAI_API_KEY")
        if not self.api_key:
            has_legacy_groq_key = bool(os.environ.get("GROQ_API_KEY"))
            legacy_hint = (
                " Found GROQ_API_KEY in the environment/.env; rename it to "
                "OPENAI_API_KEY or add an OpenAI key separately."
                if has_legacy_groq_key
                else ""
            )
            raise ValueError(
                "OpenAI API key not found. Set OPENAI_API_KEY environment variable, "
                "add it to .env, or pass --api-key."
                + legacy_hint
            )
        self.client = OpenAI(api_key=self.api_key)

        # Load Silero VAD
        self.vad_model = None
        self._load_vad_model()

        # Pre-warm the OpenAI connection so the first real dictation doesn't pay
        # connection setup cost on the critical path.
        self._prewarm_connection()

        # Worker pool for speculative transcription (fire requests as soon as silence
        # is detected, before silence_timeout confirms the utterance is over).
        self.transcribe_executor = ThreadPoolExecutor(
            max_workers=4, thread_name_prefix="asr"
        )

        # Thread-safe queues
        self.audio_chunk_queue: Queue = Queue(maxsize=200)
        # Queue items are now Futures resolving to transcribed text.
        self.speech_segment_queue: "Queue[Optional[Future]]" = Queue(maxsize=10)

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

    def _prewarm_connection(self):
        """Fire a tiny request so the first real dictation skips cold-start work."""
        print("Pre-warming OpenAI transcription connection...")
        try:
            tiny = self._audio_to_wav_bytes(np.zeros(1600, dtype=np.float32))  # 100ms silence
            t0 = time.monotonic()
            self.client.audio.transcriptions.create(
                model=self.config.model,
                file=("warmup.wav", tiny, "audio/wav"),
                temperature=0.0,
                response_format="text",
                language=self.config.language or "en",
            )
            print(f"Pre-warmed in {(time.monotonic() - t0) * 1000:.0f} ms.")
        except Exception as e:
            print(f"Pre-warm failed (will warm on first real call): {e}")

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
        Reads audio chunks, runs Silero VAD, detects speech start/end.
        On the FIRST silence chunk after speech, fires a speculative OpenAI request so
        the network round-trip overlaps with the silence_timeout wait. If speech
        resumes within silence_timeout, the speculative result is discarded.
        """
        pre_speech_maxlen = max(
            1, int(self.config.pre_speech_buffer * SAMPLE_RATE / VAD_CHUNK_SAMPLES)
        )
        pre_speech_buffer = collections.deque(maxlen=pre_speech_maxlen)

        speech_chunks = []
        in_speech = False
        silence_start = None
        speech_start = None
        pending_future: Optional[Future] = None  # speculative transcription in flight

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
                        pending_future = None
                        speech_chunks = list(pre_speech_buffer)
                        pre_speech_buffer.clear()
                        speech_chunks.append(window.copy())
                        print("[VAD] Speech started")
                else:
                    # SPEECH state
                    speech_chunks.append(window.copy())

                    if not is_speech:
                        if silence_start is None:
                            # First silence chunk after speech — fire speculative request
                            silence_start = time.monotonic()
                            speech_duration = silence_start - speech_start
                            if speech_duration >= self.config.min_speech_duration:
                                full_audio = np.concatenate(speech_chunks)
                                pending_future = self.transcribe_executor.submit(
                                    self._transcribe_audio,
                                    self._audio_to_wav_bytes(full_audio),
                                )
                                print(f"[Spec] Submitted at silence start ({speech_duration:.1f}s)")
                        elif (time.monotonic() - silence_start) >= self.config.silence_timeout:
                            speech_duration = time.monotonic() - speech_start
                            print(f"[VAD] Speech ended ({speech_duration:.1f}s)")

                            if pending_future is not None:
                                # Fast path — speculative request likely already in flight
                                try:
                                    self.speech_segment_queue.put(
                                        pending_future, timeout=5.0
                                    )
                                except Exception:
                                    print("[VAD] Result queue full, dropping segment")
                            else:
                                # Speech was too short for speculation; transcribe now
                                full_audio = np.concatenate(speech_chunks)
                                future = self.transcribe_executor.submit(
                                    self._transcribe_audio,
                                    self._audio_to_wav_bytes(full_audio),
                                )
                                try:
                                    self.speech_segment_queue.put(future, timeout=5.0)
                                except Exception:
                                    print("[VAD] Result queue full, dropping segment")

                            # Reset state
                            in_speech = False
                            speech_chunks = []
                            silence_start = None
                            speech_start = None
                            pending_future = None
                            self.vad_model.reset_states()
                    else:
                        # Speech resumed before silence_timeout — discard speculation
                        if pending_future is not None:
                            print("[Spec] Discarded (speech resumed)")
                            pending_future = None
                        silence_start = None

        print("[VAD] Processing loop exiting.")

    def _transcription_loop(self):
        """
        Result-collection thread.
        Pops futures from the queue (already in flight thanks to speculation) and
        pastes the resolved text.
        """
        while not self.shutdown_event.is_set():
            try:
                future = self.speech_segment_queue.get(timeout=0.5)
            except Empty:
                continue

            if future is None:
                break

            try:
                t0 = time.monotonic()
                text = future.result(timeout=30.0)
                wait = time.monotonic() - t0
                cleaned_text = self._normalize_transcript_text(text)

                if cleaned_text:
                    print(f"\n{'=' * 40}")
                    print(f"  {cleaned_text}")
                    print(f"{'=' * 40}")
                    print(f"[Transcribe] waited {wait * 1000:.0f} ms after silence\n")

                    self._copy_to_clipboard(cleaned_text + " ")

                    if self.config.auto_paste:
                        self._simulate_paste()

                    self.segments_transcribed += 1
                else:
                    print("[Transcribe] Empty result, skipping.")

            except Exception as e:
                print(f"[Transcribe] Error: {e}")

        print("[Transcribe] Transcription loop exiting.")

    def _transcribe_audio(self, wav_bytes: bytes) -> str:
        """Transcribe in-memory WAV bytes via the OpenAI speech-to-text API."""
        params = {
            "model": self.config.model,
            "file": ("audio.wav", wav_bytes, "audio/wav"),
            "temperature": 0.0,
            "response_format": "text",
        }
        if self.config.language:
            params["language"] = self.config.language
        if self.config.prompt:
            params["prompt"] = self.config.prompt
        response = self.client.audio.transcriptions.create(**params)
        return response if isinstance(response, str) else response.text

    @staticmethod
    def _normalize_transcript_text(text: Optional[str]) -> str:
        """Collapse model-added newlines and extra whitespace for inline dictation."""
        if not text:
            return ""
        return re.sub(r"\s+", " ", text).strip()

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

    @staticmethod
    def _audio_to_wav_bytes(audio_data: np.ndarray) -> bytes:
        """Encode float32 numpy audio as 16-bit PCM WAV bytes (no disk roundtrip)."""
        audio_int16 = np.clip(audio_data * 32767, -32768, 32767).astype(np.int16)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(2)  # 16-bit = 2 bytes
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(audio_int16.tobytes())
        return buf.getvalue()

    def run(self):
        """Start the always-on background dictation pipeline. Blocks until Ctrl+C."""
        print("=" * 60)
        print("  Background Voice Dictation (Silero VAD + OpenAI Transcribe)")
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
                print("Listening... speak naturally. Press Ctrl+C to stop.\n")
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
        self.transcribe_executor.shutdown(wait=False, cancel_futures=True)

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
            f"OpenAI transcription model (default: {DEFAULT_MODEL}). "
            "Options: gpt-4o-mini-transcribe, gpt-4o-transcribe."
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
            "Pass an ISO code like en, fr, de, es, or ja."
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
        help="OpenAI API key (otherwise uses OPENAI_API_KEY env var or .env file)",
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

    def validate_input_device(device_index: Optional[int]) -> None:
        if device_index is None:
            return
        try:
            dev = sd.query_devices(device_index, "input")
        except Exception as exc:
            raise ValueError(
                f"Audio input device {device_index} is not available. "
                "Run with --list-devices to see current indices, or omit --device "
                "to auto-select the built-in mic."
            ) from exc
        if dev["max_input_channels"] <= 0:
            raise ValueError(
                f"Audio device {device_index} is not an input device. "
                "Run with --list-devices to see current input-capable devices."
            )

    # Auto-prefer the MacBook's built-in mic when no explicit device was passed,
    # because the Bose QC35 over Bluetooth tends to pick up an obnoxious squeal.
    device_index = args.device
    if device_index is None:
        for i, dev in enumerate(sd.query_devices()):
            if dev["max_input_channels"] > 0 and "macbook" in dev["name"].lower():
                device_index = i
                print(f"Auto-selected built-in mic: [{i}] {dev['name']}")
                break
    else:
        validate_input_device(device_index)

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
