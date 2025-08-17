# Voice Dictate for macOS

A powerful voice dictation tool for macOS that records audio from your microphone, transcribes it using OpenAI's Whisper API, and automatically places the text in your clipboard (with optional auto-paste functionality).

## Features

- 🎙️ **Simple Audio Recording**: Records directly from your Mac's microphone using FFmpeg
- 🔤 **Accurate Transcription**: Uses OpenAI's Whisper API for high-quality speech-to-text
- 📋 **Clipboard Integration**: Automatically copies transcribed text to clipboard
- ⌨️ **Auto-Paste**: Optionally simulates Cmd+V to paste text immediately
- 🌍 **Multi-Language Support**: Supports all languages that Whisper supports
- ⚡ **Multiple Models**: Choose between whisper-1, gpt-4o-transcribe, or gpt-4o-mini-transcribe
- 🎯 **Hotkey Support**: Integrate with macOS Shortcuts for global hotkey activation

## Prerequisites

### System Requirements
- macOS (tested on macOS Sonoma 14.0+)
- Python 3.8 or higher
- UV package manager
- FFmpeg
- OpenAI API key

### Required Permissions
- **Microphone Access**: The app needs permission to access your microphone
- **Accessibility Access** (optional): Required only if you want auto-paste functionality

## Installation

### Step 1: Install UV (Python Package Manager)

```bash
# Install UV if you haven't already
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or using Homebrew
brew install uv
```

### Step 2: Install FFmpeg

```bash
# Install FFmpeg using Homebrew
brew install ffmpeg

# Verify installation
ffmpeg -version
```

### Step 3: Clone or Download This Project

```bash
# Clone the repository (or download and extract the files)
cd ~/Downloads/Voice_Dictate

# Or create a new directory and add the files
mkdir -p ~/Voice_Dictate
cd ~/Voice_Dictate
```

### Step 4: Install Python Dependencies with UV

```bash
# Create a virtual environment and install dependencies
uv venv
uv pip install -r pyproject.toml

# Or simply run with UV (it will auto-install dependencies)
uv run python voice_dictate.py --help
```

### Step 5: Set Up OpenAI API Key

You need an OpenAI API key to use the transcription service.

#### Option A: Environment Variable (Recommended)

```bash
# Add to your ~/.zshrc or ~/.bash_profile
export OPENAI_API_KEY="sk-your-api-key-here"

# Reload your shell configuration
source ~/.zshrc

# For system-wide availability (for Shortcuts app)
launchctl setenv OPENAI_API_KEY "sk-your-api-key-here"
```

#### Option B: Pass as Argument

```bash
uv run python voice_dictate.py --api-key "sk-your-api-key-here"
```

## Usage

### Basic Usage

```bash
# Record for 10 seconds (default) and auto-paste
uv run python voice_dictate.py

# Record for 5 seconds
uv run python voice_dictate.py --duration 5

# Record for 15 seconds without auto-paste
uv run python voice_dictate.py --duration 15 --no-paste
```

### Advanced Options

```bash
# Use a specific model (gpt-4o models are faster and more accurate)
uv run python voice_dictate.py --model gpt-4o-mini-transcribe

# Specify language for better accuracy
uv run python voice_dictate.py --language en

# Add a prompt to guide transcription style
uv run python voice_dictate.py --prompt "Technical terms: API, Python, macOS"

# List available audio devices
uv run python voice_dictate.py --list-devices

# Use a specific audio device
uv run python voice_dictate.py --device ":1"

# Quiet mode (don't show transcribed text)
uv run python voice_dictate.py --quiet
```

### Command Line Arguments

| Argument | Short | Description | Default |
|----------|-------|-------------|---------|
| `--duration` | `-d` | Recording duration in seconds | 10 |
| `--model` | `-m` | Whisper model to use | whisper-1 |
| `--language` | `-l` | Language code (en, es, fr, etc.) | Auto-detect |
| `--prompt` | `-p` | Guide transcription with context | None |
| `--device` | | Audio device ID | :0 |
| `--no-paste` | | Don't auto-paste, just copy | False |
| `--list-devices` | | List audio devices and exit | - |
| `--api-key` | | OpenAI API key | From env |
| `--quiet` | `-q` | Don't show transcribed text | False |

## Setting Up Global Hotkey with macOS Shortcuts

### Method 1: macOS Shortcuts App (Recommended)

1. **Open Shortcuts App**
   - Find it in Applications or use Spotlight (Cmd+Space, type "Shortcuts")

2. **Create New Shortcut**
   - Click the "+" button to create a new shortcut
   - Name it "Voice Dictate"

3. **Add Shell Script Action**
   - Search for "Run Shell Script" in the actions
   - Add it to your shortcut

4. **Configure the Script**
   - Shell: `/bin/zsh`
   - Input: Pass to stdin
   - Script content:
   ```bash
   #!/bin/zsh
   
   # Add Homebrew to PATH (required for ffmpeg)
   export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
   
   # Set your OpenAI API key
   export OPENAI_API_KEY="sk-your-api-key-here"
   
   # Change to your project directory
   cd ~/Voice_Dictate
   
   # Run the voice dictation
   uv run python voice_dictate.py --duration 8 --model gpt-4o-mini-transcribe
   ```

5. **Assign Keyboard Shortcut**
   - Click the settings icon (⚙️) in the top right
   - Click "Add Keyboard Shortcut"
   - Press your desired key combination (e.g., Cmd+Shift+V)
   - Click "Done"

6. **Enable the Shortcut**
   - Go to System Settings → Keyboard → Keyboard Shortcuts → Services
   - Find your shortcut under "General"
   - Make sure it's checked and the keyboard shortcut is set

### Method 2: Automator Quick Action

1. **Open Automator**
   - Find it in Applications or use Spotlight

2. **Create Quick Action**
   - Choose "Quick Action" as document type
   - Set "Workflow receives" to "no input"

3. **Add Run Shell Script**
   - Drag "Run Shell Script" action from the library
   - Set the same script as above

4. **Save and Assign Hotkey**
   - Save with a memorable name
   - Go to System Settings → Keyboard → Keyboard Shortcuts → Services
   - Find your Quick Action and assign a keyboard shortcut

## Permissions Setup

### Microphone Permission

When you first run the script, macOS will ask for microphone permission. Grant it through the popup or:

1. System Settings → Privacy & Security → Microphone
2. Enable access for Terminal (or your IDE)

### Accessibility Permission (for Auto-Paste)

For the auto-paste feature to work:

1. System Settings → Privacy & Security → Accessibility
2. Add and enable Terminal (or Shortcuts app if using hotkey)
3. You may need to toggle it off and on if it's already there

## Troubleshooting

### "ffmpeg: command not found"

```bash
# Install FFmpeg
brew install ffmpeg

# If using in Shortcuts, ensure PATH is set:
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
```

### "No audio devices found"

```bash
# List available devices
uv run python voice_dictate.py --list-devices

# Use a specific device (e.g., device 1)
uv run python voice_dictate.py --device ":1"
```

### Silent Recording / No Audio

1. Check microphone permissions
2. Verify the correct audio device is selected
3. Test with the built-in Voice Memos app first

### "OpenAI API key not found"

```bash
# Set the environment variable
export OPENAI_API_KEY="sk-your-api-key-here"

# For system-wide (Shortcuts app)
launchctl setenv OPENAI_API_KEY "sk-your-api-key-here"
```

### Auto-Paste Not Working

1. Grant Accessibility permission to Terminal/Shortcuts
2. Try toggling the permission off and on
3. Use `--no-paste` flag and paste manually with Cmd+V

### API Errors

- **Rate Limit**: Wait a moment and try again
- **Invalid API Key**: Check your API key is correct
- **Quota Exceeded**: Check your OpenAI account billing

## API Models Comparison

| Model | Speed | Accuracy | Cost | Best For |
|-------|-------|----------|------|----------|
| whisper-1 | Good | Good | Low | General use |
| gpt-4o-mini-transcribe | Fast | Better | Medium | Quick dictation |
| gpt-4o-transcribe | Fastest | Best | Higher | Professional use |

## Cost Estimation

OpenAI Whisper API pricing (as of 2025):
- whisper-1: $0.006 per minute
- gpt-4o models: Check OpenAI pricing page

For typical usage (10-second recordings):
- Cost per recording: ~$0.001
- 100 recordings: ~$0.10
- 1000 recordings: ~$1.00

## Performance Tips

1. **Optimal Recording Duration**: 5-15 seconds works best
2. **Sample Rate**: 16kHz is optimal for speech (default)
3. **Quiet Environment**: Reduces transcription errors
4. **Clear Speech**: Speak clearly and at normal pace
5. **Language Specification**: Specifying language improves accuracy

## Security Notes

- **API Key**: Never commit your API key to version control
- **Audio Files**: Temporary recordings are auto-cleaned
- **Privacy**: Audio is sent to OpenAI for transcription
- **Local Storage**: Recordings are stored temporarily in `/tmp/voice_dictate/`

## Development

### Running Tests

```bash
# Install dev dependencies
uv pip install -e ".[dev]"

# Run tests
uv run pytest

# Format code
uv run black voice_dictate.py
uv run ruff check voice_dictate.py
```

### Project Structure

```
Voice_Dictate/
├── voice_dictate.py       # Main application script
├── pyproject.toml         # UV/Python project configuration
├── README.md              # This documentation
├── SETUP_GUIDE.md         # Detailed setup instructions
└── shortcuts/             # Example Shortcuts configurations
    └── VoiceDictate.shortcut
```

## Advanced Customization

### Custom Prompt Examples

```bash
# For technical writing
--prompt "Technical document with terms: API, SDK, REST, JSON"

# For medical transcription
--prompt "Medical transcription with terminology"

# For specific formatting
--prompt "Format as bullet points"
```

### Integration with Other Apps

The tool outputs to clipboard, so it works with any app:
- **Notion**: Paste directly into pages
- **Slack**: Quick voice messages as text
- **Email**: Dictate emails quickly
- **Code Editors**: Comment and document code
- **Note Apps**: Quick note-taking

## Support and Contributing

### Getting Help

1. Check the troubleshooting section above
2. Review OpenAI API documentation
3. Verify all dependencies are installed

### Known Limitations

- Maximum recording file size: 25MB (~30 minutes at 16kHz)
- Requires internet connection for API calls
- Auto-paste requires Accessibility permissions
- FFmpeg required for audio recording

## License

This tool is provided as-is for personal and commercial use. Please ensure you comply with OpenAI's usage policies and your local privacy regulations when recording audio.

## Changelog

### Version 1.0.0 (2025)
- Initial release
- Support for multiple Whisper models
- macOS Shortcuts integration
- Auto-paste functionality
- Multi-language support
- Device selection
- Comprehensive error handling

---

Built with ❤️ for macOS users who want efficient voice-to-text capabilities.