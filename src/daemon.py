"""
eva daemon — background process that listens on a Unix socket and
provides shell command predictions via the DeepSeek API.

Protocol (newline-delimited JSON over Unix socket):
  Request:  {"seq": 1, "buffer": "git com", "cwd": "/tmp", "history": ["ls"]}
  Response: {"seq": 1, "prediction": "mit -m 'fix'"}
"""

import os
import sys
import json
import time
import signal
import socket
import asyncio
import logging
from pathlib import Path

# Add parent to path so we can import predictor
sys.path.insert(0, str(Path(__file__).parent))
from predictor import predict

log = logging.getLogger("eva.daemon")

# --- Config ---
EVA_HOME = Path(os.environ.get("EVA_HOME", Path.home() / ".eva"))
SOCKET_PATH = EVA_HOME / "eva.sock"
PID_FILE = EVA_HOME / "eva.pid"
LOG_FILE = EVA_HOME / "eva.log"
DEBOUNCE_MS = int(os.environ.get("EVA_DEBOUNCE_MS", "100"))  # debounce window

# Global state for debounce: track the latest sequence number seen
_latest_seq = 0
_last_request_time = 0.0


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Handle a single client connection."""
    global _latest_seq, _last_request_time

    try:
        # Read one line (JSON request)
        data = await asyncio.wait_for(reader.readline(), timeout=30.0)
        if not data:
            return

        request_str = data.decode("utf-8").strip()
        if not request_str:
            return

        try:
            request = json.loads(request_str)
        except json.JSONDecodeError as e:
            log.error("Invalid JSON: %s", e)
            return

        seq = request.get("seq", 0)
        buffer = request.get("buffer", "")
        cwd = request.get("cwd", "/")
        history = request.get("history", [])

        # Debounce: if this isn't the latest request, ignore it
        # (we process the latest only when it arrives)
        now = time.monotonic()
        if seq < _latest_seq:
            log.debug("stale request seq=%d (latest=%d), dropping", seq, _latest_seq)
            return

        _latest_seq = seq
        _last_request_time = now

        # Small delay to allow rapid typing to settle, then check if superseded
        await asyncio.sleep(DEBOUNCE_MS / 1000.0)

        if seq < _latest_seq:
            log.debug("request seq=%d superseded by seq=%d during debounce", seq, _latest_seq)
            return

        # Call the predictor
        prediction = predict(buffer, cwd, history)

        response = json.dumps({"seq": seq, "prediction": prediction}) + "\n"
        writer.write(response.encode("utf-8"))
        await writer.drain()

    except asyncio.TimeoutError:
        log.debug("client read timeout")
    except ConnectionResetError:
        pass
    except Exception:
        log.exception("handle_client error")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def run_server():
    """Start the Unix socket server."""
    # Ensure eva home exists
    EVA_HOME.mkdir(parents=True, exist_ok=True)

    # Remove stale socket if it exists
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()

    server = await asyncio.start_unix_server(
        handle_client,
        path=str(SOCKET_PATH),
        limit=65536,  # 64KB buffer
    )

    # Set socket permissions so only the user can access it
    os.chmod(str(SOCKET_PATH), 0o600)

    # Write PID file
    PID_FILE.write_text(str(os.getpid()))

    log.info("eva daemon listening on %s (pid=%d)", SOCKET_PATH, os.getpid())
    print(f"eva daemon started (pid={os.getpid()}, socket={SOCKET_PATH})")

    async with server:
        await server.serve_forever()


def stop_daemon():
    """Stop a running daemon by reading the PID file."""
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, signal.SIGTERM)
            print(f"eva daemon stopped (pid={pid})")
        except ProcessLookupError:
            print("eva daemon was not running (stale PID file)")
        except Exception as e:
            print(f"Failed to stop daemon: {e}")
        PID_FILE.unlink(missing_ok=True)
    else:
        print("eva daemon is not running (no PID file)")


def status_daemon():
    """Check if the daemon is running."""
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, 0)  # signal 0 just checks existence
            print(f"eva daemon is running (pid={pid})")
        except (ProcessLookupError, ValueError):
            print("eva daemon is not running (stale PID file)")
    else:
        print("eva daemon is not running")


def main():
    """CLI entry point: start | stop | status."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        handlers=[
            logging.FileHandler(str(LOG_FILE)),
            logging.StreamHandler(sys.stderr),
        ],
    )

    cmd = sys.argv[1] if len(sys.argv) > 1 else "start"

    if cmd == "start":
        asyncio.run(run_server())
    elif cmd == "stop":
        stop_daemon()
    elif cmd == "status":
        status_daemon()
    else:
        print(f"Usage: {sys.argv[0]} {{start|stop|status}}")
        sys.exit(1)


if __name__ == "__main__":
    main()
