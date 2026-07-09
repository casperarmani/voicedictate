#!/bin/zsh

# Voice Dictate Shortcut Script (Terminal Window Mode)
# Copy this into macOS Shortcuts app -> Run Shell Script action.
# Press the shortcut once to START — a Terminal window opens so you can watch
# it live. Press again to STOP (or just Ctrl+C in the Terminal window).

# ===== CONFIGURATION =====
# Modify these values to customize your setup

# API key is loaded from .env automatically
# You can still override by uncommenting the line below:
# API_KEY="sk-your-key-here"
PROJECT_DIR="$HOME/Desktop/voicedictate"  # Path to Voice Dictate project
MODE="realtime"                              # Options: realtime, classic
MODEL="gpt-4o-mini-transcribe"               # Options: gpt-4o-mini-transcribe, gpt-4o-transcribe
LANGUAGE=""                                  # Leave empty for the app default (en), or use: en, es, fr, de, zh, etc.
AUTO_PASTE=true                              # true = auto-paste, false = copy only
DEVICE=""                                    # Leave empty to auto-select the built-in mic

# VAD (Voice Activity Detection) settings
VAD_THRESHOLD=0.5                        # 0.0-1.0, higher = stricter (raise if false triggers)
SILENCE_TIMEOUT=0.25                     # Seconds of silence before ending an utterance
MIN_SPEECH=0.2                           # Minimum speech duration (filters coughs/clicks)

# ===== TOGGLE: STOP IF ALREADY RUNNING =====

RUNNING_PIDS=$(pgrep -f "python.*voice_dictate_bg\.py" 2>/dev/null)
if [[ -n "$RUNNING_PIDS" ]]; then
    echo "$RUNNING_PIDS" | xargs kill 2>/dev/null
    rm -f "$PROJECT_DIR/.voice_dictate_bg.pid"
    echo "Voice Dictate stopped."
    exit 0
fi

# ===== START IN A NEW TERMINAL WINDOW =====

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: Cannot find project directory at $PROJECT_DIR"
    echo "Please check the PROJECT_DIR setting in this script"
    exit 1
fi

PYTHON_BIN="$PROJECT_DIR/.venv/bin/python"
if [[ -x "$PYTHON_BIN" ]]; then
    RUNNER="'$PYTHON_BIN'"
else
    RUNNER="uv run"  # fallback; the new Terminal's login shell has brew/uv on PATH
fi

CMD_ARGS="--mode $MODE --model $MODEL --vad-threshold $VAD_THRESHOLD --silence-timeout $SILENCE_TIMEOUT --min-speech $MIN_SPEECH"
[[ -n "$DEVICE" ]] && CMD_ARGS="$CMD_ARGS --device $DEVICE"
[[ -n "$LANGUAGE" ]] && CMD_ARGS="$CMD_ARGS --language $LANGUAGE"
[[ "$AUTO_PASTE" != "true" ]] && CMD_ARGS="$CMD_ARGS --no-paste"

KEY_PREFIX=""
[[ -n "$API_KEY" ]] && KEY_PREFIX="OPENAI_API_KEY='$API_KEY' "

LAUNCH_CMD="cd '$PROJECT_DIR' && ${KEY_PREFIX}exec $RUNNER voice_dictate_bg.py $CMD_ARGS"

# If Terminal isn't running yet, `activate` creates a default startup window —
# reuse it instead of opening a second window for the command.
osascript <<EOF
set wasRunning to application "Terminal" is running
tell application "Terminal"
    activate
    if wasRunning then
        do script "$LAUNCH_CMD"
    else
        try
            do script "$LAUNCH_CMD" in front window
        on error
            do script "$LAUNCH_CMD"
        end try
    end if
end tell
EOF

echo "Voice Dictate started in a Terminal window."
echo "Press the shortcut again (or Ctrl+C in the window) to stop."
exit 0
