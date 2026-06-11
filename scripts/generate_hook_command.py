#!/usr/bin/env python3
"""Generate the shell command used by Claude Code and Codex hooks."""

import shlex
import sys


def generate(config_path: str, python_path: str, hook_path: str) -> str:
    return shlex.join([
        "env",
        f"THENOW_CONFIG_PATH={config_path}",
        python_path,
        hook_path,
    ])


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: generate_hook_command.py CONFIG PYTHON HOOK")
    print(generate(sys.argv[1], sys.argv[2], sys.argv[3]))
