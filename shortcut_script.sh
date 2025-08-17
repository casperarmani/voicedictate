#!/bin/zsh

# Voice Dictate Shortcut Script
# Copy this into macOS Shortcuts app -> Run Shell Script action
# Remember to replace YOUR_API_KEY_HERE with your actual OpenAI API key

# ===== CONFIGURATION =====
# Modify these values to customize your setup

# API key is now loaded from .env file automatically
# You can still override by uncommenting the line below:
# API_KEY="sk-your-key-here"
PROJECT_DIR="$HOME/Voice_Dictate"        # Path to Voice Dictate project
RECORDING_DURATION=8                     # Recording time in seconds
MODEL="gpt-4o-mini-transcribe"          # Options: whisper-1, gpt-4o-mini-transcribe, gpt-4o-transcribe
LANGUAGE=""                              # Leave empty for auto-detect, or use: en, es, fr, de, zh, etc.
AUTO_PASTE=true                          # true = auto-paste, false = copy only

# ===== SETUP PATH =====
# Add Homebrew to PATH (required for ffmpeg and uv)

# For Apple Silicon Macs (M1/M2/M3)
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

# For Intel Macs
if [[ -d "/usr/local/bin" ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# Add UV to PATH if installed via curl
if [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# ===== MAIN SCRIPT =====
# Don't modify below unless you know what you're doing

# Set OpenAI API key (only if specified in this script)
if [[ -n "$API_KEY" ]]; then
    export OPENAI_API_KEY="$API_KEY"
fi

# Change to project directory
if ! cd "$PROJECT_DIR"; then
    echo "Error: Cannot find project directory at $PROJECT_DIR"
    echo "Please check the PROJECT_DIR setting in this script"
    exit 1
fi

# Check if UV is available
if ! command -v uv &> /dev/null; then
    echo "Error: UV package manager not found"
    echo "Install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# Build command arguments
CMD_ARGS="--duration $RECORDING_DURATION --model $MODEL --quiet"

# Add language if specified
if [[ -n "$LANGUAGE" ]]; then
    CMD_ARGS="$CMD_ARGS --language $LANGUAGE"
fi

# Add no-paste flag if auto-paste is disabled
if [[ "$AUTO_PASTE" != "true" ]]; then
    CMD_ARGS="$CMD_ARGS --no-paste"
fi

# Run voice dictation
uv run voice_dictate.py $CMD_ARGS

# Exit with the same status as the Python script
exit $?