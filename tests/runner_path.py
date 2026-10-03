#!/usr/bin/env python3
"""Check the runner's exact initialization against special checkout paths."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import cast

from helper_test_support import raise_test_failure


def runtime_paths(repository: Path, command: str | None = None) -> list[str]:
    """Read Neovim's actual runtime paths, not the Lua option's comma splitter."""
    arguments = ["nvim", "--headless", "--clean", "-u", "NONE", "-i", "NONE"]
    if command is not None:
        arguments.extend(["--cmd", command])
    arguments.extend(
        [
            "-c",
            "lua io.write(vim.json.encode(vim.api.nvim_list_runtime_paths()))",
            "-c",
            "qa!",
        ]
    )
    return cast(
        "list[str]",
        json.loads(
            subprocess.check_output(
                arguments,
                env=dict(os.environ, LINGUA_MOTION_TEST_REPO=str(repository)),
                text=True,
                encoding="utf-8",
                timeout=10,
            )
        ),
    )


def check_runner_path(command: str) -> None:
    """Require the supplied directory to become exactly one additional entry."""
    with tempfile.TemporaryDirectory(prefix="lingua-motion-path-") as directory:
        repository = Path(directory).resolve() / "test checkout,|back\\slash"
        repository.mkdir()
        baseline = runtime_paths(repository)
        paths = runtime_paths(repository, command)
        if paths != [str(repository), *baseline]:
            raise_test_failure(f"checkout path was not added as one entry: {paths!r}")
    print("runner path ok")


if __name__ == "__main__":
    check_runner_path(sys.argv[1])
