#!/usr/bin/env python3
"""Run the board with a bounded, combined stdout/stderr log."""
import argparse
import os
from pathlib import Path
import signal
import subprocess


class RotatingLog:
    def __init__(self, path, size, copies):
        self.path = Path(path)
        self.size = size
        self.copies = copies
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open("ab", buffering=0)

    def rotate(self):
        self.file.close()
        for index in range(self.copies - 1, 0, -1):
            source = self.path if index == 1 else Path(f"{self.path}.{index - 1}")
            if source.exists():
                source.replace(f"{self.path}.{index}")
        self.file = self.path.open("wb", buffering=0)

    def write(self, data):
        while data:
            remaining = self.size - self.file.tell()
            if remaining <= 0:
                self.rotate()
                remaining = self.size
            self.file.write(data[:remaining])
            data = data[remaining:]

    def close(self):
        self.file.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=50 * 1024 * 1024)
    parser.add_argument("--copies", type=int, default=5)
    parser.add_argument("log")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.size <= 0 or args.copies < 2 or not args.command:
        parser.error("use a positive size, at least two copies, and a command")
    log = RotatingLog(args.log, args.size, args.copies)
    child = subprocess.Popen(args.command, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)

    def forward(signum, _frame):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    try:
        while chunk := os.read(child.stdout.fileno(), 65536):
            log.write(chunk)
        result = child.wait()
        return result if result >= 0 else 128 - result
    finally:
        log.close()
        child.stdout.close()
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
