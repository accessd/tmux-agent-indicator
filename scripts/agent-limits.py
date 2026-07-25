#!/usr/bin/env python3

import argparse
import base64
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path


CLAUDE_LABEL = "C"
CODEX_LABEL = "X"
TAIL_BYTES = 512 * 1024
MAX_CODEX_ROLLOUTS = 25
OUTPUT_CACHE_VERSION = 2


def cache_dir():
    override = os.environ.get("TMUX_AGENT_LIMITS_CACHE_DIR")
    if override:
        return Path(override).expanduser()
    root = os.environ.get("XDG_CACHE_HOME")
    if root:
        return Path(root).expanduser() / "tmux-agent-indicator"
    return Path.home() / ".cache" / "tmux-agent-indicator"


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None


def write_json(path, payload):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        delete=False,
    ) as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.write("\n")
        temp_path = Path(handle.name)
    temp_path.chmod(0o600)
    temp_path.replace(path)


def try_write_json(path, payload):
    try:
        write_json(path, payload)
    except OSError:
        pass


def epoch_seconds(value):
    if isinstance(value, (int, float)) and math.isfinite(value):
        return int(value)
    if not isinstance(value, str) or not value:
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def number(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return float(value)
    return None


def window(raw, used_key, minutes):
    if not isinstance(raw, dict):
        return None
    used = number(raw.get(used_key))
    if used is None:
        return None
    raw_minutes = number(raw.get("window_minutes"))
    return {
        "used_percent": used,
        "resets_at": epoch_seconds(raw.get("resets_at")),
        "window_minutes": int(raw_minutes) if raw_minutes is not None else minutes,
    }


def claude_json_candidate():
    path = Path(os.environ.get("CLAUDE_CONFIG_JSON", str(Path.home() / ".claude.json"))).expanduser()
    payload = read_json(path)
    if not isinstance(payload, dict):
        return None
    cached = payload.get("cachedUsageUtilization")
    if not isinstance(cached, dict):
        return None
    utilization = cached.get("utilization")
    if not isinstance(utilization, dict):
        return None
    windows = [
        window(utilization.get("five_hour"), "utilization", 300),
        window(utilization.get("seven_day"), "utilization", 10080),
    ]
    windows = [item for item in windows if item]
    if not windows:
        return None
    fetched = number(cached.get("fetchedAtMs"))
    if fetched is None:
        try:
            fetched = path.stat().st_mtime * 1000
        except OSError:
            fetched = 0
    return {"fetched_at": int(fetched / 1000), "windows": windows}


def claude_statusline_candidate():
    payload = read_json(cache_dir() / "claude-limits.json")
    if not isinstance(payload, dict) or not isinstance(payload.get("windows"), list):
        return None
    return payload


def claude_candidates():
    candidates = [candidate for candidate in (claude_json_candidate(), claude_statusline_candidate()) if candidate]
    return sorted(candidates, key=lambda candidate: candidate.get("fetched_at", 0), reverse=True)


def codex_home():
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()


def newest_rollouts():
    sessions = codex_home() / "sessions"
    matches = []
    try:
        for path in sessions.glob("*/*/*/rollout-*.jsonl"):
            try:
                matches.append((path.stat().st_mtime, path))
            except OSError:
                continue
    except OSError:
        return []
    matches.sort(key=lambda item: item[0], reverse=True)
    return matches[:MAX_CODEX_ROLLOUTS]


def tail_lines(path):
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - TAIL_BYTES))
            data = handle.read()
    except OSError:
        return []
    if size > TAIL_BYTES:
        data = data.split(b"\n", 1)[-1]
    return data.decode("utf-8", errors="ignore").splitlines()


def codex_candidate():
    for mtime, path in newest_rollouts():
        for line in reversed(tail_lines(path)):
            try:
                event = json.loads(line)
            except (ValueError, TypeError):
                continue
            if not isinstance(event, dict):
                continue
            payload = event.get("payload")
            if event.get("type") != "event_msg" or not isinstance(payload, dict) or payload.get("type") != "token_count":
                continue
            rate_limits = payload.get("rate_limits")
            if not isinstance(rate_limits, dict):
                info = payload.get("info")
                rate_limits = info.get("rate_limits") if isinstance(info, dict) else None
            if not isinstance(rate_limits, dict):
                continue
            windows = [
                window(rate_limits.get("primary"), "used_percent", None),
                window(rate_limits.get("secondary"), "used_percent", None),
            ]
            windows = [item for item in windows if item]
            if windows:
                return {"fetched_at": int(mtime), "windows": windows}
    return None


def window_label(minutes):
    if not minutes:
        return "limit"
    if minutes % 10080 == 0:
        return f"{minutes // 10080 * 7}d"
    if minutes % 1440 == 0:
        return f"{minutes // 1440}d"
    if minutes % 60 == 0:
        return f"{minutes // 60}h"
    return f"{minutes}m"


def format_candidate(label, candidate, now):
    if not candidate:
        return ""
    fetched_at = candidate.get("fetched_at", 0)
    valid = []
    for item in candidate.get("windows", []):
        resets_at = item.get("resets_at")
        if resets_at is not None and resets_at <= now:
            continue
        if resets_at is None and now - fetched_at > 7200:
            continue
        valid.append(item)
    if not valid:
        return ""
    valid.sort(key=lambda item: item.get("window_minutes") or sys.maxsize)
    selected = valid[0]
    used = max(0, min(100, int(math.floor(selected["used_percent"] + 0.5))))
    return f"{label} {window_label(selected.get('window_minutes'))} {used}% used"


def format_candidates(label, candidates, now):
    for candidate in candidates:
        rendered = format_candidate(label, candidate, now)
        if rendered:
            return rendered
    return ""


def collect(providers, now):
    parts = []
    for provider in providers:
        if provider == "claude":
            rendered = format_candidates(CLAUDE_LABEL, claude_candidates(), now)
        elif provider == "codex":
            rendered = format_candidate(CODEX_LABEL, codex_candidate(), now)
        else:
            continue
        if rendered:
            parts.append(rendered)
    return " · ".join(parts)


def render(args):
    providers = [item.strip().lower() for item in args.providers.split(",") if item.strip()]
    now = int(time.time())
    output_cache = cache_dir() / "limits-output.json"
    if not args.no_cache and args.cache_seconds > 0:
        cached = read_json(output_cache)
        if (
            isinstance(cached, dict)
            and cached.get("version") == OUTPUT_CACHE_VERSION
            and cached.get("providers") == providers
            and cached.get("expires_at", 0) > now
        ):
            print(cached.get("output", ""))
            return 0
    output = collect(providers, now)
    if not args.no_cache and args.cache_seconds > 0:
        try_write_json(
            output_cache,
            {
                "version": OUTPUT_CACHE_VERSION,
                "expires_at": now + args.cache_seconds,
                "providers": providers,
                "output": output,
            },
        )
    print(output)
    return 0


def cache_claude_statusline(payload):
    try:
        parsed = json.loads(payload)
    except (ValueError, TypeError):
        return
    rate_limits = parsed.get("rate_limits") if isinstance(parsed, dict) else None
    if not isinstance(rate_limits, dict):
        return
    windows = [
        window(rate_limits.get("five_hour"), "used_percentage", 300),
        window(rate_limits.get("seven_day"), "used_percentage", 10080),
    ]
    windows = [item for item in windows if item]
    if windows:
        try_write_json(
            cache_dir() / "claude-limits.json",
            {"fetched_at": int(time.time()), "windows": windows},
        )


def claude_statusline(args):
    payload = sys.stdin.buffer.read()
    cache_claude_statusline(payload.decode("utf-8", errors="replace"))
    if not args.previous_command_base64:
        return 0
    try:
        command = base64.b64decode(args.previous_command_base64).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return 1
    return subprocess.run(command, shell=True, input=payload).returncode


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command")
    statusline = subparsers.add_parser("claude-statusline")
    statusline.add_argument("--previous-command-base64", default="")
    parser.add_argument("--providers", default="claude,codex")
    parser.add_argument("--cache-seconds", type=int, default=60)
    parser.add_argument("--no-cache", action="store_true")
    args = parser.parse_args()
    if args.command == "claude-statusline":
        return claude_statusline(args)
    return render(args)


if __name__ == "__main__":
    raise SystemExit(main())
