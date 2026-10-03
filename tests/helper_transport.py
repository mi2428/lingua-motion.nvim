#!/usr/bin/env python3
"""Check complete JSONL deadlines with an independent signal watchdog."""

from __future__ import annotations

import json
import signal
import subprocess
import sys
import time
from typing import NoReturn

from helper_test_support import (
    RequestPayload,
    raise_test_failure,
    require_text_stream,
    send_json_request,
    terminate_helper_process,
)

TIMEOUT_SECONDS = 0.2
WATCHDOG_SECONDS = 3


def watchdog_expired(_signum: int, _frame: object) -> NoReturn:
    """Interrupt even a blocking readline without accepting it as a timeout."""
    message = "transport regression watchdog expired"
    raise TimeoutError(message)


def check_response(
    chunks: list[bytes],
    expected_error: str | None = None,
    *,
    early_exit: bool = False,
    chunk_delay: float = 0.02,
) -> None:
    """Exercise two sequential responses, or one visibly failing response."""
    program = (
        "import os,sys,time\n"
        "os.write(2,b'ready\\n')\n"
        "for _ in range(2):\n"
        " sys.stdin.readline()\n"
        f" for chunk in {chunks!r}:\n"
        "  os.write(1,chunk)\n"
        f"  time.sleep({chunk_delay!r})\n" + (" sys.exit(0)\n" if early_exit else "")
    )
    process = subprocess.Popen[str](
        [sys.executable, "-c", program],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    try:
        signal.setitimer(signal.ITIMER_REAL, WATCHDOG_SECONDS)
        if require_text_stream(process.stderr, "stderr").readline() != "ready\n":
            raise_test_failure("transport check child failed to start")
        for _ in range(2):
            started = time.monotonic()
            signal.setitimer(signal.ITIMER_REAL, WATCHDOG_SECONDS)
            try:
                response = send_json_request(
                    process,
                    RequestPayload(id=1, text="日本語", unit="word", language="auto"),
                    timeout_seconds=TIMEOUT_SECONDS,
                )
            except (AssertionError, json.JSONDecodeError) as error:
                if expected_error is None or expected_error not in str(error):
                    raise
                if time.monotonic() - started >= TIMEOUT_SECONDS + 0.5:
                    raise_test_failure(f"response failure exceeded deadline: {error}")
                break
            else:
                if expected_error is not None:
                    raise_test_failure(f"expected {expected_error}, got {response}")
                if response != {"id": 1, "tokens": [], "error": "日"}:
                    raise_test_failure(f"unexpected chunked response: {response}")
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        terminate_helper_process(process)
        if process.poll() is None or any(
            stream is not None and not stream.closed
            for stream in (process.stdin, process.stdout, process.stderr)
        ):
            raise_test_failure("transport check leaked a process or stream")


def run_transport_test() -> None:
    """Check deadlines, framing, decoding, id validation, and cleanup."""
    signal.signal(signal.SIGALRM, watchdog_expired)
    check_response([], "timeout")
    check_response([b'{"id":1'], "timeout")
    check_response([b'{"id":', b'1,"tokens":', b"[]}"], "timeout", chunk_delay=0.15)
    check_response([b'{"id":1,"tokens":[],"error":"\xe6', b'\x97\xa5"}', b"\n"])
    check_response([], "exited", early_exit=True)
    check_response([b'{"id":1,"tokens":[]}'], "exited", early_exit=True)
    check_response([b"{invalid}\n"], "Expecting property name")
    check_response([b'{"id":2,"tokens":[]}\n'], "id mismatch")
    check_response([b'{"id":true,"tokens":[]}\n'], "must be an integer")
    print("helper transport ok")


if __name__ == "__main__":
    run_transport_test()
