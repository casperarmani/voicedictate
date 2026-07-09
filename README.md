# Voice Dictate for macOS

**Always-on voice dictation with classic and Realtime OpenAI transcription modes that works system-wide.**

## What It Does

1. **Start listening** (via shortcut or terminal command)
2. **Just talk** — use local VAD (`classic`) or OpenAI server-side VAD (`realtime`)
3. **Text appears** wherever your cursor is — transcribed and pasted automatically
4. **Keep talking** — it keeps listening for your next utterance

No buttons to hold, no fixed timers. Works from **any app** — Chrome, Slack, Notes, Cursor, anywhere.

---

## Quick Setup

### 1. Install Dependencies
```bash
# Install required tools
brew install uv

# Navigate to project and install Python packages
cd ~/Desktop/voicedictate
uv sync
```

If you already had the project checked out before Realtime mode was added, run `uv sync` again to install the websocket dependency.

### 2. Add Your OpenAI API Key
Create a `.env` file in the project directory:
```bash
OPENAI_API_KEY=sk-your-key-here
```

### 3. Grant Permissions

**Microphone Access:**
- Allow when prompted on first run

**Accessibility Access (for auto-paste):**
- System Settings > Privacy & Security > Accessibility
- Add "Terminal" and toggle it ON

### 4. Test It
```bash
cd ~/Desktop/voicedictate
uv run voice_dictate_bg.py
```

This starts Realtime transcription mode by default. Speak a sentence, pause briefly, and your text should appear.

---

## How to Use

### From Terminal
```bash
cd ~/Desktop/voicedictate

# Start with system default mic in Realtime mode
uv run voice_dictate_bg.py

# Start in classic local VAD mode
uv run voice_dictate_bg.py --mode classic

# Start with a specific mic after checking indices
uv run voice_dictate_bg.py --device 1

# Clipboard only (no auto-paste)
uv run voice_dictate_bg.py --no-paste

# List available microphones
uv run voice_dictate_bg.py --list-devices
```

Press **Ctrl+C** to stop listening.

### From macOS Shortcuts (Toggle On/Off)

The included `shortcut_script.sh` works as a toggle — press your shortcut once to start, press again to stop.

**Set up a Shortcut:**
1. Open Shortcuts app (`Cmd+Space` > "Shortcuts")
2. Create a new shortcut, name it "Voice Dictate"
3. Add "Run Shell Script" action
4. Shell: `/bin/zsh`, Input: `No Input`
5. Paste the contents of `shortcut_script.sh`
6. Add to Touch Bar or assign a keyboard shortcut

---

## Configuration

### Modes
```bash
--mode realtime    # OpenAI Realtime transcription session + server-side VAD (default)
--mode classic     # Local Silero VAD + /audio/transcriptions
```

### Transcription Models
```bash
--model gpt-4o-mini-transcribe    # Fast, cheap (default)
--model gpt-4o-transcribe         # Best quality
```

### VAD Tuning
```bash
--vad-threshold 0.5      # Speech confidence 0.0-1.0 (default: 0.5)
--silence-timeout 0.25   # Seconds of silence to end utterance (default: 0.25)
--min-speech 0.2         # Minimum speech duration in seconds (default: 0.2)
```

`--vad-threshold`, `--silence-timeout`, and `--pre-buffer` map to OpenAI `server_vad` settings in Realtime mode.

### Languages
```bash
--language en    # English
--language es    # Spanish
--language fr    # French
```

### Audio Devices
```bash
# List available devices
uv run voice_dictate_bg.py --list-devices

# Use a specific device by index
uv run voice_dictate_bg.py --device 1    # Example explicit input device
uv run voice_dictate_bg.py --device 0    # Another example
```

All of these can also be set in `shortcut_script.sh` for the shortcut workflow.

---

## Troubleshooting

### Auto-paste not working
- Grant Terminal accessibility permissions
- System Settings > Privacy & Security > Accessibility > Add Terminal

### Wrong microphone / fuzzy audio
- Bluetooth headsets can switch to low-quality HFP mic mode
- Run without `--device` to let the app auto-select the built-in MacBook mic
- Use `--list-devices` if you want to force a specific input index

### "No audio recorded"
- Check microphone permissions in System Settings > Privacy & Security > Microphone

### Dictation stopped or froze mid-session
- Check the debug log: `tail -50 voice_dictate.log` (timestamped, includes reconnect activity)
- Realtime sessions auto-reconnect on network drops and are rotated roughly every
  20 minutes (during a quiet moment) so OpenAI's session-duration cap never cuts
  one off. If transcription pauses for a second or two and resumes, that was a
  reconnect — check the log if it never resumes.

## Project Files

```
voicedictate/
├── voice_dictate_bg.py    # Main app (classic + realtime dictation modes)
├── shortcut_script.sh     # macOS Shortcuts toggle script
├── pyproject.toml         # Dependencies
├── .env                   # Your API key
├── voice_dictate.log      # Timestamped runtime/debug log (auto-created)
├── .gitignore             # Git safety
└── README.md              # This file
```

---

## How It Works

### Classic Mode

The app uses a 3-thread pipeline:

1. **Audio Thread** — `sounddevice` streams mic input continuously
2. **VAD Thread** — Silero VAD (a neural network) analyzes each 32ms audio chunk and detects speech vs. non-speech. Keyboard typing, AC, fans, etc. are ignored — only human voice triggers it.
3. **Transcription Thread** — On the first silence chunk after speech, the app starts a speculative OpenAI transcription request so network latency overlaps the trailing-silence wait. Once the utterance is confirmed finished, the resolved text is pasted into the active app.

### Realtime Mode

The app opens an OpenAI Realtime transcription session, streams microphone audio continuously, lets OpenAI server-side VAD detect turn boundaries, and pastes each final completed transcript in commit order.

A supervisor loop keeps the session alive indefinitely:
- Any websocket drop (network blip, sleep/wake, server-side session cap) triggers an automatic reconnect with a freshly configured session.
- Healthy sessions are proactively rotated after ~20 minutes, but only during a quiet moment, so the server's max-session-duration limit never kills one mid-sentence.
- A committed utterance whose transcript never arrives is skipped after 10s instead of blocking everything dictated after it.
- Clipboard/paste run on a dedicated thread with hard timeouts, so a hung `osascript` can never freeze the pipeline.
