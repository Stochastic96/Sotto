import os
import sys
import requests
from dotenv import load_dotenv
from google.antigravity import Agent, LocalAgentConfig

# Load environment variables from a .env file if present
load_dotenv()

# Define the custom tool to communicate with Sotto's PhoneRemote HTTP API
def send_command_to_sotto(command: str) -> str:
    """Sends a voice/text command to the local Sotto assistant running on macOS.
    
    Use this tool whenever the user asks to control their Mac system, run macOS actions,
    or delegate native commands (e.g., volume, brightness, window tiling, sleep, notes,
    reminders, opening apps, web searches, screen clicking, or Siri tasks).
    
    Args:
        command: The natural language command to send to Sotto, e.g., "set volume to 50 percent",
                 "open Safari", "mute", "sleep mac", "create a note: buy milk", "maximize window".
    """
    url = "http://localhost:52027/command"
    headers = {"Content-Type": "application/json"}
    payload = {"text": command}
    
    print(f"\n[TOOL] Forwarding command to Sotto: '{command}'...")
    try:
        response = requests.post(url, json=payload, headers=headers, timeout=5)
        if response.status_code == 200:
            return f"Successfully sent command to Sotto. Response: {response.text}"
        else:
            return f"Failed to send command to Sotto. Status code: {response.status_code}, Response: {response.text}"
    except requests.exceptions.RequestException as e:
        return (
            f"Error connecting to Sotto's PhoneRemote server: {e}.\n"
            "Please ensure Sotto is running on your Mac and the PhoneRemote listener is active."
        )

async def main():
    # Verify GEMINI_API_KEY is present
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key or api_key == "your_gemini_api_key_here":
        print("Error: GEMINI_API_KEY is not set.")
        print("Please obtain a Gemini API key from Google AI Studio:")
        print("  👉 https://aistudio.google.com/app/api-keys")
        print("\nThen set it in a '.env' file or your shell environment:")
        print("  export GEMINI_API_KEY=\"your_actual_api_key_here\"\n")
        sys.exit(1)

    # Configure the Antigravity Agent
    config = LocalAgentConfig(
        tools=[send_command_to_sotto],
        system_instructions=(
            "You are a helpful desktop assistant. You can control the user's macOS system "
            "by sending commands to Sotto, an on-device Mac assistant. "
            "When the user requests macOS control or system actions (like changing volume, "
            "launching apps, creating notes/reminders, or sleeping the Mac), formulate the request "
            "as a clear Sotto command and use the `send_command_to_sotto` tool."
        )
    )

    print("=====================================================================")
    print("🤖 Google Antigravity Agent - Sotto Integration Controller")
    print("=====================================================================")
    print("This agent forwards system commands to Sotto via its local HTTP server.")
    print("Starting interactive loop. Type 'exit' or 'quit' to end.\n")

    async with Agent(config) as agent:
        await agent.run_interactive_loop()

if __name__ == "__main__":
    import asyncio
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nAgent session ended.")
