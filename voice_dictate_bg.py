#!/usr/bin/env python3
"""
Always-On Background Voice Dictation with OpenAI Transcription
==============================================================

Supports two modes:
- `classic`: local Silero VAD + `/audio/transcriptions`
- `realtime`: OpenAI Realtime transcription sessions with server-side VAD

Realtime mode is supervised: if the websocket drops (network blip, OpenAI's
max-session-duration cap, laptop sleep), a fresh session is opened
automatically. Long-lived sessions are also rotated proactively during a quiet
moment so the server never cuts one off mid-sentence.

The default speech-to-text model is `gpt-4o-mini-transcribe` for a strong
speed/accuracy balance; switch to `gpt-4o-transcribe` if you want the
higher-quality option.

Set `OPENAI_API_KEY` in your environment, drop it into a `.env` file, or pass
`--api-key`.

A timestamped debug log is appended to `voice_dictate.log` next to this script
(disable with `--no-log-file`).

Usage:
    uv run voice_dictate_bg.py                         # start Realtime STT
    uv run voice_dictate_bg.py --mode classic          # local Silero VAD mode
    uv run voice_dictate_bg.py --list-devices          # see available mics
    uv run voice_dictate_bg.py --vad-threshold 0.7     # stricter detection
    uv run voice_dictate_bg.py --model gpt-4o-transcribe
    uv run voice_dictate_bg.py --language fr           # transcribe French
    uv run voice_dictate_bg.py --no-paste              # clipboard only
"""

import base64
import io
import logging
import logging.handlers
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
from queue import Queue, Empty, Full
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

from openai import OpenAI, AuthenticationError
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
DEFAULT_MODE = "realtime"
REALTIME_API_SAMPLE_RATE = 24000
REALTIME_CAPTURE_SAMPLE_RATE = SAMPLE_RATE
REALTIME_BLOCK_SAMPLES = VAD_CHUNK_SAMPLES * 2

# Realtime reliability tuning.
# OpenAI enforces a max Realtime session duration server-side, so sessions are
# rotated proactively at a quiet moment well before any cap can cut one off.
REALTIME_SESSION_RECYCLE_SEC = 20 * 60  # rotate session at this age when idle
REALTIME_SESSION_MAX_AGE_SEC = 28 * 60  # rotate even mid-activity at this age
REALTIME_IDLE_QUIET_SEC = 2.0  # no speech events for this long counts as idle
REALTIME_CONFIGURE_TIMEOUT_SEC = 15.0  # give up on a session that never confirms config
REALTIME_STALE_TRANSCRIPT_SEC = 10.0  # skip a committed utterance with no transcript
REALTIME_RECONNECT_BACKOFF_INITIAL_SEC = 0.5
REALTIME_RECONNECT_BACKOFF_MAX_SEC = 15.0
REALTIME_STALE_AUDIO_DROP_SEC = 5.0  # after an outage this long, drop buffered mic audio

SUBPROCESS_TIMEOUT_SEC = 5.0  # pbcopy/osascript must never hang the pipeline

log = logging.getLogger("voice_dictate")


def _setup_logging(log_file: Optional[str]) -> None:
    """Console output stays human-friendly; the file log gets timestamps + thread names."""
    log.setLevel(logging.DEBUG)
    log.propagate = False

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(message)s"))
    log.addHandler(console)

    if log_file:
        try:
            file_handler = logging.handlers.RotatingFileHandler(
                log_file, maxBytes=2_000_000, backupCount=2, encoding="utf-8"
            )
        except OSError as exc:
            log.warning(f"Could not open log file {log_file}: {exc}")
        else:
            file_handler.setLevel(logging.DEBUG)
            file_handler.setFormatter(
                logging.Formatter("%(asctime)s %(threadName)-20s %(levelname)-7s %(message)s")
            )
            log.addHandler(file_handler)
            # Mirror OpenAI SDK / websocket diagnostics into the file log too.
            for lib_name in ("openai", "websockets"):
                lib_logger = logging.getLogger(lib_name)
                lib_logger.setLevel(logging.INFO)
                lib_logger.addHandler(file_handler)

    def _log_thread_crash(hook_args) -> None:
        if hook_args.exc_type is SystemExit:
            return
        thread_name = hook_args.thread.name if hook_args.thread else "?"
        log.error(
            f"Uncaught exception in thread {thread_name}",
            exc_info=(hook_args.exc_type, hook_args.exc_value, hook_args.exc_traceback),
        )

    threading.excepthook = _log_thread_crash


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
        mode: str = DEFAULT_MODE,
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
        self.mode = mode


class OpenAIDictationBase:
    """Shared OpenAI/client and paste helpers for dictation modes."""

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
        # Bounded HTTP timeout so a hung transcription request can never pin a
        # worker thread indefinitely (websocket connections are unaffected).
        self.client = OpenAI(api_key=self.api_key, timeout=30.0, max_retries=2)

        # Shutdown coordination
        self.shutdown_event = threading.Event()

        # Pause/resume support (for future hotkey integration)
        self.paused = threading.Event()

        # Stats
        self.segments_transcribed = 0

    @staticmethod
    def _normalize_transcript_text(text: Optional[str]) -> str:
        """Collapse model-added newlines and extra whitespace for inline dictation."""
        if not text:
            return ""
        return re.sub(r"\s+", " ", text).strip()

    def _copy_to_clipboard(self, text: str) -> None:
        """Copy text to the system clipboard."""
        try:
            subprocess.run(
                ["pbcopy"],
                input=text.encode("utf-8"),
                check=True,
                timeout=SUBPROCESS_TIMEOUT_SEC,
            )
        except Exception:
            try:
                pyperclip.copy(text)
            except Exception as exc:
                log.warning(f"[Clipboard] Copy failed: {exc}")

    def _simulate_paste(self) -> None:
        """Simulate Cmd+V to paste clipboard content."""
        applescript = 'tell application "System Events" to keystroke "v" using command down'
        try:
            subprocess.run(
                ["osascript", "-e", applescript],
                check=True,
                capture_output=True,
                timeout=SUBPROCESS_TIMEOUT_SEC,
            )
        except subprocess.TimeoutExpired:
            log.warning(
                "[Paste] osascript timed out; skipped auto-paste (text is on the clipboard)."
            )
        except subprocess.CalledProcessError:
            log.warning(
                "[Paste] Could not auto-paste. Check Terminal accessibility permissions. "
                "Text is on the clipboard."
            )

    def _emit_transcript(self, cleaned_text: str, note: Optional[str] = None) -> None:
        """Show, copy, and (optionally) paste one finished transcript."""
        log.info(f"\n{'=' * 40}\n  {cleaned_text}\n{'=' * 40}")
        if note:
            log.info(note + "\n")

        self._copy_to_clipboard(cleaned_text + " ")

        if self.config.auto_paste:
            self._simulate_paste()

        self.segments_transcribed += 1


class BackgroundDictation(OpenAIDictationBase):
    """Classic always-on dictation using Silero VAD + `/audio/transcriptions`."""

    def __init__(self, config: VADConfig, api_key: Optional[str] = None):
        super().__init__(config=config, api_key=api_key)

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

    def _load_vad_model(self):
        """Load Silero VAD model."""
        log.info("Loading Silero VAD model...")
        torch.set_num_threads(1)
        self.vad_model = load_silero_vad()
        log.info("Silero VAD model loaded.")

    def _prewarm_connection(self):
        """Fire a tiny request so the first real dictation skips cold-start work."""
        log.info("Pre-warming OpenAI transcription connection...")
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
            log.info(f"Pre-warmed in {(time.monotonic() - t0) * 1000:.0f} ms.")
        except Exception as e:
            log.warning(f"Pre-warm failed (will warm on first real call): {e}")

    def _audio_callback(self, indata, frames, time_info, status):
        """
        Called by sounddevice on the audio thread for each block of mic input.
        Must be fast — just copy data into the queue.
        """
        if status:
            log.warning(f"[Audio] {status}")

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
                        log.info("[VAD] Speech started")
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
                                log.info(
                                    f"[Spec] Submitted at silence start ({speech_duration:.1f}s)"
                                )
                        elif (time.monotonic() - silence_start) >= self.config.silence_timeout:
                            speech_duration = time.monotonic() - speech_start
                            log.info(f"[VAD] Speech ended ({speech_duration:.1f}s)")

                            if pending_future is None:
                                # Speech was too short for speculation; transcribe now
                                full_audio = np.concatenate(speech_chunks)
                                pending_future = self.transcribe_executor.submit(
                                    self._transcribe_audio,
                                    self._audio_to_wav_bytes(full_audio),
                                )
                            try:
                                self.speech_segment_queue.put_nowait(pending_future)
                            except Full:
                                log.warning("[VAD] Result queue full, dropping segment")

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
                            log.info("[Spec] Discarded (speech resumed)")
                            pending_future = None
                        silence_start = None

        log.info("[VAD] Processing loop exiting.")

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
                    self._emit_transcript(
                        cleaned_text,
                        note=f"[Transcribe] waited {wait * 1000:.0f} ms after silence",
                    )
                else:
                    log.info("[Transcribe] Empty result, skipping.")

            except Exception as e:
                log.warning(f"[Transcribe] Error: {e}")

        log.info("[Transcribe] Transcription loop exiting.")

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
        log.info("=" * 60)
        log.info("  Background Voice Dictation (Silero VAD + OpenAI Transcribe)")
        log.info("=" * 60)
        log.info(f"  Model:            {self.config.model}")
        log.info(f"  Language:         {self.config.language}")
        log.info(f"  VAD threshold:    {self.config.vad_threshold}")
        log.info(f"  Silence timeout:  {self.config.silence_timeout}s")
        log.info(f"  Min speech:       {self.config.min_speech_duration}s")
        log.info(f"  Pre-speech buf:   {self.config.pre_speech_buffer}s")
        log.info(f"  Auto-paste:       {self.config.auto_paste}")
        log.info(f"  Audio device:     {self.config.device_index or 'system default'}")
        log.info("=" * 60)

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
                log.info("Listening... speak naturally. Press Ctrl+C to stop.\n")
                while not self.shutdown_event.is_set():
                    self.shutdown_event.wait(timeout=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            self._shutdown(vad_thread, transcription_thread)

    def _shutdown(self, vad_thread, transcription_thread):
        """Gracefully shut down all threads."""
        log.info("\nShutting down...")
        self.shutdown_event.set()

        try:
            self.audio_chunk_queue.put_nowait(None)
        except Full:
            pass
        try:
            self.speech_segment_queue.put_nowait(None)
        except Full:
            pass

        vad_thread.join(timeout=3.0)
        transcription_thread.join(timeout=10.0)
        self.transcribe_executor.shutdown(wait=False, cancel_futures=True)

        log.info(f"Done. Transcribed {self.segments_transcribed} segment(s) this session.")


class RealtimeDictation(OpenAIDictationBase):
    """Dictation using OpenAI Realtime transcription sessions with server-side VAD.

    A supervisor loop owns the websocket: any disconnect (server session cap,
    network drop, sleep/wake) is answered with a fresh, fully re-configured
    session, and healthy sessions are rotated proactively while idle so the
    server-side age cap never cuts one off mid-utterance.
    """

    def __init__(self, config: VADConfig, api_key: Optional[str] = None):
        super().__init__(config=config, api_key=api_key)
        self.audio_chunk_queue: Queue = Queue(maxsize=200)
        # Finished transcripts (text, committed_at) waiting to be pasted.
        self.output_queue: Queue = Queue(maxsize=50)

        self.connection_ready = threading.Event()  # first session configured (or fatal)
        self.fatal_error: Optional[Exception] = None

        self.connection_lock = threading.Lock()
        self.connection = None  # published to the sender only once configured
        self._pending_connection = None  # handshake done, session.update not confirmed
        self._recycle_requested = threading.Event()

        # Per-session transcript ordering and health state, guarded by state_lock.
        self.state_lock = threading.Lock()
        self.commit_order: collections.deque = collections.deque()
        self.committed_at: dict[str, float] = {}
        self.completed_transcripts: dict[str, str] = {}
        self.failed_items: set[str] = set()
        self.speech_active = False
        self.last_speech_event_at = 0.0
        self.session_started_at: Optional[float] = None
        self.configuring_since: Optional[float] = None
        self.session_generation = 0
        self.disconnected_at: Optional[float] = None

    def _selected_device_name(self) -> str:
        """Best-effort device name lookup for logging and noise-reduction hints."""
        try:
            if self.config.device_index is not None:
                return str(sd.query_devices(self.config.device_index)["name"])
            default_device = sd.default.device[0]
            if default_device is None or default_device < 0:
                return "system default"
            return str(sd.query_devices(default_device)["name"])
        except Exception:
            return "system default"

    def _noise_reduction_type(self) -> str:
        """Choose a default noise-reduction profile based on the selected mic."""
        name = self._selected_device_name().lower()
        if "macbook" in name or "built-in" in name or "internal" in name:
            return "far_field"
        return "near_field"

    def _build_realtime_session(self) -> dict:
        """Build the OpenAI Realtime transcription session config."""
        transcription: dict[str, str] = {"model": self.config.model}
        if self.config.language:
            transcription["language"] = self.config.language
        if self.config.prompt:
            transcription["prompt"] = self.config.prompt

        return {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": REALTIME_API_SAMPLE_RATE},
                    "noise_reduction": {"type": self._noise_reduction_type()},
                    "transcription": transcription,
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": self.config.vad_threshold,
                        "prefix_padding_ms": max(0, int(self.config.pre_speech_buffer * 1000)),
                        "silence_duration_ms": max(100, int(self.config.silence_timeout * 1000)),
                    },
                }
            },
        }

    def _audio_callback(self, indata, frames, time_info, status):
        """Copy audio data into the queue; the sender thread streams it to Realtime."""
        if status:
            log.warning(f"[Audio] {status}")

        if self.shutdown_event.is_set():
            raise sd.CallbackAbort

        if self.paused.is_set():
            return

        audio_chunk = indata[:, 0].copy()
        try:
            self.audio_chunk_queue.put_nowait(audio_chunk)
        except Exception:
            pass

    @staticmethod
    def _resample_audio(audio_data: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
        """Resample float32 mono audio using linear interpolation."""
        if src_rate == dst_rate or len(audio_data) == 0:
            return audio_data.astype(np.float32, copy=False)

        dst_length = max(1, round(len(audio_data) * dst_rate / src_rate))
        src_positions = np.arange(len(audio_data), dtype=np.float32)
        dst_positions = np.linspace(0, len(audio_data) - 1, num=dst_length, dtype=np.float32)
        return np.interp(dst_positions, src_positions, audio_data).astype(np.float32)

    @classmethod
    def _audio_chunk_to_base64(cls, audio_data: np.ndarray, src_rate: int) -> str:
        """Encode float32 audio to base64 PCM16 for Realtime input_audio_buffer.append."""
        resampled = cls._resample_audio(audio_data, src_rate=src_rate, dst_rate=REALTIME_API_SAMPLE_RATE)
        audio_int16 = np.clip(resampled * 32767, -32768, 32767).astype(np.int16)
        return base64.b64encode(audio_int16.tobytes()).decode("ascii")

    # ---------------------------------------------------------------- session lifecycle

    def _event_loop(self) -> None:
        """Supervisor: connect, run one session, and reconnect on any disconnect."""
        backoff = REALTIME_RECONNECT_BACKOFF_INITIAL_SEC

        while not self.shutdown_event.is_set():
            session_began = time.monotonic()
            planned = False
            try:
                with self.client.realtime.connect(
                    extra_query={"intent": "transcription"}
                ) as connection:
                    with self.connection_lock:
                        self._pending_connection = connection
                    with self.state_lock:
                        self.configuring_since = time.monotonic()

                    connection.session.update(session=self._build_realtime_session())

                    for event in connection:
                        self._handle_realtime_event(event, connection)
                        if self.shutdown_event.is_set():
                            break

                    if not self.shutdown_event.is_set() and not self._recycle_requested.is_set():
                        log.warning("[Realtime] Server closed the session.")
            except Exception as exc:
                if not self.shutdown_event.is_set():
                    if "openai[realtime]" in str(exc):
                        self.fatal_error = RuntimeError(
                            "OpenAI Realtime dependencies are missing. "
                            "Run `uv sync` in the project directory."
                        )
                    elif self._is_fatal_connect_error(exc):
                        self.fatal_error = exc

                    if self.fatal_error is not None:
                        log.error(f"[Realtime] Fatal error: {exc}")
                        self.connection_ready.set()
                    else:
                        log.warning(f"[Realtime] Connection dropped: {exc!r}")
            finally:
                planned = self._recycle_requested.is_set()
                self._recycle_requested.clear()
                self._teardown_session()

            if self.shutdown_event.is_set() or self.fatal_error is not None:
                break

            if planned:
                backoff = REALTIME_RECONNECT_BACKOFF_INITIAL_SEC
                log.info("[Realtime] Opening replacement session...")
                continue

            if (time.monotonic() - session_began) > 60.0:
                # The last session was healthy for a while; reset the backoff.
                backoff = REALTIME_RECONNECT_BACKOFF_INITIAL_SEC
            log.info(f"[Realtime] Reconnecting in {backoff:.1f}s...")
            self.shutdown_event.wait(timeout=backoff)
            backoff = min(backoff * 2.0, REALTIME_RECONNECT_BACKOFF_MAX_SEC)

        log.info("[Realtime] Event loop exiting.")

    def _teardown_session(self) -> None:
        """Unpublish the connection and reset per-session state between sessions."""
        with self.connection_lock:
            self.connection = None
            self._pending_connection = None

        with self.state_lock:
            lost = len(self.commit_order)
            self.commit_order.clear()
            self.committed_at.clear()
            self.completed_transcripts.clear()
            self.failed_items.clear()
            self.speech_active = False
            self.session_started_at = None
            self.configuring_since = None
            if self.disconnected_at is None:
                self.disconnected_at = time.monotonic()

        if lost:
            log.warning(f"[Realtime] Lost {lost} in-flight utterance(s) when the session ended.")

    def _activate_session(self, connection) -> None:
        """Publish a configured session to the audio sender."""
        stale_gap = None
        with self.state_lock:
            self.session_generation += 1
            generation = self.session_generation
            self.session_started_at = time.monotonic()
            self.configuring_since = None
            if self.disconnected_at is not None:
                gap = time.monotonic() - self.disconnected_at
                if gap > REALTIME_STALE_AUDIO_DROP_SEC:
                    stale_gap = gap
            self.disconnected_at = None

        if stale_gap is not None:
            # After a long outage the queued mic audio is ancient history — pasting
            # it now would be confusing. Drop it and start fresh.
            dropped = 0
            while True:
                try:
                    self.audio_chunk_queue.get_nowait()
                    dropped += 1
                except Empty:
                    break
            if dropped:
                seconds = dropped * REALTIME_BLOCK_SAMPLES / REALTIME_CAPTURE_SAMPLE_RATE
                log.info(
                    f"[Realtime] Dropped {seconds:.1f}s of buffered mic audio "
                    f"after {stale_gap:.0f}s offline."
                )

        with self.connection_lock:
            self.connection = connection
            self._pending_connection = None
        self.connection_ready.set()

        if generation == 1:
            log.info("Realtime transcription session ready.")
        else:
            log.info(f"[Realtime] Session #{generation} ready.")

    def _handle_realtime_event(self, event, connection) -> None:
        """Handle the subset of Realtime events relevant to transcription dictation."""
        event_type = event.type

        if event_type == "session.created":
            session_id = getattr(getattr(event, "session", None), "id", None)
            log.debug(f"[Realtime] Session created: {session_id}")
            return

        if event_type == "session.updated":
            with self.connection_lock:
                already_active = self.connection is connection
            if already_active:
                log.debug("[Realtime] Session config updated.")
            else:
                self._activate_session(connection)
            return

        if event_type == "input_audio_buffer.speech_started":
            with self.state_lock:
                self.speech_active = True
                self.last_speech_event_at = time.monotonic()
            log.info("[RT] Speech started")
            return

        if event_type == "input_audio_buffer.speech_stopped":
            with self.state_lock:
                self.speech_active = False
                self.last_speech_event_at = time.monotonic()
            log.info("[RT] Speech stopped")
            return

        if event_type == "input_audio_buffer.committed":
            now = time.monotonic()
            with self.state_lock:
                self.commit_order.append(event.item_id)
                self.committed_at[event.item_id] = now
                self.last_speech_event_at = now
                self.speech_active = False
                self._flush_ready_transcripts_locked()
            return

        if event_type == "conversation.item.input_audio_transcription.delta":
            return

        if event_type == "conversation.item.input_audio_transcription.completed":
            with self.state_lock:
                self.completed_transcripts[event.item_id] = event.transcript
                self._flush_ready_transcripts_locked()
            return

        if event_type == "conversation.item.input_audio_transcription.failed":
            log.warning(f"[Realtime] Transcription failed for item {event.item_id}")
            with self.state_lock:
                self.failed_items.add(event.item_id)
                self._flush_ready_transcripts_locked()
            return

        if event_type == "error":
            error = getattr(event, "error", None)
            code = getattr(error, "code", None)
            message = getattr(error, "message", None) or str(event)
            log.warning(f"[Realtime] Server error ({code}): {message}")
            if code in ("session_expired", "session_not_found"):
                self._recycle_requested.set()
                self._safe_close(connection)
            return

        log.debug(f"[Realtime] Unhandled event: {event_type}")

    @staticmethod
    def _is_fatal_connect_error(exc: Exception) -> bool:
        """Auth failures should stop the app instead of retrying forever."""
        if isinstance(exc, AuthenticationError):
            return True
        status = getattr(getattr(exc, "response", None), "status_code", None)
        return status in (401, 403)

    # ---------------------------------------------------------------- transcript output

    def _flush_ready_transcripts_locked(self) -> None:
        """Emit completed transcripts in commit order (caller holds state_lock).

        A committed utterance whose transcript never arrives is skipped after a
        timeout so it can't dam up everything dictated after it.
        """
        while self.commit_order:
            item_id = self.commit_order[0]

            if item_id in self.failed_items:
                self.failed_items.discard(item_id)
                self.commit_order.popleft()
                self.committed_at.pop(item_id, None)
                self.completed_transcripts.pop(item_id, None)
                continue

            transcript = self.completed_transcripts.get(item_id)
            if transcript is None:
                committed = self.committed_at.get(item_id)
                if committed is not None and (
                    time.monotonic() - committed
                ) > REALTIME_STALE_TRANSCRIPT_SEC:
                    log.warning(
                        f"[Realtime] No transcript for item {item_id} after "
                        f"{REALTIME_STALE_TRANSCRIPT_SEC:.0f}s; skipping it."
                    )
                    self.commit_order.popleft()
                    self.committed_at.pop(item_id, None)
                    continue
                break

            self.commit_order.popleft()
            self.completed_transcripts.pop(item_id, None)
            committed = self.committed_at.pop(item_id, None)
            try:
                self.output_queue.put_nowait((transcript, committed))
            except Full:
                log.warning("[Realtime] Output queue full; dropping a transcript.")

    def _flush_transcripts(self) -> None:
        with self.state_lock:
            self._flush_ready_transcripts_locked()

    def _output_loop(self) -> None:
        """Paste worker: keeps slow clipboard/osascript work off the websocket thread."""
        while not self.shutdown_event.is_set():
            try:
                item = self.output_queue.get(timeout=0.5)
            except Empty:
                continue

            if item is None:
                break

            transcript, committed = item
            cleaned_text = self._normalize_transcript_text(transcript)
            if not cleaned_text:
                log.info("[Realtime] Empty result, skipping.")
                continue

            note = None
            if committed is not None:
                note = f"[Realtime] waited {(time.monotonic() - committed) * 1000:.0f} ms after commit"
            self._emit_transcript(cleaned_text, note=note)

        log.info("[Realtime] Output loop exiting.")

    # ---------------------------------------------------------------- audio sender

    def _audio_sender_loop(self) -> None:
        """Stream queued mic audio to the current Realtime session.

        While no session is available the chunk is held (and the queue buffers
        behind it), so a quick reconnect loses little or no speech.
        """
        pending: Optional[np.ndarray] = None

        while not self.shutdown_event.is_set():
            if pending is None:
                try:
                    item = self.audio_chunk_queue.get(timeout=0.1)
                except Empty:
                    continue
                if item is None:
                    break
                pending = item

            with self.connection_lock:
                connection = self.connection

            if connection is None:
                self.shutdown_event.wait(timeout=0.05)
                continue

            try:
                connection.input_audio_buffer.append(
                    audio=self._audio_chunk_to_base64(
                        pending,
                        src_rate=REALTIME_CAPTURE_SAMPLE_RATE,
                    )
                )
                pending = None
            except Exception as exc:
                if self.shutdown_event.is_set():
                    break
                log.warning(f"[Realtime] Audio send failed ({exc!r}); waiting for a fresh session.")
                self._safe_close(connection)
                with self.connection_lock:
                    if self.connection is connection:
                        self.connection = None
                self.shutdown_event.wait(timeout=0.2)

        log.info("[Realtime] Audio sender exiting.")

    # ---------------------------------------------------------------- maintenance & run

    def _maintenance_tick(self) -> None:
        """Runs on the main thread every 0.5s: stale flushes and session rotation."""
        self._flush_transcripts()

        if self._recycle_requested.is_set():
            return

        now = time.monotonic()
        reason = None
        with self.state_lock:
            if self.configuring_since is not None:
                if (now - self.configuring_since) > REALTIME_CONFIGURE_TIMEOUT_SEC:
                    reason = "session setup timed out"
            elif self.session_started_at is not None:
                age = now - self.session_started_at
                idle = (
                    not self.speech_active
                    and not self.commit_order
                    and (now - self.last_speech_event_at) > REALTIME_IDLE_QUIET_SEC
                )
                if age > REALTIME_SESSION_MAX_AGE_SEC:
                    reason = f"session reached hard age cap ({age / 60:.0f} min)"
                elif age > REALTIME_SESSION_RECYCLE_SEC and idle:
                    reason = f"proactive session refresh ({age / 60:.0f} min)"

        if reason is not None:
            log.info(f"[Realtime] {reason}; rotating to a fresh session.")
            self._recycle_requested.set()
            self._close_connection()

    def _close_connection(self) -> None:
        """Close the active or in-setup Realtime websocket connection, if any."""
        with self.connection_lock:
            connection = self.connection or self._pending_connection
        self._safe_close(connection)

    @staticmethod
    def _safe_close(connection) -> None:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass

    def run(self):
        """Start the Realtime transcription dictation pipeline. Blocks until Ctrl+C."""
        log.info("=" * 60)
        log.info("  Background Voice Dictation (OpenAI Realtime Transcribe)")
        log.info("=" * 60)
        log.info(f"  Model:            {self.config.model}")
        log.info("  Mode:             realtime")
        log.info(f"  Language:         {self.config.language}")
        log.info(f"  VAD threshold:    {self.config.vad_threshold}")
        log.info(f"  Silence timeout:  {self.config.silence_timeout}s")
        log.info(f"  Pre-speech buf:   {self.config.pre_speech_buffer}s")
        log.info(f"  Auto-paste:       {self.config.auto_paste}")
        log.info(f"  Audio device:     {self.config.device_index or 'system default'}")
        log.info("=" * 60)

        event_thread = threading.Thread(
            target=self._event_loop,
            name="realtime-events",
            daemon=True,
        )
        sender_thread = threading.Thread(
            target=self._audio_sender_loop,
            name="realtime-audio-sender",
            daemon=True,
        )
        output_thread = threading.Thread(
            target=self._output_loop,
            name="realtime-output",
            daemon=True,
        )
        event_thread.start()
        sender_thread.start()
        output_thread.start()

        if not self.connection_ready.wait(timeout=15.0) and self.fatal_error is None:
            log.warning(
                "Realtime session not ready yet; will keep retrying in the background..."
            )
        if self.fatal_error is not None:
            raise self.fatal_error

        stream_warned = False
        try:
            with sd.InputStream(
                samplerate=REALTIME_CAPTURE_SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                blocksize=REALTIME_BLOCK_SAMPLES,
                device=self.config.device_index,
                callback=self._audio_callback,
            ) as stream:
                log.info("Listening... speak naturally. Press Ctrl+C to stop.\n")
                while not self.shutdown_event.is_set():
                    if self.fatal_error is not None:
                        raise self.fatal_error
                    self._maintenance_tick()
                    if not stream_warned and not stream.active and not self.shutdown_event.is_set():
                        log.warning(
                            "[Audio] Input stream stopped — the mic may have disconnected. "
                            "Toggle dictation off/on if transcription stops."
                        )
                        stream_warned = True
                    self.shutdown_event.wait(timeout=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            self._shutdown(event_thread, sender_thread, output_thread)

    def _shutdown(self, event_thread, sender_thread, output_thread):
        """Gracefully shut down the Realtime threads and websocket connection."""
        log.info("\nShutting down...")
        self.shutdown_event.set()
        try:
            self.audio_chunk_queue.put_nowait(None)
        except Full:
            pass
        try:
            self.output_queue.put_nowait(None)
        except Full:
            pass
        self._close_connection()

        sender_thread.join(timeout=3.0)
        event_thread.join(timeout=5.0)
        output_thread.join(timeout=5.0)

        log.info(f"Done. Transcribed {self.segments_transcribed} segment(s) this session.")


def main():
    """Entry point for background voice dictation."""
    parser = argparse.ArgumentParser(
        description="Always-on background voice dictation with classic and Realtime OpenAI STT",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Start with defaults (Realtime transcription mode)
  uv run voice_dictate_bg.py

  # Classic local Silero VAD mode
  uv run voice_dictate_bg.py --mode classic

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
        "--mode",
        choices=["classic", "realtime"],
        default=DEFAULT_MODE,
        help=(
            "Dictation mode. 'classic' uses local Silero VAD plus /audio/transcriptions; "
            f"'realtime' uses OpenAI Realtime transcription sessions (default: {DEFAULT_MODE})."
        ),
    )
    parser.add_argument(
        "--vad-threshold",
        type=float,
        default=DEFAULT_VAD_THRESHOLD,
        help=(
            f"VAD confidence threshold 0.0-1.0 (default: {DEFAULT_VAD_THRESHOLD}). "
            "In realtime mode this is passed to OpenAI server_vad."
        ),
    )
    parser.add_argument(
        "--silence-timeout",
        type=float,
        default=DEFAULT_SILENCE_TIMEOUT,
        help=(
            f"Seconds of silence to end utterance (default: {DEFAULT_SILENCE_TIMEOUT}). "
            "In realtime mode this controls server_vad silence_duration_ms."
        ),
    )
    parser.add_argument(
        "--min-speech",
        type=float,
        default=DEFAULT_MIN_SPEECH_DURATION,
        help=(
            f"Minimum speech duration in seconds (default: {DEFAULT_MIN_SPEECH_DURATION}). "
            "Used only in classic mode."
        ),
    )
    parser.add_argument(
        "--pre-buffer",
        type=float,
        default=DEFAULT_PRE_SPEECH_BUFFER,
        help=(
            f"Pre-speech buffer in seconds (default: {DEFAULT_PRE_SPEECH_BUFFER}). "
            "In realtime mode this maps to server_vad prefix padding."
        ),
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
        "--log-file",
        type=str,
        default=str(Path(__file__).parent / "voice_dictate.log"),
        help=(
            "Append a timestamped debug log to this file "
            "(default: voice_dictate.log next to the script)."
        ),
    )
    parser.add_argument(
        "--no-log-file",
        action="store_true",
        help="Disable the debug log file",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List available audio input devices and exit",
    )

    args = parser.parse_args()

    _setup_logging(None if args.no_log_file else args.log_file)

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
                log.info(f"Auto-selected built-in mic: [{i}] {dev['name']}")
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
        mode=args.mode,
    )

    app = None

    def signal_handler(sig, frame):
        if app is not None:
            app.shutdown_event.set()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        dictation_cls = RealtimeDictation if args.mode == "realtime" else BackgroundDictation
        app = dictation_cls(config=config, api_key=args.api_key)
        app.run()
    except ValueError as e:
        log.error(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        log.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
