"""Entry point for a dedicated Python/Passenger site, e.g. voice.metalcarcase.ru.

Copy this file into the subdomain's *separate* WSGI site directory.
Keep source and secrets outside the document root.
"""
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

# Store OAuth token and device key in HOME, never in the website's public files.
load_dotenv(Path.home() / ".watch5-voice-capture.env", override=False)

# Clone the GitHub repository here (independently of metalcarcase-production).
server_root = Path(
    os.environ.get("WATCH_APP_ROOT", str(Path.home() / "watch5-voice-capture" / "server"))
).expanduser()
sys.path.insert(0, str(server_root))

from app.wsgi import application  # noqa: E402
