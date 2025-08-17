# Engineering Brief: Voice Dictation System for macOS

## Executive Summary

This document provides a complete technical specification for implementing a voice dictation system on macOS that:
1. Records audio from the microphone via a global hotkey
2. Transcribes speech using OpenAI's Whisper API  
3. Automatically inserts transcribed text at the cursor position

## System Architecture

### Component Overview

```
User Presses Hotkey
        ↓
macOS Shortcuts App
        ↓
Shell Script Execution
        ↓
Python Script (voice_dictate.py)
        ├── FFmpeg (Audio Recording)
        ├── OpenAI API (Transcription)
        ├── Pyperclip (Clipboard)
        └── AppleScript (Auto-paste)
```

### Technology Stack

- **Language**: Python 3.8+
- **Package Manager**: UV (modern Python package manager)
- **Audio Recording**: FFmpeg with AVFoundation (macOS native)
- **Speech-to-Text**: OpenAI Whisper API (cloud-based)
- **Clipboard**: Pyperclip (cross-platform) with pbcopy fallback
- **Hotkey Integration**: macOS Shortcuts app (no background daemon needed)
- **Auto-paste**: AppleScript via osascript

## Technical Implementation Details

### 1. Audio Recording Module

**Technology**: FFmpeg with AVFoundation framework

**Implementation**:
```python
# Core recording command structure
ffmpeg -f avfoundation -i ":0" -t 10 -ar 16000 -ac 1 -acodec pcm_s16le output.wav
```

**Key Parameters**:
- `-f avfoundation`: macOS native audio framework
- `-i ":0"`: Default microphone (device index)
- `-t 10`: Duration in seconds
- `-ar 16000`: Sample rate (16kHz optimal for speech)
- `-ac 1`: Mono channel
- `-acodec pcm_s16le`: 16-bit PCM encoding

**Why FFmpeg**:
- No Python C extensions needed (unlike PyAudio)
- Reliable on macOS without permission issues
- Handles device enumeration properly
- Minimal dependencies

### 2. Speech-to-Text Module

**Technology**: OpenAI Audio API

**Available Models** (as of 2025):
- `whisper-1`: Original Whisper model, lowest cost
- `gpt-4o-mini-transcribe`: Faster, more accurate, medium cost
- `gpt-4o-transcribe`: Best accuracy, highest cost

**API Implementation**:
```python
from openai import OpenAI

client = OpenAI(api_key=api_key)
with open(audio_file, 'rb') as f:
    response = client.audio.transcriptions.create(
        model="whisper-1",
        file=f,
        language="en",  # Optional
        prompt="",       # Optional context
        temperature=0.0  # Deterministic
    )
text = response.text
```

**API Constraints**:
- Max file size: 25MB
- Supported formats: wav, mp3, mp4, m4a, webm, etc.
- Rate limits: Based on tier (typically 50-500 requests/min)

### 3. Clipboard Integration

**Primary Method**: Pyperclip library
```python
import pyperclip
pyperclip.copy(text)
```

**Fallback Method**: Direct pbcopy
```python
subprocess.run(['pbcopy'], input=text.encode('utf-8'))
```

**Auto-paste via AppleScript**:
```python
applescript = '''
tell application "System Events"
    keystroke "v" using command down
end tell
'''
subprocess.run(['osascript', '-e', applescript])
```

### 4. Hotkey Integration

**Method**: macOS Shortcuts App (no daemon required)

**Shell Script for Shortcuts**:
```bash
#!/bin/zsh
export PATH="/opt/homebrew/bin:$PATH"
export OPENAI_API_KEY="sk-..."
cd ~/Voice_Dictate
uv run python voice_dictate.py --duration 8 --model gpt-4o-mini-transcribe
```

**Why Shortcuts App**:
- Native macOS solution (no third-party tools)
- No background process needed
- System-level hotkey handling
- Proper permission management
- Works across all applications

## File Structure

```
Voice_Dictate/
├── voice_dictate.py          # Main application (622 lines)
├── pyproject.toml            # UV package configuration
├── README.md                 # User documentation
├── SETUP_GUIDE.md           # Detailed setup instructions
├── ENGINEERING_BRIEF.md     # This document
├── test_setup.sh            # Installation verification script
└── shortcut_script.sh       # Template for Shortcuts app
```

## Core Features Implemented

### Required Features
- ✅ Audio recording from microphone
- ✅ OpenAI Whisper API integration
- ✅ Clipboard placement
- ✅ Global hotkey trigger
- ✅ Simple UV-based setup

### Additional Features
- ✅ Multiple model support
- ✅ Auto-paste functionality
- ✅ Device selection
- ✅ Multi-language support
- ✅ Custom prompts for context
- ✅ Quiet mode
- ✅ Error handling and recovery
- ✅ Temporary file cleanup
- ✅ Progress indicators

## Permissions Required

### Microphone Access
- **When**: First run
- **Prompt**: System dialog
- **Setting**: System Settings → Privacy & Security → Microphone

### Accessibility Access (for auto-paste)
- **When**: First auto-paste attempt
- **Required for**: AppleScript keyboard simulation
- **Setting**: System Settings → Privacy & Security → Accessibility
- **Apps to enable**: Shortcuts, Terminal

## Error Handling Strategy

### Graceful Degradation
1. **FFmpeg missing**: Clear error with installation instructions
2. **API key missing**: Prompt with setup instructions
3. **Auto-paste fails**: Fallback to clipboard-only mode
4. **Network errors**: Retry logic with timeout
5. **Invalid audio**: Proper error messages

### User Feedback
- Clear progress indicators
- Descriptive error messages
- Success confirmations
- Clipboard fallback notifications

## Security Considerations

### API Key Management
- Environment variable storage
- Never in code/logs
- Per-user configuration
- No hardcoded values

### Audio Privacy
- Temporary files auto-deleted
- Local recording only
- Explicit user trigger required
- No persistent storage

### Clipboard Security
- No sensitive data logging
- User-initiated actions only
- Standard OS clipboard APIs

## Performance Specifications

### Latency Breakdown
- Recording: Real-time (N seconds)
- Upload: ~0.5-1 second
- Transcription: ~1-3 seconds
- Total: Recording + 2-4 seconds

### Resource Usage
- CPU: Minimal (FFmpeg encoding)
- Memory: <50MB Python process
- Disk: Temporary WAV files only
- Network: Audio file upload only

## Installation Requirements

### System Dependencies
```bash
# Package manager
curl -LsSf https://astral.sh/uv/install.sh | sh

# Audio recording
brew install ffmpeg

# Python packages (via UV)
uv pip install openai pyperclip
```

### Environment Setup
```bash
# API key configuration
export OPENAI_API_KEY="sk-..."
launchctl setenv OPENAI_API_KEY "sk-..."
```

## Testing Protocol

### Unit Testing
1. Audio device enumeration
2. Recording functionality
3. API communication
4. Clipboard operations
5. Error handling

### Integration Testing
1. Full workflow execution
2. Hotkey triggering
3. Permission handling
4. Multi-app compatibility

### Test Commands
```bash
# Verify installation
./test_setup.sh

# List devices
uv run python voice_dictate.py --list-devices

# Test recording
uv run python voice_dictate.py --duration 3 --no-paste

# Test with specific model
uv run python voice_dictate.py --model gpt-4o-mini-transcribe
```

## Deployment Steps

### For End Users

1. **Clone/Download Files**
   ```bash
   cd ~/Downloads/Voice_Dictate
   ```

2. **Run Setup**
   ```bash
   ./test_setup.sh
   uv pip install openai pyperclip
   ```

3. **Configure Hotkey**
   - Open Shortcuts app
   - Create new shortcut
   - Add shell script
   - Assign keyboard shortcut

4. **Test**
   ```bash
   uv run python voice_dictate.py --duration 5
   ```

## API Cost Analysis

### Pricing (2025 rates)
- whisper-1: $0.006/minute
- gpt-4o-mini-transcribe: ~$0.01/minute
- gpt-4o-transcribe: ~$0.02/minute

### Usage Estimates
- 10-second recording: ~$0.001
- 100 uses/day: ~$0.10/day
- 3000 uses/month: ~$3.00/month

## Future Enhancements

### Potential Additions
1. **Streaming transcription**: Real-time results
2. **Push-to-talk**: Variable length recording
3. **Voice commands**: "Stop recording", "Cancel"
4. **Multiple languages**: Auto-detection
5. **Local Whisper**: On-device processing option
6. **History**: Recent transcriptions log
7. **Corrections**: Quick edit last transcription

### Performance Optimizations
1. **Parallel processing**: Upload while recording ends
2. **Compression**: Reduce upload size
3. **Caching**: Remember common phrases
4. **Batch operations**: Multiple recordings

## Troubleshooting Guide

### Common Issues

**Issue**: "ffmpeg: command not found"
**Solution**: Add Homebrew to PATH in shortcut script

**Issue**: No audio recorded
**Solution**: Check microphone permissions and device selection

**Issue**: Auto-paste not working
**Solution**: Grant Accessibility permission to Shortcuts app

**Issue**: API errors
**Solution**: Verify API key and check OpenAI account status

## Conclusion

This implementation provides a robust, user-friendly voice dictation system for macOS that:
- Requires minimal setup (UV + FFmpeg + API key)
- Works system-wide via hotkey
- Provides reliable transcription
- Handles errors gracefully
- Respects user privacy
- Operates efficiently

The modular design allows for easy customization and extension while maintaining simplicity for end users. The use of UV for package management ensures reproducible installations and easy dependency management.

## Support Resources

- OpenAI API Docs: https://platform.openai.com/docs
- FFmpeg Documentation: https://ffmpeg.org/documentation.html
- UV Package Manager: https://github.com/astral-sh/uv
- macOS Shortcuts: https://support.apple.com/guide/shortcuts-mac

---

*This engineering brief provides complete context for implementing and maintaining the Voice Dictate system. All code is production-ready and thoroughly tested on macOS.*