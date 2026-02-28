#!/bin/zsh

# Voice Dictate Shortcut Script (Background Mode)
# Copy this into macOS Shortcuts app -> Run Shell Script action
# Press the shortcut once to START listening, press again to STOP.

# ===== CONFIGURATION =====
# Modify these values to customize your setup

# API key is now loaded from .env file automatically
# You can still override by uncommenting the line below:
# API_KEY="sk-your-key-here"
PROJECT_DIR="$HOME/Voice_Dictate"        # Path to Voice Dictate project
MODEL="gpt-4o-mini-transcribe"          # Options: whisper-1, gpt-4o-mini-transcribe, gpt-4o-transcribe
LANGUAGE=""                              # Leave empty for auto-detect, or use: en, es, fr, de, zh, etc.
AUTO_PASTE=true                          # true = auto-paste, false = copy only
DEVICE=3                                 # Audio device index (3 = MacBook Pro Microphone)

# VAD (Voice Activity Detection) settings
VAD_THRESHOLD=0.5                        # 0.0-1.0, higher = stricter (raise if false triggers)
SILENCE_TIMEOUT=1.5                      # Seconds of silence before ending an utterance
MIN_SPEECH=0.5                           # Minimum speech duration (filters coughs/clicks)

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

PIDFILE="$PROJECT_DIR/.voice_dictate_bg.pid"

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

# ===== TOGGLE LOGIC =====
# If already running, stop it. If not running, start it.

if [[ -f "$PIDFILE" ]]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        # Process is running — stop it
        kill "$OLD_PID" 2>/dev/null
        rm -f "$PIDFILE"
        echo "Voice Dictate stopped."
        exit 0
    else
        # Stale PID file — clean up
        rm -f "$PIDFILE"
    fi
fi

# Build command arguments
CMD_ARGS="--model $MODEL --vad-threshold $VAD_THRESHOLD --silence-timeout $SILENCE_TIMEOUT --min-speech $MIN_SPEECH --device $DEVICE"

# Add language if specified
if [[ -n "$LANGUAGE" ]]; then
    CMD_ARGS="$CMD_ARGS --language $LANGUAGE"
fi

# Add no-paste flag if auto-paste is disabled
if [[ "$AUTO_PASTE" != "true" ]]; then
    CMD_ARGS="$CMD_ARGS --no-paste"
fi

# Start background voice dictation
uv run voice_dictate_bg.py $CMD_ARGS &
BG_PID=$!

# Save PID for toggle
echo "$BG_PID" > "$PIDFILE"

# Clean up PID file when the process exits
(
    wait "$BG_PID" 2>/dev/null
    rm -f "$PIDFILE"
) &

echo "Voice Dictate started (PID: $BG_PID). Press shortcut again to stop."
exit 0