# Complete Setup Guide for Voice Dictate with Hotkey

This guide will walk you through setting up Voice Dictate with a global hotkey on macOS, step by step.

## Table of Contents

1. [Quick Setup Checklist](#quick-setup-checklist)
2. [Detailed Installation Steps](#detailed-installation-steps)
3. [Setting Up the Hotkey](#setting-up-the-hotkey)
4. [Testing and Troubleshooting](#testing-and-troubleshooting)
5. [Customization Options](#customization-options)

## Quick Setup Checklist

- [ ] Python 3.8+ installed
- [ ] UV package manager installed
- [ ] FFmpeg installed via Homebrew
- [ ] OpenAI API key obtained
- [ ] Project files downloaded
- [ ] Dependencies installed with UV
- [ ] Microphone permissions granted
- [ ] Shortcuts app configured
- [ ] Hotkey assigned and working

## Detailed Installation Steps

### Step 1: Install Homebrew (if needed)

```bash
# Check if Homebrew is installed
brew --version

# If not installed, install it:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Follow the instructions to add Homebrew to your PATH
```

### Step 2: Install Required System Tools

```bash
# Install FFmpeg for audio recording
brew install ffmpeg

# Verify FFmpeg installation
ffmpeg -version
# Should show version information
```

### Step 3: Install UV Package Manager

```bash
# Install UV (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via Homebrew
brew install uv

# Verify UV installation
uv --version
```

### Step 4: Set Up Project Directory

```bash
# Create project directory
mkdir -p ~/Voice_Dictate
cd ~/Voice_Dictate

# Copy the project files here:
# - voice_dictate.py
# - pyproject.toml
# - README.md
# - SETUP_GUIDE.md
```

### Step 5: Install Python Dependencies

```bash
# Navigate to project directory
cd ~/Voice_Dictate

# Create virtual environment and install dependencies
uv venv
uv pip sync pyproject.toml

# Or just test run (UV will auto-install dependencies)
uv run python voice_dictate.py --help
```

### Step 6: Get OpenAI API Key

1. Go to [OpenAI Platform](https://platform.openai.com)
2. Sign in or create an account
3. Navigate to API Keys section
4. Create a new API key
5. Copy the key (starts with `sk-`)

⚠️ **Important**: Save this key securely. You won't be able to see it again!

### Step 7: Configure API Key

#### For Terminal Use:

```bash
# Add to ~/.zshrc (or ~/.bash_profile for bash)
echo 'export OPENAI_API_KEY="sk-your-actual-api-key-here"' >> ~/.zshrc

# Reload shell configuration
source ~/.zshrc

# Verify it's set
echo $OPENAI_API_KEY
```

#### For System-Wide Use (Required for Shortcuts):

```bash
# Set for all applications
launchctl setenv OPENAI_API_KEY "sk-your-actual-api-key-here"

# Note: This needs to be run after each restart, or add to login items
```

### Step 8: Test Basic Functionality

```bash
# Test listing devices
uv run python voice_dictate.py --list-devices

# Test recording (5 seconds)
uv run python voice_dictate.py --duration 5 --no-paste

# If successful, you should see:
# 🎙️  Recording for 5 seconds...
# ✅ Recording complete!
# 🔄 Transcribing with whisper-1...
# ✅ Transcription complete!
# 📋 Text copied to clipboard!
```

## Setting Up the Hotkey

### Method 1: macOS Shortcuts App (Recommended)

#### A. Create the Shortcut

1. **Open Shortcuts App**
   - Press `Cmd + Space`, type "Shortcuts", press Enter
   - Or find it in the Applications folder

2. **Create New Shortcut**
   - Click the "+" button in the top right
   - You'll see an empty shortcut editor

3. **Add Run Shell Script Action**
   - In the search bar on the right, type "shell"
   - Drag "Run Shell Script" into the shortcut

4. **Configure Shell Script Settings**
   - Click on the shell script action
   - Set these options:
     - **Shell**: `/bin/zsh`
     - **Pass Input**: to stdin (dropdown)
     - **Run as administrator**: OFF (unchecked)

5. **Enter the Script**
   
   Copy and paste this exact script:

   ```bash
   #!/bin/zsh
   
   # CONFIGURATION - Modify these values
   API_KEY="sk-your-actual-api-key-here"  # <- Replace with your API key
   PROJECT_DIR="$HOME/Voice_Dictate"       # <- Change if different location
   RECORDING_DURATION=8                    # <- Adjust recording time (seconds)
   MODEL="gpt-4o-mini-transcribe"         # <- Or "whisper-1" or "gpt-4o-transcribe"
   
   # Add Homebrew to PATH (adjust if Homebrew is elsewhere)
   if [[ -d "/opt/homebrew/bin" ]]; then
       export PATH="/opt/homebrew/bin:$PATH"
   elif [[ -d "/usr/local/bin" ]]; then
       export PATH="/usr/local/bin:$PATH"
   fi
   
   # Set OpenAI API key
   export OPENAI_API_KEY="$API_KEY"
   
   # Change to project directory
   cd "$PROJECT_DIR" || exit 1
   
   # Check if UV is available
   if ! command -v uv &> /dev/null; then
       echo "Error: UV not found. Please install UV first."
       exit 1
   fi
   
   # Run voice dictation
   uv run python voice_dictate.py \
       --duration "$RECORDING_DURATION" \
       --model "$MODEL" \
       --quiet
   ```

6. **Name Your Shortcut**
   - Click "Shortcut Name" at the top
   - Enter "Voice Dictate" or your preferred name

#### B. Assign Keyboard Shortcut

1. **In the Shortcuts App**
   - With your shortcut selected
   - Click the ⓘ (info) button in the top right
   - Click "Add Keyboard Shortcut"
   - Press your desired key combination (e.g., `Cmd + Shift + D`)
   - Click "Done"

2. **Enable in System Settings**
   - Open System Settings
   - Go to Keyboard → Keyboard Shortcuts → Services
   - Scroll to "General" section
   - Find "Voice Dictate" (or your shortcut name)
   - Ensure it's checked ✓
   - Verify the keyboard shortcut is shown

#### C. Grant Required Permissions

When you first run the shortcut, you'll need to grant permissions:

1. **Microphone Access**
   - You'll see a popup asking for microphone permission
   - Click "OK" or "Allow"

2. **Accessibility Access (for auto-paste)**
   - System Settings → Privacy & Security → Accessibility
   - Click the lock to make changes
   - Add "Shortcuts" app (click + and find it)
   - Ensure it's checked ✓

### Method 2: Using Automator (Alternative)

If Shortcuts doesn't work well for you, use Automator:

1. **Open Automator**
2. **Choose "Quick Action"**
3. **Set "Workflow receives" to "no input" in "any application"**
4. **Add "Run Shell Script" action**
5. **Paste the same script as above**
6. **Save as "Voice Dictate"**
7. **Assign hotkey in System Settings → Keyboard → Keyboard Shortcuts → Services**

## Testing and Troubleshooting

### Test Your Setup

1. **Open any text application** (TextEdit, Notes, etc.)
2. **Place your cursor where you want text**
3. **Press your hotkey** (e.g., Cmd+Shift+D)
4. **Start speaking when you see the recording indicator**
5. **Wait for the transcription to appear**

### Common Issues and Solutions

#### "Permission Denied" or No Recording

```bash
# Check microphone permissions
# System Settings → Privacy & Security → Microphone
# Ensure Terminal and Shortcuts are allowed
```

#### "ffmpeg: command not found"

```bash
# The PATH might not be set correctly in the shortcut
# Try using full path in the script:
/opt/homebrew/bin/ffmpeg  # For Apple Silicon Macs
/usr/local/bin/ffmpeg      # For Intel Macs
```

#### "UV: command not found"

```bash
# Add UV to PATH in the shortcut script:
export PATH="$HOME/.cargo/bin:$PATH"  # If installed via curl
export PATH="/opt/homebrew/bin:$PATH" # If installed via Homebrew
```

#### No Text Appears / Silent Failure

1. **Check API Key**:
   ```bash
   # Test in Terminal first
   export OPENAI_API_KEY="your-key"
   uv run python voice_dictate.py --duration 3
   ```

2. **Check Shortcut Output**:
   - In Shortcuts app, add "Quick Look" action after the shell script
   - This will show any error messages

3. **Enable Debugging**:
   Add this to your shortcut script:
   ```bash
   # Enable debugging
   exec 2>&1  # Redirect errors to output
   set -x     # Print commands as they run
   ```

#### Auto-Paste Not Working

1. **Grant Accessibility Permission**:
   - System Settings → Privacy & Security → Accessibility
   - Add and enable Shortcuts app
   - Toggle off and on if already there

2. **Use Manual Paste**:
   - Add `--no-paste` to the command
   - Text will be in clipboard, paste with Cmd+V

### Checking Audio Devices

If default microphone isn't working:

```bash
# List all audio devices
uv run python voice_dictate.py --list-devices

# Output example:
# Available audio devices:
# ----------------------------------------
#   [0] Built-in Microphone
#   [1] External Microphone
#   [2] AirPods Pro

# Use specific device in shortcut:
uv run python voice_dictate.py --device ":1"  # Use device 1
```

## Customization Options

### Adjust Recording Duration

In your shortcut script, change:
```bash
RECORDING_DURATION=8  # Change to any number of seconds
```

### Change Transcription Model

```bash
MODEL="whisper-1"              # Standard, lowest cost
MODEL="gpt-4o-mini-transcribe" # Faster, more accurate
MODEL="gpt-4o-transcribe"      # Best quality, highest cost
```

### Add Language Specification

For better accuracy with non-English or accented speech:
```bash
# Add to the command in your shortcut
--language "es"  # Spanish
--language "fr"  # French
--language "de"  # German
--language "zh"  # Chinese
```

### Custom Prompts for Context

Add domain-specific terms for better recognition:
```bash
# Add to the command
--prompt "Technical terms: Kubernetes, Docker, API, microservices"
```

### Different Modes

```bash
# Just copy to clipboard (no auto-paste)
--no-paste

# Don't show transcribed text
--quiet

# Show progress and text
# (remove --quiet flag)
```

## Advanced Setup

### Multiple Shortcuts for Different Uses

Create different shortcuts for various scenarios:

1. **Quick Note** (5 seconds, auto-paste)
2. **Long Dictation** (30 seconds, copy only)
3. **Code Comments** (10 seconds, with technical prompt)
4. **Foreign Language** (with specific language set)

### Integration with Other Apps

The tool works with any app that accepts text input:
- **Notion**: Direct dictation into pages
- **Slack**: Voice messages as text
- **VS Code**: Code comments and documentation
- **Email**: Quick email composition
- **Messages**: Voice to text messaging

### Backup Script

Create a simple shell script for Terminal use:

```bash
# Create ~/bin/dictate
mkdir -p ~/bin
cat > ~/bin/dictate << 'EOF'
#!/bin/zsh
cd ~/Voice_Dictate
uv run python voice_dictate.py "$@"
EOF

chmod +x ~/bin/dictate

# Add to PATH in ~/.zshrc
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Now you can use:
dictate --duration 5
```

## Performance Optimization

### For Faster Response

1. Use `gpt-4o-mini-transcribe` model (fastest)
2. Reduce recording duration
3. Ensure good internet connection
4. Use wired microphone for clearer audio

### For Better Accuracy

1. Use `gpt-4o-transcribe` model
2. Speak clearly and at normal pace
3. Specify language with `--language` flag
4. Use quiet environment
5. Add context with `--prompt` flag

## Security Best Practices

1. **Never share your API key**
2. **Don't commit API key to git**
3. **Use environment variables for API key**
4. **Regularly rotate API keys**
5. **Monitor API usage in OpenAI dashboard**
6. **Set spending limits in OpenAI account**

## Getting Help

### Diagnostic Commands

```bash
# Check all components
cd ~/Voice_Dictate

# 1. Check Python
python3 --version

# 2. Check UV
uv --version

# 3. Check FFmpeg
ffmpeg -version

# 4. Check API key
echo $OPENAI_API_KEY | cut -c1-7  # Should show "sk-..."

# 5. Test recording
ffmpeg -f avfoundation -i ":0" -t 2 test.wav

# 6. Test full flow
uv run python voice_dictate.py --duration 3 --no-paste
```

### Error Reporting

When reporting issues, include:
1. macOS version: `sw_vers`
2. Python version: `python3 --version`
3. Error messages from Shortcuts (use Quick Look)
4. Output of diagnostic commands above

## Next Steps

Once everything is working:

1. **Experiment with different models** to find the best balance of speed/accuracy/cost
2. **Adjust recording duration** based on your typical use
3. **Create multiple shortcuts** for different scenarios
4. **Share with team members** (they'll need their own API keys)
5. **Monitor API usage** to optimize costs

---

Congratulations! You now have a powerful voice dictation system with global hotkey support on your Mac. Press your hotkey anywhere, speak, and watch your words appear like magic! 🎙️✨