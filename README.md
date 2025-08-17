# Voice Dictate for macOS

**One-tap voice dictation with OpenAI Whisper that works system-wide.**

## 🎯 What It Does

1. **Tap Touch Bar** → **Starts recording immediately**
2. **Talk for as long as you want** 🗣️
3. **Press Cmd+`** → **Transcribes and pastes text wherever your cursor is**
4. **Ready for next recording** (same terminal, no new windows)

Works from **any app** - Chrome, Slack, Notes, Cursor, anywhere!

---

## 🚀 Quick Setup

### 1. Install Dependencies
```bash
# Install required tools
brew install ffmpeg uv

# Navigate to project and install Python packages
cd ~/Downloads/Voice_Dictate
uv sync
```

### 2. Add Your OpenAI API Key
Your API key is already in the `.env` file - you're ready to go!

### 3. Test It Works
```bash
# Test 5-second recording
uv run voice_dictate.py --duration 5 --no-paste

# You should see transcribed text in terminal
```

### 4. Set Up Touch Bar Shortcut

**Open Shortcuts App:**
- Press `Cmd+Space`, type "Shortcuts", press Enter

**Create New Shortcut:**
- Click "+" button
- Name it "Voice Dictate"

**Add Shell Script:**
- Search for "Run Shell Script" and add it
- **Shell**: `/bin/zsh`
- **Input**: `No Input`
- **Paste this exact script:**

```bash
#!/bin/zsh

# Run in Terminal without switching to it
osascript -e '
tell application "Terminal"
    if (count of windows) > 0 then
        -- Use existing front window but dont bring Terminal to front
        do script "cd ~/Downloads/Voice_Dictate && uv run voice_dictate.py --push-to-talk --model gpt-4o-mini-transcribe --quiet" in front window
    else
        -- Create new window only if none exist
        do script "cd ~/Downloads/Voice_Dictate && uv run voice_dictate.py --push-to-talk --model gpt-4o-mini-transcribe --quiet"
    end if
end tell'
```

**Add to Touch Bar:**
- Right-click your shortcut → "Add to Menu Bar" or "Add to Touch Bar"
- Or: Right-click → "Shortcut Settings" → "Use as Quick Action"
- Then: System Settings → Keyboard → "Customize Control Strip" → Drag "Quick Actions" to Touch Bar

### 5. Grant Permissions

**Microphone Access:**
- Allow when prompted

**Accessibility Access (for auto-paste):**
- System Settings → Privacy & Security → Accessibility
- Add "Terminal" and make sure it's checked ✅

---

## 🎙️ How to Use

### First Recording
1. **Tap Touch Bar icon** 
2. **Terminal opens in background, recording starts immediately**
3. **Start talking** (no desktop switching)
4. **Press Cmd+`** when done talking
5. **Text transcribes and pastes** where your cursor was

### Subsequent Recordings (Same Session)
1. **Terminal shows**: "🎯 Ready for next recording! Press Cmd+` to start recording again"
2. **Press Cmd+`** → **Starts new recording**
3. **Talk** → **Press Cmd+`** → **Transcribes and pastes**
4. **Repeat forever** (no Touch Bar needed)

### Exit
- **Ctrl+C** in terminal or just close the terminal window

---

## ⚙️ Customization

### Different Models
Edit the shortcut script to change model:
```bash
# Faster, cheaper
--model gpt-4o-mini-transcribe

# Best quality, more expensive  
--model gpt-4o-transcribe

# Original Whisper
--model whisper-1
```

### Different Languages
Add language specification:
```bash
# Add to the command
--language en    # English
--language es    # Spanish
--language fr    # French
```

### Use Headset Microphone
```bash
# Change device (list devices first)
uv run voice_dictate.py --list-devices

# Then use specific device
--device ":0"    # Usually headset
--device ":1"    # Usually built-in mic (default)
```

---

## 🔧 Troubleshooting

### "No audio recorded"
- Check microphone permissions
- Run: `uv run voice_dictate.py --list-devices` to see available mics

### "Auto-paste not working"
- Grant Terminal accessibility permissions
- System Settings → Privacy & Security → Accessibility → Add Terminal

### "Command not found: ffmpeg"
- Install with: `brew install ffmpeg`

### "Cmd+` conflicts with my app"
- Edit `voice_dictate.py` line 215 to change key:
  ```python
  stop_key_combo: tuple = (keyboard.Key.cmd, keyboard.KeyCode.from_char(';'))
  ```

### Touch Bar shortcut not working
- Make sure "Quick Actions" is added to Control Strip
- Try right-clicking shortcut → "Shortcut Settings" → "Use as Quick Action"

---

## 📁 Project Files

```
Voice_Dictate/
├── voice_dictate.py       # Main application
├── pyproject.toml         # Dependencies  
├── .env                   # Your API key
├── .gitignore            # Git safety
└── README.md             # This file
```

---

## 💡 Tips

- **Best recording length**: 30 seconds to 5 minutes works great
- **Speak clearly**: Normal pace, don't rush
- **Quiet environment**: Better transcription quality
- **MacBook Pro mic**: Default is built-in mic (device ":1")
- **Background use**: Terminal can stay open all day for quick access

---

## 🎉 You're Done!

**Tap your Touch Bar → Talk → Cmd+` → Text appears!**

Perfect for:
- 📝 **Note-taking** in any app
- 💬 **Slack messages** 
- ✉️ **Email composition**
- 📄 **Document writing**
- 💻 **Code comments**

Enjoy your supercharged voice-to-text workflow! 🚀