#!/usr/bin/env python3
"""Native messaging host for the IRF Minutes extension.

Chrome extensions can't run git, so the panel's "Update now" button asks this
script to do it. The script lives inside the extension folder, so the
repository to update is simply its parent directory.

Protocol: each message is a 4-byte little-endian length followed by that many
bytes of JSON, on stdin and stdout.

Every run appends to updater/updater.log. To try an update by hand, outside
Chrome, run:   python updater/irf_updater.py --test
"""

import datetime
import json
import os
import struct
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LOG = os.path.join(HERE, "updater.log")
BRANCH = "main"
TIMEOUT = 120


def log(text):
    try:
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s  %s\n" % (stamp, text))
    except OSError:
        pass  # Logging must never be the reason an update fails.


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
    result = subprocess.run(
        ("git", "-C", REPO) + args,
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )
    log("git %s -> exit %d %s" % (" ".join(args), result.returncode, (result.stderr or result.stdout).strip()))
    return result


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
    try:
        for args in [("fetch", "origin", BRANCH), ("merge", "--ff-only", "origin/" + BRANCH)]:
            result = git(*args)
            if result.returncode != 0:
                return {"ok": False, "before": before, "error": explain(result.stderr or result.stdout)}
    except subprocess.TimeoutExpired:
        return {"ok": False, "before": before, "error": "git took too long to respond."}
    except OSError as err:
        return {"ok": False, "before": before, "error": "couldn't run git (%s). Is Git installed and on PATH?" % err}
    return {"ok": True, "before": before, "after": version()}


def main():
    log("started: python %s, repo %s" % (sys.version.split()[0], REPO))

    if "--check" in sys.argv:
        # What the installers run: proves Python starts and git can see this
        # folder, without changing anything.
        try:
            result = git("rev-parse", "--is-inside-work-tree")
            ok = result.returncode == 0 and result.stdout.strip() == "true"
            detail = "git sees the extension folder" if ok else explain(result.stderr or result.stdout)
        except OSError as err:
            ok, detail = False, "couldn't run git (%s). Is Git installed and on PATH?" % err
        print("%s: Python %s, %s" % ("OK" if ok else "PROBLEM", sys.version.split()[0], detail))
        sys.exit(0 if ok else 1)

    if "--test" in sys.argv:
        result = update()
        log("test result: %s" % result)
        print(json.dumps(result, indent=2))
        return

    message = read_message()
    log("received: %s" % message)
    if message is None:
        return
    result = update() if message.get("action") == "update" else {"ok": False, "error": "Unknown action."}
    log("result: %s" % result)
    send_message(result)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log("crashed:\n" + traceback.format_exc())
        raise
