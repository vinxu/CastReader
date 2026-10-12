#!/usr/bin/env python3
"""Capture native Duo inner-display pixels requested by the genuine UI test.

This process only captures screenshots. The XCTest workflow controls the app;
Device Hub controls folding. No image resizing, app fixtures or account changes.
"""
import argparse
import hashlib
import json
import re
import struct
import subprocess
import time
from pathlib import Path


def serve(output: Path, device: str, display: str, timeout: float, closed: bool = False) -> None:
    queue = output / "capture-requests"
    queue.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + timeout
    print(f"Native Duo capture host ready: {queue}", flush=True)
    while time.monotonic() < deadline:
        for request in sorted(queue.glob("*.request.json")):
            token = request.name.removesuffix(".request.json")
            if not re.fullmatch(r"[A-Fa-f0-9-]{36}", token):
                continue
            reply = queue / f"{token}.response.json"
            if reply.exists():
                continue
            response = {"token": token, "status": "error"}
            temporary = queue / f"{token}.tmp.png"
            try:
                payload = json.loads(request.read_text())
                if payload.get("token") != token:
                    raise ValueError("Request token mismatch")
                subprocess.run(["xcrun", "simctl", "io", device, "screenshot",
                                f"--display={display}", str(temporary)],
                               check=True, capture_output=True, timeout=20)
                data = temporary.read_bytes()
                if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
                    raise ValueError("Capture did not return PNG pixels")
                width, height = struct.unpack(">II", data[16:24])
                if (width, height) != ((1398, 2034) if closed else (2853, 2007)):
                    raise ValueError(f"Unexpected Duo framebuffer dimensions: {width}x{height}")
                temporary.replace(queue / f"{token}.png")
                response.update(status="ok", width=width, height=height,
                                sha256=hashlib.sha256(data).hexdigest(),
                                device=device, display=display,
                                name=payload.get("name"), captured_at=time.time())
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                response["error"] = str(error)
            pending = reply.with_suffix(".tmp")
            pending.write_text(json.dumps(response, indent=2) + "\n")
            pending.replace(reply)
            print(f"{response.get('name', token)}: {response['status']}", flush=True)
        time.sleep(0.2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device", required=True, help="Exact Duo simulator UDID")
    parser.add_argument("--display", required=True, help="Inner display identifier from simctl io enumerate")
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--closed", action="store_true", help="Capture the native upright outer display")
    args = parser.parse_args()
    serve(args.output.resolve(), args.device, args.display, args.timeout, args.closed)
