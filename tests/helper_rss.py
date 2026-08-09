#!/usr/bin/env python3
"""Measure helper RSS stability and latency over a long-lived JSONL process."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

from helper_test_support import (
    HelperProcess,
    RequestPayload,
    assert_success_token_spans,
    raise_test_failure,
    send_json_request,
    terminate_helper_process,
)

MEBIBYTE = 1024 * 1024
WARMUP_TEXT = "warm ASCII"
MINIMUM_REQUEST_COUNT = 20_000
PROCESS_FIELD_COUNT = 2
RSS_LIMIT_MEBIBYTES = 25
RSS_DELTA_LIMIT_MEBIBYTES = 2
P95_LATENCY_LIMIT_SECONDS = 0.005
P99_LATENCY_LIMIT_SECONDS = 0.016


def send_word_request(
    process: HelperProcess,
    request_identifier: int,
    source_text: str,
    language_code: str = "auto",
) -> None:
    """Send one word request and validate its response and byte spans."""
    response = send_json_request(
        process,
        RequestPayload(
            id=request_identifier,
            text=source_text,
            unit="word",
            language=language_code,
        ),
    )
    assert_success_token_spans(response, source_text)


def helper_process_ids(helper_path: str) -> list[int]:
    """Return process ids whose executable matches the helper path."""
    process_listing = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,command="], text=True
    )
    resolved_helper_path = os.path.realpath(helper_path)
    matching_process_ids: list[int] = []
    for process_line in process_listing.splitlines():
        process_fields = process_line.strip().split(None, 1)
        if len(process_fields) != PROCESS_FIELD_COUNT:
            continue
        executable = os.path.realpath(process_fields[1].split(None, 1)[0])
        if executable == resolved_helper_path:
            matching_process_ids.append(int(process_fields[0]))
    return matching_process_ids


def rss_bytes(process_id: int) -> int:
    """Read one process RSS value and convert ps kibibytes to bytes."""
    rss_output = subprocess.check_output(
        ["/bin/ps", "-o", "rss=", "-p", str(process_id)], text=True
    ).strip()
    if not rss_output:
        raise_test_failure(f"RSS unavailable for pid {process_id}")
    return int(rss_output) * 1024


def measure_request_phase(
    process: HelperProcess,
    first_request_id: int,
    request_count: int,
    *,
    use_unique_text: bool,
) -> tuple[float, float, float]:
    """Measure elapsed time and p95/p99 latency for one request phase."""
    phase_started = time.monotonic()
    request_latencies: list[float] = []
    for request_offset in range(request_count):
        request_identifier = first_request_id + request_offset
        source_text = (
            WARMUP_TEXT
            if not use_unique_text
            else f"request-{request_identifier:05d} unique"
        )
        request_started = time.perf_counter()
        send_word_request(process, request_identifier, source_text)
        request_latencies.append(time.perf_counter() - request_started)
    elapsed_seconds = time.monotonic() - phase_started
    request_latencies.sort()
    return (
        elapsed_seconds,
        request_latencies[int(len(request_latencies) * 0.95) - 1],
        request_latencies[int(len(request_latencies) * 0.99) - 1],
    )


def run_rss_test(
    helper_path: str, warmup_request_count: int, unique_request_count: int
) -> None:
    """Run process-count, memory plateau, and latency assertions."""
    process: HelperProcess = subprocess.Popen[str](
        [helper_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        bufsize=1,
    )
    try:
        for request_identifier, language_code in enumerate(
            ("en", "ja", "zh-Hans", "auto"), start=-4
        ):
            send_word_request(process, request_identifier, WARMUP_TEXT, language_code)
        expected_process_ids = [process.pid]
        if helper_process_ids(helper_path) != expected_process_ids:
            raise_test_failure(
                f"expected one helper process, got {helper_process_ids(helper_path)}"
            )
        warmup_seconds, warmup_p95, warmup_p99 = measure_request_phase(
            process, 1, warmup_request_count, use_unique_text=False
        )
        warmup_rss = rss_bytes(process.pid)
        if helper_process_ids(helper_path) != expected_process_ids:
            raise_test_failure("helper process count changed after warmup phase")

        unique_prewarm_request_count = 1_000
        unique_prewarm_seconds, prewarm_p95, prewarm_p99 = measure_request_phase(
            process,
            warmup_request_count + 1,
            unique_prewarm_request_count,
            use_unique_text=True,
        )
        unique_prewarm_rss = rss_bytes(process.pid)
        if helper_process_ids(helper_path) != expected_process_ids:
            raise_test_failure(
                "helper process count changed after unique prewarm phase"
            )

        unique_seconds, unique_p95, unique_p99 = measure_request_phase(
            process,
            warmup_request_count + unique_prewarm_request_count + 1,
            unique_request_count,
            use_unique_text=True,
        )
        unique_rss = rss_bytes(process.pid)
        if helper_process_ids(helper_path) != expected_process_ids:
            raise_test_failure("helper process count changed after unique phase")

        rss_delta = unique_rss - unique_prewarm_rss
        rss_summary = (
            f"helper RSS pid={process.pid} warm={warmup_rss / MEBIBYTE:.2f}MiB "
            f"unique-prewarm={unique_prewarm_rss / MEBIBYTE:.2f}MiB "
            f"unique-soak={unique_rss / MEBIBYTE:.2f}MiB "
            f"delta={rss_delta / MEBIBYTE:.2f}MiB"
        )
        print(rss_summary)
        warmup_latency = warmup_seconds * 1000 / warmup_request_count
        prewarm_latency = unique_prewarm_seconds * 1000 / unique_prewarm_request_count
        unique_latency = unique_seconds * 1000 / unique_request_count
        print(
            f"helper latency warm={warmup_latency:.3f}ms/request "
            f"unique-prewarm={prewarm_latency:.3f}ms/request "
            f"unique={unique_latency:.3f}ms/request"
        )
        maximum_p95 = max(warmup_p95, prewarm_p95, unique_p95) * 1000
        maximum_p99 = max(warmup_p99, prewarm_p99, unique_p99) * 1000
        print(f"helper latency p95={maximum_p95:.3f}ms p99={maximum_p99:.3f}ms")
        if any(
            rss >= RSS_LIMIT_MEBIBYTES * MEBIBYTE
            for rss in (warmup_rss, unique_prewarm_rss, unique_rss)
        ):
            raise_test_failure(
                f"RSS limit exceeded: warm={warmup_rss / MEBIBYTE:.2f}MiB "
                f"unique={unique_rss / MEBIBYTE:.2f}MiB"
            )
        if rss_delta >= RSS_DELTA_LIMIT_MEBIBYTES * MEBIBYTE:
            raise_test_failure(
                f"RSS unique plateau delta exceeded: {rss_delta / MEBIBYTE:.2f}MiB"
            )
        if (
            max(warmup_p95, prewarm_p95, unique_p95) >= P95_LATENCY_LIMIT_SECONDS
            or max(warmup_p99, prewarm_p99, unique_p99) >= P99_LATENCY_LIMIT_SECONDS
        ):
            raise_test_failure("helper latency percentile limit exceeded")
    finally:
        terminate_helper_process(process)


def parse_rss_arguments() -> tuple[str, int, int]:
    """Parse the helper path and minimum RSS soak counts."""
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument(
        "--helper",
        default=os.environ.get("LINGUA_MOTION_HELPER", ".build/lingua-motion-helper"),
    )
    argument_parser.add_argument("--warm", type=int, default=MINIMUM_REQUEST_COUNT)
    argument_parser.add_argument("--unique", type=int, default=MINIMUM_REQUEST_COUNT)
    parsed_arguments = argument_parser.parse_args()
    warmup_request_count = parsed_arguments.warm
    unique_request_count = parsed_arguments.unique
    if (
        warmup_request_count < MINIMUM_REQUEST_COUNT
        or unique_request_count < MINIMUM_REQUEST_COUNT
    ):
        raise_test_failure(
            "RSS soak requires at least 20000 warm and 20000 unique requests"
        )
    helper_path = parsed_arguments.helper
    if not isinstance(helper_path, str):
        raise_test_failure(f"helper path is not a string: {helper_path!r}")
    if not os.access(helper_path, os.X_OK):
        raise_test_failure(f"helper is not executable: {helper_path}")
    return str(Path(helper_path).resolve()), warmup_request_count, unique_request_count


if __name__ == "__main__":
    try:
        run_rss_test(*parse_rss_arguments())
        print("helper RSS test ok")
    except (
        AssertionError,
        OSError,
        subprocess.CalledProcessError,
    ) as test_error:
        print(f"helper RSS test failed: {test_error}", file=sys.stderr)
        raise SystemExit(1) from None
