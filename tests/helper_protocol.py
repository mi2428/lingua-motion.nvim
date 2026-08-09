#!/usr/bin/env python3
"""Exercise the helper JSONL protocol across supported tokenization cases."""

from __future__ import annotations

import json
import os
import subprocess
import sys

from helper_test_support import (
    HelperProcess,
    RequestPayload,
    assert_rejected_response,
    assert_success_token_spans,
    raise_test_failure,
    send_json_request,
    terminate_helper_process,
)


def run_protocol_test() -> None:
    """Run protocol requests for each supported language and token unit."""
    helper_path = os.environ.get("LINGUA_MOTION_HELPER", ".build/lingua-motion-helper")
    process: HelperProcess = subprocess.Popen[str](
        [helper_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    try:
        request_cases: list[tuple[int, str, str]] = [
            (1, "日本語の文章。", "auto"),
            (2, "English sentence.", "en"),
            (3, "中文句子。", "zh-Hans"),
            (4, "日本語 English 中文 😀", "ja"),
            (5, "English sentence.", "en"),
            (6, "日本語の文章。", "ja"),
            (7, "中文句子。", "zh-Hans"),
            (8, "warm ASCII", "auto"),
        ]
        for request_identifier, source_text, language_code in request_cases:
            assert_success_token_spans(
                send_json_request(
                    process,
                    RequestPayload(
                        id=request_identifier,
                        text=source_text,
                        unit="word",
                        language=language_code,
                    ),
                ),
                source_text,
            )
            assert_success_token_spans(
                send_json_request(
                    process,
                    RequestPayload(
                        id=request_identifier + 100,
                        text=source_text,
                        unit="sentence",
                        language=language_code,
                    ),
                ),
                source_text,
            )
        invalid_response = send_json_request(
            process,
            RequestPayload(id=999, text="abc", unit="unknown", language="auto"),
        )
        if "error" not in invalid_response:
            raise_test_failure(
                f"invalid unit response lacked error: {invalid_response}"
            )

        malformed_response_lines = [
            '{"id":true,"tokens":[]}',
            '{"id":1,"tokens":[{"start":0}]}',
            '{"id":1,"tokens":[],"error":false}',
        ]
        for malformed_response_line in malformed_response_lines:
            assert_rejected_response(malformed_response_line)
    finally:
        terminate_helper_process(process)
    print("helper protocol ok")


if __name__ == "__main__":
    try:
        run_protocol_test()
    except (
        AssertionError,
        OSError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
    ) as test_error:
        print(f"helper protocol failed: {test_error}", file=sys.stderr)
        raise SystemExit(1) from None
