#!/usr/bin/env python3
"""Timestamp and sanitize the installation transcript before persisting it."""
import datetime as dt
import re
import sys

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
URL = re.compile(r"https?://[^\s<>\"']+")
TOKEN = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|[yt][01]_[A-Za-z0-9_-]{12,})")
SECRET = re.compile(r"(?i)(\b(?:password|passwd|token|secret|api[_-]?key|authorization)\b\s*[:=]\s*)(?:Bearer\s+)?[^\s,;]+")


def sanitize(text):
    text = ANSI.sub("", text).replace("\r", "")
    def clean_url(match):
        value = match.group(0).split("?", 1)[0].split("#", 1)[0]
        return re.sub(r"(https?://)[^/@]+@", r"\1<credentials-masked>@", value)
    return SECRET.sub(r"\1<masked>", TOKEN.sub("<masked>", URL.sub(clean_url, text)))


def main():
    try:
        with open(sys.argv[1], "a", encoding="utf-8", buffering=1) as log:
            for line in sys.stdin:
                clean = sanitize(line.rstrip("\n"))
                stamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
                log.write(f"[{stamp}] {clean}\n")
                print(clean, flush=True)
    except (OSError, BrokenPipeError):
        print("[FAIL] Не удалось записать журнал: проверьте место и права доступа.", file=sys.stderr)
        return 74
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
