#!/usr/bin/env python3
"""Native messaging host for the IRF Minutes extension.

Chrome extensions can't run git, so the panel's "Update now" button asks this
script to do it. The script lives inside the extension folder, so the
repository to update is simply its parent directory.

Protocol: each message is a 4-byte little-endian length followed by that many
bytes of JSON, on stdin and stdout.
"""

import json
import os
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRANCH = "main"
TIMEOUT = 120


def read_message():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    length = struct.unpack("<I", header)[0]
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))


def send_message(payload):
    data = json.dumps(payload).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def git(*args):
    return subprocess.run(
        ("git", "-C", REPO) + args,
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )


def version():
    try:
        with open(os.path.join(REPO, "manifest.json"), encoding="utf-8") as f:
            return json.load(f).get("version")
    except (OSError, ValueError):
        return None


def explain(output):
    """Turn the noisier git failures into something a user can act on."""
    if "local changes" in output or "would be overwritten" in output:
        return (
            "this folder has edits that aren't on GitHub. Run "
            "'git checkout -- .' in the extension folder to drop them, then try again."
        )
    if "not possible to fast-forward" in output or "diverging" in output:
        return (
            "this folder has commits that aren't on GitHub, so it can't fast-forward. "
            "Someone needs to sort the branch out by hand."
        )
    if "could not read" in output.lower() or "authentication" in output.lower():
        return "git couldn't reach GitHub. Check the network, or whether sign-in is needed."
    return output.strip()[:300]


def update():
    """Bring the folder up to date with origin/main, without discarding work."""
    before = version()
    steps = [("fetch", "origin", BRANCH), ("merge", "--ff-only", "origin/" + BRANCH)]
    for args in steps:
        result = git(*args)
        if result.returncode != 0:
            return {"ok": False, "before": before, "error": explain(result.stderr or result.stdout)}
    return {"ok": True, "before": before, "after": version()}


def main():
    message = read_message()
    if message is None:
        return
    if message.get("action") != "update":
        send_message({"ok": False, "error": "Unknown action."})
        return
    try:
        send_message(update())
    except subprocess.TimeoutExpired:
        send_message({"ok": False, "error": "git took too long to respond."})
    except OSError as err:
        send_message({"ok": False, "error": "Couldn't run git: %s" % err})


if __name__ == "__main__":
    main()
