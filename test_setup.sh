#!/bin/bash

# Voice Dictate Setup Test Script
# This script helps verify your installation is working correctly

echo "========================================="
echo "Voice Dictate Setup Verification"
echo "========================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check function
check_command() {
    if command -v $1 &> /dev/null; then
        echo -e "${GREEN}✓${NC} $2 found: $(command -v $1)"
        return 0
    else
        echo -e "${RED}✗${NC} $2 not found"
        echo "  Install with: $3"
        return 1
    fi
}

# Check environment variable
check_env() {
    if [ -z "${!1}" ]; then
        echo -e "${RED}✗${NC} $1 not set"
        echo "  Set with: export $1=\"$2\""
        return 1
    else
        # Show first 7 chars for API key
        if [ "$1" = "OPENAI_API_KEY" ]; then
            echo -e "${GREEN}✓${NC} $1 is set (${!1:0:7}...)"
        else
            echo -e "${GREEN}✓${NC} $1 is set"
        fi
        return 0
    fi
}

# Track overall status
all_good=true

echo "Checking System Requirements:"
echo "------------------------------"

# Check Python
if command -v python3 &> /dev/null; then
    py_version=$(python3 --version 2>&1 | cut -d' ' -f2)
    py_major=$(echo $py_version | cut -d'.' -f1)
    py_minor=$(echo $py_version | cut -d'.' -f2)
    
    if [ "$py_major" -ge 3 ] && [ "$py_minor" -ge 8 ]; then
        echo -e "${GREEN}✓${NC} Python $py_version (meets requirement >= 3.8)"
    else
        echo -e "${YELLOW}⚠${NC} Python $py_version (recommend >= 3.8)"
    fi
else
    echo -e "${RED}✗${NC} Python3 not found"
    echo "  Install from python.org or use: brew install python3"
    all_good=false
fi

# Check UV
if ! check_command "uv" "UV package manager" "curl -LsSf https://astral.sh/uv/install.sh | sh"; then
    all_good=false
fi

# Check FFmpeg
if ! check_command "ffmpeg" "FFmpeg" "brew install ffmpeg"; then
    all_good=false
fi

echo ""
echo "Checking Environment:"
echo "---------------------"

# Check API key
if ! check_env "OPENAI_API_KEY" "sk-your-api-key-here"; then
    all_good=false
fi

echo ""
echo "Checking Project Files:"
echo "-----------------------"

# Check if we're in the right directory or if files exist
files_to_check=("voice_dictate.py" "pyproject.toml" "README.md")
files_found=true

for file in "${files_to_check[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $file found"
    else
        echo -e "${RED}✗${NC} $file not found"
        files_found=false
        all_good=false
    fi
done

if [ "$files_found" = false ]; then
    echo -e "${YELLOW}  Make sure you're in the Voice_Dictate directory${NC}"
fi

echo ""
echo "Checking Audio Devices:"
echo "-----------------------"

if command -v ffmpeg &> /dev/null; then
    # Try to list devices (suppress the full output, just check if it works)
    if ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -q "AVFoundation audio devices"; then
        echo -e "${GREEN}✓${NC} Audio devices detected"
        echo "  To see full list, run: python voice_dictate.py --list-devices"
    else
        echo -e "${YELLOW}⚠${NC} Could not detect audio devices"
        all_good=false
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping (FFmpeg not installed)"
fi

echo ""
echo "Testing Python Dependencies:"
echo "----------------------------"

if command -v uv &> /dev/null && [ -f "voice_dictate.py" ]; then
    # Try to import the required modules
    echo "Checking if dependencies are installed..."
    
    if uv run python -c "import openai; print('✓ openai installed')" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} openai package available"
    else
        echo -e "${YELLOW}⚠${NC} openai package not installed"
        echo "  Run: uv pip install openai"
        all_good=false
    fi
    
    if uv run python -c "import pyperclip; print('✓ pyperclip installed')" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} pyperclip package available"
    else
        echo -e "${YELLOW}⚠${NC} pyperclip package not installed"
        echo "  Run: uv pip install pyperclip"
        all_good=false
    fi
else
    echo -e "${YELLOW}⚠${NC} Skipping (UV or project files not available)"
fi

echo ""
echo "========================================="

if [ "$all_good" = true ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo ""
    echo "You're ready to use Voice Dictate!"
    echo ""
    echo "Quick test commands:"
    echo "  1. List devices:  uv run python voice_dictate.py --list-devices"
    echo "  2. Test 3-second recording:  uv run python voice_dictate.py --duration 3"
    echo "  3. Show help:  uv run python voice_dictate.py --help"
    echo ""
    echo "Next step: Set up the hotkey following SETUP_GUIDE.md"
else
    echo -e "${YELLOW}⚠ Some checks failed${NC}"
    echo ""
    echo "Please fix the issues above, then run this test again."
    echo "Refer to README.md and SETUP_GUIDE.md for detailed instructions."
fi

echo "========================================="