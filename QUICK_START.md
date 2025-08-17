# 🚀 Quick Start Guide

Your API key is already configured! Follow these simple steps:

## 1. Install Dependencies (1 minute)

```bash
# Install FFmpeg and UV
brew install ffmpeg uv

# Navigate to the project
cd ~/Downloads/Voice_Dictate

# Install Python packages
uv sync
```

## 2. Test It Works (30 seconds)

```bash
# Test 5-second recording
uv run voice_dictate.py --duration 5 --no-paste

# You should see:
# ✅ Loaded API key from .env file
# 🎙️  Recording for 5 seconds...
# ✅ Recording complete!
# 🔄 Transcribing with whisper-1...
# ✅ Transcription complete!
# 📋 Text copied to clipboard!
```

## 3. Set Up Hotkey (2 minutes)

### Option A: Copy the Ready-Made Script

1. **Open Shortcuts app** (Cmd+Space, type "Shortcuts")
2. **Click "+" to create new shortcut**
3. **Search for "Run Shell Script"** and add it
4. **Copy the entire contents** of `shortcut_script.sh` into the script box
5. **Name it "Voice Dictate"**
6. **Click ⓘ (info) → Add Keyboard Shortcut → Press Cmd+Shift+D**

### Option B: Quick Script

Just paste this into Shortcuts:

```bash
#!/bin/zsh
export PATH="/opt/homebrew/bin:$PATH"
cd ~/Downloads/Voice_Dictate
uv run voice_dictate.py --duration 8 --model gpt-4o-mini-transcribe --quiet
```

## 4. Grant Permissions

- **Microphone**: Allow when prompted
- **Accessibility**: System Settings → Privacy & Security → Accessibility → Add "Shortcuts"

## 5. Use It! ✨

1. **Open any app** (Notes, TextEdit, Slack, etc.)
2. **Place cursor** where you want text
3. **Press Cmd+Shift+D** (or your chosen hotkey)
4. **Speak for 8 seconds**
5. **Text appears automatically!**

---

## Troubleshooting

**Nothing happens?** Check the Shortcuts app for error messages

**No sound recorded?** Run `uv run voice_dictate.py --list-devices` to see available microphones

**API errors?** Your API key in `.env` is already set - just ensure you have OpenAI credit

---

That's it! You now have voice dictation with a hotkey. Press it anywhere and start talking! 🎙️