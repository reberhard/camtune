#!/usr/bin/env python3
"""Inspect or exercise one installed Ojo accessibility control.

Inspection is read-only. --click requires --execute and an expected installed
binary SHA so a receipt cannot silently describe a different build. Hardware
readback and physical observation are separate acceptance fields; neither is
inferred from clicking a button. Output can be retained by the operator runner.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def applescript(source):
    result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def inspect():
    return applescript('''tell application "System Events"
      tell process "Ojo"
        set resultLines to ""
        repeat with element in entire contents
          try
            set identifier to value of attribute "AXIdentifier" of element
            if identifier is not missing value then
              set resultLines to resultLines & identifier & " | " & role of element & linefeed
            end if
          end try
        end repeat
        return resultLines
      end tell
    end tell''')


def click(identifier):
    if not re.fullmatch(r"[a-z0-9-]+", identifier):
        raise ValueError("Invalid control identifier")
    return applescript('''tell application "System Events"
      tell process "Ojo"
        repeat with element in entire contents
          try
            set identifier to value of attribute "AXIdentifier" of element
            if identifier is "''' + identifier + '''" then
              click element
              return "clicked"
            end if
          end try
        end repeat
        error "Control not found or not clickable"
      end tell
    end tell''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--click")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--expected-binary-sha")
    args = parser.parse_args()
    path = Path("/Applications/Ojo.app/Contents/MacOS/Ojo")
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if args.click:
        if not args.execute or args.expected_binary_sha != sha:
            parser.error("Click requires --execute and matching --expected-binary-sha")
        outcome = click(args.click)
        print(json.dumps({"build_sha256": sha, "ui_control": args.click, "at": time.time(),
            "ui_action": outcome, "device_readback": "pending", "physical_observation": "pending"}))
    else:
        print(inspect())


if __name__ == "__main__":
    main()
