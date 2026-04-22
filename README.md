# Voice Dictate for macOS

**Always-on voice dictation with OpenAI transcription models that works system-wide.**

## What It Does

1. **Start listening** (via shortcut or terminal command)
2. **Just talk** — Silero VAD automatically detects when you start and stop speaking
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
cd ~/Downloads/Voice_Dictate
uv sync
```

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
cd ~/Downloads/Voice_Dictate
uv run voice_dictate_bg.py
```

Speak a sentence, pause briefly, and your text should appear.

---

## How to Use

### From Terminal
```bash
cd ~/Downloads/Voice_Dictate

# Start with system default mic
uv run voice_dictate_bg.py

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

## Project Files

```
Voice_Dictate/
├── voice_dictate_bg.py    # Main app (background VAD listener)
├── shortcut_script.sh     # macOS Shortcuts toggle script
├── pyproject.toml         # Dependencies
├── .env                   # Your API key
├── .gitignore             # Git safety
└── README.md              # This file
```

---

## How It Works

The app uses a 3-thread pipeline:

1. **Audio Thread** — `sounddevice` streams mic input continuously
2. **VAD Thread** — Silero VAD (a neural network) analyzes each 32ms audio chunk and detects speech vs. non-speech. Keyboard typing, AC, fans, etc. are ignored — only human voice triggers it.
3. **Transcription Thread** — On the first silence chunk after speech, the app starts a speculative OpenAI transcription request so network latency overlaps the trailing-silence wait. Once the utterance is confirmed finished, the resolved text is pasted into the active app.

All three run concurrently, so the app keeps listening even while a previous utterance is being transcribed.
