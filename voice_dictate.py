#!/usr/bin/env python3
"""
Voice Dictation Tool for macOS
===============================

This script records audio from your microphone, transcribes it using OpenAI's Whisper API,
and automatically places the text in your clipboard (and optionally pastes it).

Author: Your Engineering Team
Date: 2025
"""

import os
import sys
import time
import tempfile
import subprocess
import argparse
import json
from pathlib import Path
from typing import Optional, Dict, Any
from datetime import datetime

# Try to load .env file if it exists
try:
    from dotenv import load_dotenv
    env_path = Path(__file__).parent / '.env'
    if env_path.exists():
        load_dotenv(env_path)
        print(f"✅ Loaded API key from .env file")
except ImportError:
    # dotenv not installed, will use environment variables only
    pass

# Third-party imports (these will be managed by UV)
try:
    from openai import OpenAI
    import pyperclip
except ImportError as e:
    print(f"Error: Required package not found: {e}")
    print("Please run: uv sync")
    sys.exit(1)


class VoiceDictate:
    """Main class for voice dictation functionality."""
    
    def __init__(self, api_key: Optional[str] = None):
        """
        Initialize the Voice Dictate system.
        
        Args:
            api_key: OpenAI API key. If not provided, will look for OPENAI_API_KEY environment variable.
        """
        self.api_key = api_key or os.environ.get('OPENAI_API_KEY')
        if not self.api_key:
            raise ValueError(
                "OpenAI API key not found. Please set OPENAI_API_KEY environment variable "
                "or pass it as an argument."
            )
        
        self.client = OpenAI(api_key=self.api_key)
        self.temp_dir = Path(tempfile.gettempdir()) / "voice_dictate"
        self.temp_dir.mkdir(exist_ok=True)
        
    def check_dependencies(self) -> bool:
        """
        Check if all required system dependencies are installed.
        
        Returns:
            bool: True if all dependencies are present, False otherwise.
        """
        # Check for ffmpeg
        try:
            result = subprocess.run(
                ['ffmpeg', '-version'],
                capture_output=True,
                text=True,
                check=False
            )
            if result.returncode != 0:
                print("Error: ffmpeg is not installed or not working properly.")
                print("Install it with: brew install ffmpeg")
                return False
        except FileNotFoundError:
            print("Error: ffmpeg is not installed.")
            print("Install it with: brew install ffmpeg")
            return False
            
        return True
    
    def list_audio_devices(self) -> Dict[str, Any]:
        """
        List available audio input devices using ffmpeg.
        
        Returns:
            Dict containing device information
        """
        try:
            # Run ffmpeg command to list devices
            result = subprocess.run(
                ['ffmpeg', '-f', 'avfoundation', '-list_devices', 'true', '-i', ''],
                capture_output=True,
                text=True,
                check=False
            )
            
            # Parse the stderr output (ffmpeg outputs device list to stderr)
            output = result.stderr
            devices = {"audio": [], "video": []}
            
            lines = output.split('\n')
            current_type = None
            
            for line in lines:
                if 'AVFoundation video devices:' in line:
                    current_type = 'video'
                elif 'AVFoundation audio devices:' in line:
                    current_type = 'audio'
                elif current_type and '] ' in line and '[' in line:
                    # Parse device line like "[0] Built-in Microphone"
                    parts = line.split('] ', 1)
                    if len(parts) == 2:
                        device_id = parts[0].split('[')[-1]
                        device_name = parts[1].strip()
                        devices[current_type].append({
                            'id': device_id,
                            'name': device_name
                        })
            
            return devices
            
        except Exception as e:
            print(f"Error listing devices: {e}")
            return {"audio": [], "video": []}
    
    def record_audio(
        self,
        duration: int = 10,
        device_id: str = ":0",
        sample_rate: int = 16000,
        show_progress: bool = True
    ) -> Path:
        """
        Record audio from the microphone using ffmpeg.
        
        Args:
            duration: Recording duration in seconds
            device_id: Audio device ID (use list_audio_devices to find available devices)
            sample_rate: Sample rate in Hz (16000 is recommended for speech)
            show_progress: Whether to show recording progress
            
        Returns:
            Path to the recorded audio file
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_file = self.temp_dir / f"recording_{timestamp}.wav"
        
        # Build ffmpeg command
        # -f avfoundation: Use macOS AVFoundation for audio capture
        # -i :device_id: Select audio input device
        # -t duration: Record for specified duration
        # -ar sample_rate: Set audio sample rate
        # -ac 1: Mono audio (1 channel)
        # -acodec pcm_s16le: 16-bit PCM audio codec
        cmd = [
            'ffmpeg',
            '-f', 'avfoundation',
            '-i', device_id,
            '-t', str(duration),
            '-ar', str(sample_rate),
            '-ac', '1',
            '-acodec', 'pcm_s16le',
            '-y',  # Overwrite output file if it exists
            str(output_file)
        ]
        
        if show_progress:
            print(f"🎙️  Recording for {duration} seconds...")
            print("Speak now...")
            
        try:
            # Run ffmpeg with minimal output
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True
            )
            
            if show_progress:
                print("✅ Recording complete!")
                
            return output_file
            
        except subprocess.CalledProcessError as e:
            print(f"Error during recording: {e}")
            if e.stderr:
                print(f"ffmpeg error: {e.stderr}")
            raise
    
    def transcribe_audio(
        self,
        audio_file: Path,
        model: str = "whisper-1",
        language: Optional[str] = None,
        prompt: Optional[str] = None,
        temperature: float = 0.0
    ) -> str:
        """
        Transcribe audio file using OpenAI's Whisper API.
        
        Args:
            audio_file: Path to the audio file to transcribe
            model: Model to use (whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe)
            language: Language code (e.g., 'en' for English, 'es' for Spanish)
            prompt: Optional prompt to guide the model's style
            temperature: Temperature for sampling (0.0 for deterministic)
            
        Returns:
            Transcribed text
        """
        print(f"🔄 Transcribing with {model}...")
        
        try:
            with open(audio_file, 'rb') as f:
                # Prepare transcription parameters
                params = {
                    'model': model,
                    'file': f,
                    'temperature': temperature
                }
                
                if language:
                    params['language'] = language
                    
                if prompt:
                    params['prompt'] = prompt
                
                # Call OpenAI API
                response = self.client.audio.transcriptions.create(**params)
                
            print("✅ Transcription complete!")
            return response.text
            
        except Exception as e:
            print(f"Error during transcription: {e}")
            raise
    
    def copy_to_clipboard(self, text: str) -> None:
        """
        Copy text to the system clipboard.
        
        Args:
            text: Text to copy to clipboard
        """
        try:
            pyperclip.copy(text)
            print("📋 Text copied to clipboard!")
        except Exception as e:
            print(f"Error copying to clipboard: {e}")
            # Fallback to pbcopy if pyperclip fails
            try:
                subprocess.run(
                    ['pbcopy'],
                    input=text.encode('utf-8'),
                    check=True
                )
                print("📋 Text copied to clipboard (using pbcopy)!")
            except Exception as e2:
                print(f"Failed to copy to clipboard: {e2}")
                raise
    
    def simulate_paste(self) -> None:
        """
        Simulate Command+V to paste the clipboard content.
        Uses AppleScript to send the keyboard shortcut.
        
        Note: This requires accessibility permissions for the terminal/app.
        """
        try:
            # AppleScript to simulate Cmd+V
            applescript = '''
            tell application "System Events"
                keystroke "v" using command down
            end tell
            '''
            
            subprocess.run(
                ['osascript', '-e', applescript],
                check=True,
                capture_output=True
            )
            print("📝 Text pasted!")
            
        except subprocess.CalledProcessError as e:
            print(f"Warning: Could not simulate paste (Cmd+V).")
            print("The text is still in your clipboard - you can paste it manually.")
            print("To enable auto-paste, grant accessibility permissions to Terminal/Python.")
    
    def cleanup_old_recordings(self, keep_last: int = 5) -> None:
        """
        Clean up old recording files, keeping only the most recent ones.
        
        Args:
            keep_last: Number of recent recordings to keep
        """
        try:
            recordings = sorted(
                self.temp_dir.glob("recording_*.wav"),
                key=lambda f: f.stat().st_mtime,
                reverse=True
            )
            
            # Remove old recordings
            for recording in recordings[keep_last:]:
                recording.unlink()
                
        except Exception as e:
            # Don't fail the main operation if cleanup fails
            pass
    
    def dictate(
        self,
        duration: int = 10,
        model: str = "whisper-1",
        auto_paste: bool = True,
        device_id: str = ":0",
        language: Optional[str] = None,
        prompt: Optional[str] = None,
        show_text: bool = True
    ) -> str:
        """
        Main dictation workflow: record, transcribe, and copy/paste.
        
        Args:
            duration: Recording duration in seconds
            model: Whisper model to use
            auto_paste: Whether to automatically paste after copying
            device_id: Audio device ID
            language: Language code for transcription
            prompt: Optional prompt for the model
            show_text: Whether to print the transcribed text
            
        Returns:
            The transcribed text
        """
        # Check dependencies
        if not self.check_dependencies():
            sys.exit(1)
        
        try:
            # Record audio
            audio_file = self.record_audio(
                duration=duration,
                device_id=device_id,
                show_progress=True
            )
            
            # Transcribe audio
            text = self.transcribe_audio(
                audio_file=audio_file,
                model=model,
                language=language,
                prompt=prompt
            )
            
            # Copy to clipboard
            self.copy_to_clipboard(text)
            
            # Show transcribed text if requested
            if show_text:
                print(f"\n📝 Transcribed text:\n{text}\n")
            
            # Auto-paste if requested
            if auto_paste:
                time.sleep(0.1)  # Small delay to ensure clipboard is ready
                self.simulate_paste()
            
            # Clean up old recordings
            self.cleanup_old_recordings()
            
            return text
            
        except Exception as e:
            print(f"Error during dictation: {e}")
            raise


def main():
    """Main entry point for the voice dictation tool."""
    
    parser = argparse.ArgumentParser(
        description="Voice Dictation Tool - Record, transcribe, and paste text using OpenAI Whisper",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic usage (10 second recording)
  python voice_dictate.py
  
  # Record for 5 seconds
  python voice_dictate.py --duration 5
  
  # Use a specific model
  python voice_dictate.py --model gpt-4o-mini-transcribe
  
  # Specify language
  python voice_dictate.py --language en
  
  # List available audio devices
  python voice_dictate.py --list-devices
  
  # Use a specific audio device
  python voice_dictate.py --device ":1"
  
  # Don't auto-paste (just copy to clipboard)
  python voice_dictate.py --no-paste
        """
    )
    
    parser.add_argument(
        '--duration', '-d',
        type=int,
        default=10,
        help='Recording duration in seconds (default: 10)'
    )
    
    parser.add_argument(
        '--model', '-m',
        choices=['whisper-1', 'gpt-4o-transcribe', 'gpt-4o-mini-transcribe'],
        default='whisper-1',
        help='Whisper model to use (default: whisper-1)'
    )
    
    parser.add_argument(
        '--language', '-l',
        type=str,
        help='Language code (e.g., en, es, fr, de, zh)'
    )
    
    parser.add_argument(
        '--prompt', '-p',
        type=str,
        help='Optional prompt to guide transcription style'
    )
    
    parser.add_argument(
        '--device', 
        type=str,
        default=':0',
        help='Audio device ID (default: ":0" for default microphone)'
    )
    
    parser.add_argument(
        '--no-paste',
        action='store_true',
        help="Don't auto-paste, just copy to clipboard"
    )
    
    parser.add_argument(
        '--list-devices',
        action='store_true',
        help='List available audio devices and exit'
    )
    
    parser.add_argument(
        '--api-key',
        type=str,
        help='OpenAI API key (otherwise uses OPENAI_API_KEY env var)'
    )
    
    parser.add_argument(
        '--quiet', '-q',
        action='store_true',
        help="Don't show the transcribed text"
    )
    
    args = parser.parse_args()
    
    # Initialize the dictation system
    try:
        dictate = VoiceDictate(api_key=args.api_key)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    
    # List devices if requested
    if args.list_devices:
        print("Available audio devices:")
        print("-" * 40)
        devices = dictate.list_audio_devices()
        
        if devices['audio']:
            for device in devices['audio']:
                print(f"  [{device['id']}] {device['name']}")
        else:
            print("  No audio devices found")
        
        print("\nTo use a specific device, run:")
        print('  python voice_dictate.py --device ":<device_id>"')
        sys.exit(0)
    
    # Run the main dictation workflow
    try:
        text = dictate.dictate(
            duration=args.duration,
            model=args.model,
            auto_paste=not args.no_paste,
            device_id=args.device,
            language=args.language,
            prompt=args.prompt,
            show_text=not args.quiet
        )
        
    except KeyboardInterrupt:
        print("\n\n⛔ Dictation cancelled by user")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()