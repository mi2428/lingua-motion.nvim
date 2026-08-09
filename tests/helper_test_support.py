"""Shared typed JSONL process helpers for the protocol and RSS tests."""

from __future__ import annotations

import json
import select
import subprocess
from typing import IO, NoReturn, TypedDict, cast


class TokenPayload(TypedDict):
    """Validated token fields emitted by the helper."""

    start: int
    end: int
    attributes: int
    numeric: bool
    symbolic: bool
    emoji: bool


class RequestPayload(TypedDict):
    """JSON request fields sent to the helper."""

    id: int
    text: str
    unit: str
    language: str


class SuccessResponse(TypedDict):
    """Validated successful helper response."""

    id: int
    tokens: list[TokenPayload]


class ErrorResponse(TypedDict):
    """Validated helper response containing a request error."""

    id: int
    tokens: list[TokenPayload]
    error: str


type HelperResponse = SuccessResponse | ErrorResponse
type HelperProcess = subprocess.Popen[str]


def raise_test_failure(message: str) -> NoReturn:
    """Raise a test failure with a useful protocol or process message."""
    raise AssertionError(message)


def require_text_stream(stream: IO[str] | None, stream_name: str) -> IO[str]:
    """Return a configured subprocess stream or reject an invalid test setup."""
    if stream is None:
        error_message = f"helper {stream_name} stream is unavailable"
        raise OSError(error_message)
    return stream


def require_json_object(value: object, value_name: str) -> dict[str, object]:
    """Validate a JSON object and make its string-keyed boundary explicit."""
    if not isinstance(value, dict):
        raise_test_failure(f"{value_name} is not an object: {value!r}")
    string_keyed_value: dict[str, object] = {}
    # The runtime check above makes this boundary cast safe.
    object_items = cast("dict[object, object]", value)
    for key, item in object_items.items():
        if not isinstance(key, str):
            raise_test_failure(f"{value_name} key is not a string: {key!r}")
        string_keyed_value[key] = item
    return string_keyed_value


def require_integer_field(field_value: object, field_name: str) -> int:
    """Validate one JSON integer field without accepting booleans."""
    if not isinstance(field_value, int) or isinstance(field_value, bool):
        raise_test_failure(f"{field_name} must be an integer: {field_value!r}")
    return field_value


def require_boolean_field(field_value: object, field_name: str) -> bool:
    """Validate one JSON boolean field."""
    if not isinstance(field_value, bool):
        raise_test_failure(f"{field_name} must be a boolean: {field_value!r}")
    return field_value


def decode_helper_response(response_line: str) -> HelperResponse:
    """Decode and fully validate one helper JSON response."""
    decoded_value = require_json_object(json.loads(response_line), "response")

    response_id = require_integer_field(decoded_value.get("id"), "response id")
    raw_tokens = decoded_value.get("tokens")
    if not isinstance(raw_tokens, list):
        raise_test_failure(f"response tokens must be a list: {raw_tokens!r}")

    validated_tokens: list[TokenPayload] = []
    # JSON list shape is checked above; each element is validated as an object below.
    raw_token_values = cast("list[object]", raw_tokens)
    for token_index, raw_token in enumerate(raw_token_values):
        token_object = require_json_object(raw_token, f"token {token_index}")
        start_byte = require_integer_field(token_object.get("start"), "token start")
        end_byte = require_integer_field(token_object.get("end"), "token end")
        raw_attributes = require_integer_field(
            token_object.get("attributes"), "token attributes"
        )
        if start_byte < 0 or start_byte >= end_byte or raw_attributes < 0:
            raise_test_failure(f"invalid token span or attributes: {token_object!r}")
        validated_tokens.append(
            {
                "start": start_byte,
                "end": end_byte,
                "attributes": raw_attributes,
                "numeric": require_boolean_field(
                    token_object.get("numeric"), "token numeric"
                ),
                "symbolic": require_boolean_field(
                    token_object.get("symbolic"), "token symbolic"
                ),
                "emoji": require_boolean_field(
                    token_object.get("emoji"), "token emoji"
                ),
            }
        )

    if "error" in decoded_value:
        error_message = decoded_value["error"]
        if not isinstance(error_message, str):
            raise_test_failure(f"response error must be a string: {error_message!r}")
        return {"id": response_id, "tokens": validated_tokens, "error": error_message}
    return {"id": response_id, "tokens": validated_tokens}


def send_json_request(
    process: HelperProcess,
    request: RequestPayload,
    timeout_seconds: float = 10.0,
) -> HelperResponse:
    """Send one JSONL request and read its id-matched response with a timeout."""
    input_stream = require_text_stream(process.stdin, "stdin")
    output_stream = require_text_stream(process.stdout, "stdout")
    request_line = json.dumps(request, ensure_ascii=False)
    input_stream.write(request_line + "\n")
    input_stream.flush()
    ready_streams, _, _ = select.select([output_stream], [], [], timeout_seconds)
    if not ready_streams:
        raise_test_failure(f"helper response timeout for request {request['id']}")
    response_line = output_stream.readline()
    if not response_line:
        raise_test_failure(f"helper exited before response: {process.poll()}")
    response = decode_helper_response(response_line)
    if response["id"] != request["id"]:
        raise_test_failure(
            f"response id mismatch: expected {request['id']}, got {response['id']}"
        )
    return response


def assert_success_token_spans(response: HelperResponse, source_text: str) -> None:
    """Assert a successful response covers valid ordered UTF-8 byte spans."""
    if "error" in response:
        raise_test_failure(response["error"])
    tokens = response["tokens"]
    if not tokens:
        raise_test_failure(f"missing tokens: {response}")
    source_byte_length = len(source_text.encode("utf-8"))
    previous_end_byte = 0
    for token in tokens:
        if (
            token["start"] < previous_end_byte
            or token["start"] >= token["end"]
            or token["end"] > source_byte_length
        ):
            raise_test_failure(f"invalid UTF-8 range: {token}")
        previous_end_byte = token["end"]


def assert_rejected_response(response_line: str) -> None:
    """Assert that a malformed JSON response is rejected by the schema validator."""
    try:
        decode_helper_response(response_line)
    except AssertionError:
        return
    raise_test_failure(f"malformed response was accepted: {response_line!r}")


def terminate_helper_process(process: HelperProcess) -> None:
    """Close streams, terminate hung helpers, and require a clean exit status."""
    try:
        if process.stdin is not None:
            process.stdin.close()
    except BrokenPipeError, ValueError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for output_stream in (process.stdout, process.stderr):
        if output_stream is not None:
            output_stream.close()
    if process.returncode != 0:
        raise_test_failure(f"helper exited with status {process.returncode}")
