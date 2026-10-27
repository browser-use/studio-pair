#!/usr/bin/env python3
"""Local source install and recovery. No sudo, downloads, drivers or default-device changes."""
import argparse
import fcntl
import json
import pathlib
import plistlib
import shutil
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path.home() / "Library/Application Support/StudioPair"
APP = pathlib.Path.home() / "Applications/Studio Pair.app"
BUNDLE_ID = "com.browseruse.studiopair"


def validate_app():
    if APP.exists():
        info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise SystemExit("Another app occupies the install path. Quit and move it before installing.")


def running():
    lock = RUNTIME / "app.lock"
    if not lock.exists():
        return False
    with lock.open("r+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True


def restore():
    engine = APP / "Contents/MacOS/studio-pair-engine"
    if not engine.exists():
        engine = ROOT / "build/Studio Pair.app/Contents/MacOS/studio-pair-engine"
    if (RUNTIME / "journal.json").exists():
        subprocess.run([str(engine), "restore", str(RUNTIME / "journal.json")], check=True, timeout=20)


def quit_app(disable_login=False):
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    if disable_login:
        # Launching even an inactive app unregisters its own SMAppService.
        subprocess.run([str(APP / "Contents/MacOS/StudioPair"), "--disable-login-and-quit"], check=True, timeout=25)
    elif running():
        (RUNTIME / "quit.request").touch()
    deadline = time.monotonic() + 20
    while running():
        if time.monotonic() >= deadline:
            raise SystemExit("Studio Pair has not quit. Use Quit Studio Pair in its menu, then retry.")
        time.sleep(0.2)
    restore()
    if disable_login:
        status = json.loads((RUNTIME / "status.json").read_text())
        if status["loginStatus"] not in (0, 3):
            raise SystemExit("Launch at login is still registered. Disable it in Studio Pair and retry.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "stop", "uninstall"))
    args = parser.parse_args()
    validate_app()
    if args.action == "install":
        subprocess.run([str(ROOT / "scripts/build.sh")], check=True)
        quit_app()
        APP.parent.mkdir(parents=True, exist_ok=True)
        # Keep one recoverable prior build, outside the application directory.
        backup = ROOT / "build/previous/Studio Pair.app"
        if APP.exists():
            if backup.exists():
                shutil.rmtree(backup)
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(APP), str(backup))
        try:
            shutil.copytree(ROOT / "build/Studio Pair.app", APP)
        except Exception:
            if APP.exists():
                shutil.rmtree(APP)
            if backup.exists():
                shutil.move(str(backup), str(APP))
            raise
        subprocess.run(["open", str(APP), "--args", "--show"], check=True)
        print("Installed. Use the menu-bar icon; Launch at login is optional.")
    elif args.action == "stop":
        if running():
            (RUNTIME / "stop.request").touch()
            deadline = time.monotonic() + 20
            while running():
                status = json.loads((RUNTIME / "status.json").read_text())
                if not status["enabled"] and not status["workerPID"] and not status["restoring"]:
                    break
                if time.monotonic() >= deadline:
                    raise SystemExit("Stop is pending. Quit Studio Pair from its menu and retry.")
                time.sleep(0.2)
        restore()
        print("Pairing stopped. Direct playback restored.")
    else:
        if APP.exists():
            quit_app(disable_login=True)
            shutil.rmtree(APP)
        else:
            restore()
        print("Uninstalled. Settings and recovery metadata remain in ~/Library/Application Support/StudioPair.")


if __name__ == "__main__":
    main()
