#!/usr/bin/env python3
"""Launch the Inganzo Node.js application and open it in a browser."""

import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import webbrowser
from pathlib import Path


ROOT = Path(__file__).parent.resolve()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Launch the Inganzo website")
    parser.add_argument("--port", type=int, default=3000, help="Port to use (default: 3000)")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind (default: 127.0.0.1)")
    parser.add_argument("--no-open", action="store_true", help="Do not open a browser")
    return parser.parse_args()


def wait_for_server(host: str, port: int, process: subprocess.Popen, timeout: int = 15) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and process.poll() is None:
        try:
            with socket.create_connection((host, port), timeout=1):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        print("Error: --port must be between 1 and 65535.", file=sys.stderr)
        return 2

    node = shutil.which("node")
    if not node:
        print("Error: Node.js is required. Install Node.js 18 or later.", file=sys.stderr)
        return 1
    if not (ROOT / "node_modules").is_dir():
        print("Dependencies are missing. Run `npm ci` in the project folder first.", file=sys.stderr)
        return 1

    environment = os.environ.copy()
    environment["HOST"] = args.host
    environment["PORT"] = str(args.port)
    url = f"http://{args.host}:{args.port}"
    process = subprocess.Popen([node, "server.js"], cwd=str(ROOT), env=environment)
    try:
        if not wait_for_server(args.host, args.port, process):
            returncode = process.poll()
            if returncode is None:
                print("Error: the server did not become ready within 15 seconds.", file=sys.stderr)
                returncode = 1
            else:
                print(f"Error: the server exited with status {returncode}.", file=sys.stderr)
            return returncode

        print(f"Inganzo is running at {url}")
        print(f"Library: {url}/library.html")
        print("Press Ctrl+C to stop.")
        if not args.no_open:
            webbrowser.open(url)
        while process.poll() is None:
            time.sleep(0.25)
        return process.returncode or 0
    except KeyboardInterrupt:
        print("\nStopping Inganzo…")
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        return 0
    finally:
        if process.poll() is None:
            process.terminate()


if __name__ == "__main__":
    raise SystemExit(main())
