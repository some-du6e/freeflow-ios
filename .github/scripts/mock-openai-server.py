#!/usr/bin/env python3
"""Local OpenAI-compatible mock provider for FreeFlow's iOS UI tests.

The iOS simulator shares the Mac's network stack, so the app and the keyboard
extension in a simulator reach this server at http://127.0.0.1:8765/v1. It
uses only the Python standard library and never contacts a real provider.

Endpoints (the /v1 prefix is optional):
  GET  /healthz                  200 without auth, for CI health checks.
  GET  /v1/models                200 with a model list.
  POST /v1/audio/transcriptions  Validates the multipart upload and the WAV
                                 (RIFF/WAVE PCM, 16 kHz, mono, 16-bit, sizes
                                 patched, at least 0.3 s, not silent). Returns
                                 {"text":"hello from the free flow mock",...}
                                 or HTTP 400 with the reason.
  POST /v1/chat/completions      Returns "Hello from the FreeFlow mock.".
  GET  /v1/debug/requests        Request metadata (?since=<seq> for newer).
  POST /v1/debug/reset           Clears the request log.

The provider endpoints need "Authorization: Bearer ui-test-key". A suffix on
the key selects a scenario, so UI tests can steer the mock through the
FreeFlowUITestAPIKey launch argument alone:
  ui-test-key/slow                 delays transcription and chat responses
  ui-test-key/transcription-error  transcription returns HTTP 500
  ui-test-key/empty-transcript     transcription returns empty text
  ui-test-key/chat-error           chat completions return HTTP 500

The request log holds metadata only: sizes, formats, levels, counts, the
User-Agent and model names. It never holds audio, prompt or transcript text,
or the Authorization header, because CI logs and artifacts in this
repository are public.

--latency adds a fixed delay to every transcription and chat response, like a
real provider's, so UI tests can observe the keyboard's processing state.

Usage:
  mock-openai-server.py [--host 127.0.0.1] [--port 8765] [--log FILE] [--latency SECONDS]
  mock-openai-server.py --self-test
"""

from __future__ import annotations

import argparse
import array
import http.client
import json
import math
import signal
import struct
import sys
import threading
import time
import traceback
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

API_KEY = "ui-test-key"
SCENARIOS = ("slow", "transcription-error", "empty-transcript", "chat-error")
TRANSCRIPT_TEXT = "hello from the free flow mock"
CLEANUP_TEXT = "Hello from the FreeFlow mock."
MODELS = (
    "whisper-large-v3",
    "whisper-large-v3-turbo",
    "openai/gpt-oss-20b",
    "openai/gpt-oss-120b",
)

MAX_BODY_BYTES = 25 * 1024 * 1024
EXPECTED_SAMPLE_RATE = 16000
MIN_DURATION_SECONDS = 0.3
# A peak below about -50 dBFS counts as silence.
SILENCE_PEAK = 100
WAV_CONTENT_TYPES = ("audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave")
DEBUG_PATHS = ("/debug/requests", "/debug/reset")


class RequestError(Exception):
    """An error the mock reports to the client as an OpenAI-style error."""

    def __init__(self, status: int, reason: str, error_type: str = "invalid_request_error"):
        super().__init__(reason)
        self.status = status
        self.reason = reason
        self.error_type = error_type


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def parse_header_params(value: str) -> tuple[str, dict[str, str]]:
    """Split 'type/subtype; a=b; c="d"' into ('type/subtype', {'a': 'b', 'c': 'd'})."""
    pieces = value.split(";")
    main = pieces[0].strip().lower()
    params: dict[str, str] = {}
    for piece in pieces[1:]:
        if "=" not in piece:
            continue
        key, raw = piece.split("=", 1)
        raw = raw.strip()
        if len(raw) >= 2 and raw[0] == raw[-1] == '"':
            raw = raw[1:-1]
        params[key.strip().lower()] = raw
    return main, params


def parse_multipart(body: bytes, boundary: str) -> list[tuple[dict[str, str], bytes]]:
    """Parse a multipart/form-data body into (headers, content) pairs."""
    delimiter = b"--" + boundary.encode("latin-1")
    position = body.find(delimiter)
    if position < 0:
        raise RequestError(400, "multipart body does not contain its boundary")
    parts = []
    while True:
        position += len(delimiter)
        if body[position:position + 2] == b"--":
            return parts
        if body[position:position + 2] != b"\r\n":
            raise RequestError(400, "multipart boundary line is malformed")
        position += 2
        next_delimiter = body.find(b"\r\n" + delimiter, position)
        if next_delimiter < 0:
            raise RequestError(400, "multipart body is missing its closing boundary")
        part = body[position:next_delimiter]
        if part.startswith(b"\r\n"):
            raw_headers, content = b"", part[2:]
        else:
            header_end = part.find(b"\r\n\r\n")
            if header_end < 0:
                raise RequestError(400, "multipart part has no blank line after its headers")
            raw_headers, content = part[:header_end], part[header_end + 4:]
        headers = {}
        for line in raw_headers.split(b"\r\n"):
            if b":" in line:
                name, value = line.split(b":", 1)
                headers[name.strip().lower().decode("latin-1")] = value.strip().decode("utf-8", "replace")
        parts.append((headers, content))
        position = next_delimiter + 2


def inspect_wav(data: bytes) -> dict:
    """Describe a WAV file. "problem" names the first reason it is rejected, or is None."""
    info: dict = {"bytes": len(data), "problem": None}

    def reject(reason: str) -> dict:
        info["problem"] = reason
        return info

    if len(data) < 12 or data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        return reject("the file is not a RIFF/WAVE file")
    riff_size = struct.unpack_from("<I", data, 4)[0]
    info["riff_size"] = riff_size
    if riff_size != len(data) - 8:
        return reject(
            f"the RIFF size is {riff_size} but the file holds {len(data) - 8} bytes after it; "
            "the header was not patched after writing"
        )

    fmt = None
    data_range = None
    offset = 12
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        start = offset + 8
        end = start + chunk_size
        if end > len(data):
            return reject(f"the {chunk_id.decode('latin-1')!r} chunk runs past the end of the file")
        if chunk_id == b"fmt ":
            if chunk_size < 16:
                return reject("the fmt chunk is shorter than 16 bytes")
            fmt = struct.unpack_from("<HHIIHH", data, start)
            audio_format = fmt[0]
            if audio_format == 0xFFFE and chunk_size >= 26:
                # WAVE_FORMAT_EXTENSIBLE: the sub-format GUID starts with the format code.
                audio_format = struct.unpack_from("<H", data, start + 24)[0]
            fmt = (audio_format,) + fmt[1:]
        elif chunk_id == b"data" and data_range is None:
            data_range = (start, end)
        offset = end + (chunk_size & 1)

    if fmt is None:
        return reject("the file has no fmt chunk")
    audio_format, channels, sample_rate, byte_rate, block_align, bits = fmt
    info.update(
        audio_format=audio_format,
        channels=channels,
        sample_rate=sample_rate,
        bits=bits,
        block_align=block_align,
        byte_rate=byte_rate,
    )
    if data_range is None:
        return reject("the file has no data chunk")
    data_size = data_range[1] - data_range[0]
    info["data_bytes"] = data_size

    if audio_format != 1:
        return reject(f"the audio format is {audio_format}, not 1 (integer PCM)")
    if channels != 1:
        return reject(f"the file has {channels} channels; expected mono")
    if sample_rate != EXPECTED_SAMPLE_RATE:
        return reject(f"the sample rate is {sample_rate} Hz; expected {EXPECTED_SAMPLE_RATE} Hz")
    if bits != 16:
        return reject(f"the samples are {bits}-bit; expected 16-bit")
    if block_align != 2 or byte_rate != EXPECTED_SAMPLE_RATE * 2:
        return reject(f"block align {block_align} and byte rate {byte_rate} don't match 16 kHz mono 16-bit")
    if data_size % 2:
        return reject(f"the data chunk has an odd size ({data_size} bytes)")

    frames = data_size // 2
    duration = frames / EXPECTED_SAMPLE_RATE
    info["frames"] = frames
    info["duration_s"] = round(duration, 3)
    if duration < MIN_DURATION_SECONDS:
        return reject(f"the audio lasts {duration:.3f} s; expected at least {MIN_DURATION_SECONDS} s")

    samples = array.array("h")
    samples.frombytes(data[data_range[0]:data_range[1]])
    if sys.byteorder == "big":
        samples.byteswap()
    peak = max(abs(min(samples)), abs(max(samples)))
    rms = math.sqrt(sum(sample * sample for sample in samples) / frames)
    info["peak"] = peak
    info["peak_dbfs"] = round(20 * math.log10(peak / 32768), 1) if peak else None
    info["rms_dbfs"] = round(20 * math.log10(rms / 32768), 1) if rms else None
    if peak < SILENCE_PEAK:
        return reject(f"the audio is silent (peak sample {peak}, below {SILENCE_PEAK})")
    return info


def classify_chat(messages: list) -> str:
    """Name the FreeFlow prompt a chat request came from, without logging the prompt."""
    text = " ".join(str(message.get("content", "")) for message in messages if isinstance(message, dict))
    if "RAW_TRANSCRIPTION" in text:
        return "cleanup"
    if "<<<TRANSCRIPT" in text or "literal translator" in text:
        return "verbatim-translation"
    return "other"


def summarize(meta: dict) -> str:
    pieces = [meta.get("method", "?"), meta.get("path", "?"), "->", str(meta.get("status", "?"))]
    wav = meta.get("wav") or {}
    if "sample_rate" in wav:
        described = f"wav={wav['sample_rate']}Hz/ch{wav.get('channels')}/{wav.get('bits')}bit"
        if "duration_s" in wav:
            described += f"/{wav['duration_s']}s"
        if wav.get("peak_dbfs") is not None:
            described += f"/peak {wav['peak_dbfs']} dBFS"
        pieces.append(described)
    chat = meta.get("chat")
    if chat:
        pieces.append(f"chat={chat.get('kind')}/{chat.get('model')}/{chat.get('messages')} messages")
    if meta.get("scenario") not in (None, "default"):
        pieces.append(f"scenario={meta['scenario']}")
    if meta.get("error"):
        pieces.append(f"error={meta['error']}")
    if meta.get("user_agent"):
        pieces.append(f"ua={meta['user_agent']}")
    return " ".join(pieces)


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FreeFlowMock/1"
    sys_version = ""
    timeout = 60

    def do_GET(self) -> None:
        self.dispatch()

    def do_POST(self) -> None:
        self.dispatch()

    def do_PUT(self) -> None:
        self.dispatch()

    def do_DELETE(self) -> None:
        self.dispatch()

    def do_PATCH(self) -> None:
        self.dispatch()

    def log_message(self, format: str, *args) -> None:
        # Requests are summarized by MockServer.record instead.
        pass

    def dispatch(self) -> None:
        started = time.monotonic()
        url = urlsplit(self.path)
        path = url.path.rstrip("/") or "/"
        route = path[3:] if path.startswith("/v1/") else path
        meta: dict = {"time": utc_timestamp(), "method": self.command, "path": path}
        user_agent = self.headers.get("User-Agent")
        if user_agent:
            meta["user_agent"] = user_agent[:200]
        record = route not in DEBUG_PATHS and route != "/healthz"
        try:
            body = self.read_body(meta)
            if route == "/healthz":
                self.require_method("GET")
                self.send_json(200, {"ok": True}, meta)
            elif route == "/debug/requests":
                self.require_method("GET")
                since = parse_qs(url.query).get("since", ["0"])[0]
                self.send_json(200, self.server.snapshot(int(since) if since.isdigit() else 0), meta)
            elif route == "/debug/reset":
                self.require_method("POST")
                self.send_json(200, {"cleared": self.server.reset()}, meta)
            elif route == "/models":
                self.require_method("GET")
                self.authenticate(meta)
                self.send_json(200, {
                    "object": "list",
                    "data": [{"id": model, "object": "model", "owned_by": "freeflow-mock"} for model in MODELS],
                }, meta)
            elif route == "/audio/transcriptions":
                self.require_method("POST")
                scenario = self.authenticate(meta)
                self.transcribe(body, scenario, meta)
            elif route == "/chat/completions":
                self.require_method("POST")
                scenario = self.authenticate(meta)
                self.complete_chat(body, scenario, meta)
            else:
                raise RequestError(404, f"unknown endpoint {path}", "not_found_error")
        except RequestError as error:
            meta["error"] = error.reason
            self.send_json(error.status, {"error": {"message": error.reason, "type": error.error_type}}, meta)
        except Exception as error:  # noqa: BLE001 - report every failure to the client
            meta["error"] = f"mock server error: {type(error).__name__}"
            traceback.print_exc()
            self.close_connection = True
            self.send_json(500, {"error": {"message": meta["error"], "type": "server_error"}}, meta)
        finally:
            meta["duration_ms"] = round((time.monotonic() - started) * 1000, 1)
            if record:
                self.server.record(meta)

    def require_method(self, method: str) -> None:
        if self.command != method:
            raise RequestError(405, f"{self.command} is not allowed here; use {method}")

    def read_body(self, meta: dict) -> bytes:
        """Read the whole request body first, so an early error never leaves
        unread bytes on a kept-alive connection."""
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            meta["transfer_encoding"] = "chunked"
            chunks = []
            total = 0
            while True:
                size_line = self.rfile.readline(65537)
                try:
                    size = int(size_line.split(b";")[0].strip(), 16)
                except ValueError:
                    self.close_connection = True
                    raise RequestError(400, "malformed chunked request body") from None
                if size == 0:
                    while self.rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                        pass
                    break
                total += size
                if total > MAX_BODY_BYTES:
                    self.close_connection = True
                    raise RequestError(413, f"request body exceeds {MAX_BODY_BYTES} bytes")
                chunks.append(self.rfile.read(size))
                self.rfile.readline(65537)
            body = b"".join(chunks)
        else:
            length_header = self.headers.get("Content-Length")
            if length_header is None:
                body = b""
            else:
                try:
                    length = int(length_header)
                except ValueError:
                    self.close_connection = True
                    raise RequestError(400, "Content-Length is not a number") from None
                if length > MAX_BODY_BYTES:
                    self.close_connection = True
                    raise RequestError(413, f"request body exceeds {MAX_BODY_BYTES} bytes")
                body = self.rfile.read(length)
        meta["content_type"] = parse_header_params(self.headers.get("Content-Type", ""))[0] or None
        meta["body_bytes"] = len(body)
        return body

    def authenticate(self, meta: dict) -> str:
        """Check the bearer token and return the scenario it selects. Only the
        outcome and the token length are logged, never the token."""
        header = self.headers.get("Authorization")
        if header is None:
            meta["auth"] = "missing"
            raise RequestError(401, "missing Authorization header", "invalid_api_key")
        if not header.startswith("Bearer "):
            meta["auth"] = "malformed"
            raise RequestError(401, "Authorization is not a Bearer token", "invalid_api_key")
        token = header[len("Bearer "):].strip()
        meta["auth_token_length"] = len(token)
        scenario = None
        if token == API_KEY:
            scenario = "default"
        elif token.startswith(API_KEY + "/") and token[len(API_KEY) + 1:] in SCENARIOS:
            scenario = token[len(API_KEY) + 1:]
        if scenario is None:
            meta["auth"] = "wrong"
            raise RequestError(401, "Invalid API Key", "invalid_api_key")
        meta["auth"] = "ok"
        meta["scenario"] = scenario
        return scenario

    def transcribe(self, body: bytes, scenario: str, meta: dict) -> None:
        mime, params = parse_header_params(self.headers.get("Content-Type", ""))
        if mime != "multipart/form-data":
            raise RequestError(400, f"Content-Type is {mime or 'missing'}; expected multipart/form-data")
        boundary = params.get("boundary")
        if not boundary:
            raise RequestError(400, "the multipart Content-Type has no boundary")
        fields: dict[str, str] = {}
        names = []
        upload = None
        for headers, content in parse_multipart(body, boundary):
            disposition, disposition_params = parse_header_params(headers.get("content-disposition", ""))
            name = disposition_params.get("name")
            if disposition != "form-data" or not name:
                raise RequestError(400, "a multipart part has no form-data name")
            names.append(name)
            if name == "file":
                upload = (disposition_params.get("filename") or "", headers.get("content-type", ""), content)
            else:
                fields[name] = content.decode("utf-8", "replace").strip()
        multipart = {
            "parts": names,
            "model": fields.get("model"),
            "response_format": fields.get("response_format"),
            "language": fields.get("language"),
        }
        meta["multipart"] = multipart
        if not fields.get("model"):
            raise RequestError(400, "the 'model' field is missing")
        response_format = fields.get("response_format") or "json"
        if response_format not in ("json", "verbose_json", "text"):
            raise RequestError(400, f"response_format {response_format!r} is not supported")
        if upload is None:
            raise RequestError(400, "the 'file' part is missing")
        filename, file_type, audio = upload
        extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
        multipart["file"] = {"extension": extension, "content_type": file_type, "bytes": len(audio)}
        if extension != "wav":
            raise RequestError(400, f"the file name has extension {extension!r}; expected .wav")
        if file_type.split(";")[0].strip().lower() not in WAV_CONTENT_TYPES:
            raise RequestError(400, f"the file part's Content-Type is {file_type!r}; expected audio/wav")
        wav = inspect_wav(audio)
        meta["wav"] = wav
        if wav["problem"]:
            raise RequestError(400, f"invalid WAV: {wav['problem']}")

        self.server.simulate_latency()
        if scenario == "slow":
            time.sleep(self.server.slow_seconds)
        if scenario == "transcription-error":
            raise RequestError(500, "mock transcription failure (scenario transcription-error)", "server_error")
        text = "" if scenario == "empty-transcript" else TRANSCRIPT_TEXT
        if response_format == "text":
            self.send_bytes(200, text.encode("utf-8"), "text/plain; charset=utf-8", meta)
        elif response_format == "verbose_json":
            segments = [{"no_speech_prob": 0.01}] if text else []
            self.send_json(200, {"text": text, "segments": segments}, meta)
        else:
            self.send_json(200, {"text": text}, meta)

    def complete_chat(self, body: bytes, scenario: str, meta: dict) -> None:
        mime, _ = parse_header_params(self.headers.get("Content-Type", ""))
        if mime != "application/json":
            raise RequestError(400, f"Content-Type is {mime or 'missing'}; expected application/json")
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise RequestError(400, "the body is not valid JSON") from None
        if not isinstance(payload, dict):
            raise RequestError(400, "the body is not a JSON object")
        model = payload.get("model")
        messages = payload.get("messages")
        if not isinstance(model, str) or not model.strip():
            raise RequestError(400, "the 'model' field is missing")
        if not isinstance(messages, list) or not messages:
            raise RequestError(400, "the 'messages' field must be a non-empty list")
        if not all(isinstance(m, dict) and isinstance(m.get("role"), str) and isinstance(m.get("content"), str)
                   for m in messages):
            raise RequestError(400, "every message needs a string 'role' and 'content'")
        meta["chat"] = {
            "model": model,
            "messages": len(messages),
            "roles": [message["role"] for message in messages],
            "characters": sum(len(message["content"]) for message in messages),
            "kind": classify_chat(messages),
            "temperature": payload.get("temperature"),
            "options": sorted(key for key in payload if key not in ("model", "messages")),
        }
        if payload.get("stream"):
            raise RequestError(400, "streaming responses are not supported by the mock")
        self.server.simulate_latency()
        if scenario == "slow":
            time.sleep(self.server.slow_seconds)
        if scenario == "chat-error":
            raise RequestError(500, "mock chat failure (scenario chat-error)", "server_error")
        self.send_json(200, {
            "id": f"chatcmpl-mock-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": CLEANUP_TEXT},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }, meta)

    def send_json(self, status: int, payload: object, meta: dict) -> None:
        self.send_bytes(status, json.dumps(payload).encode("utf-8"), "application/json", meta)

    def send_bytes(self, status: int, data: bytes, content_type: str, meta: dict) -> None:
        meta["status"] = status
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()


class MockServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, log_path: str | None = None, slow_seconds: float = 3.0, quiet: bool = False,
                 latency: float = 0.0):
        super().__init__(address, MockHandler)
        self.lock = threading.Lock()
        self.requests: list[dict] = []
        self.sequence = 0
        self.log_path = log_path
        self.slow_seconds = slow_seconds
        self.quiet = quiet
        self.latency = latency

    def simulate_latency(self) -> None:
        if self.latency > 0:
            time.sleep(self.latency)

    def record(self, meta: dict) -> None:
        with self.lock:
            self.sequence += 1
            meta["seq"] = self.sequence
            self.requests.append(meta)
            if self.log_path:
                with open(self.log_path, "a", encoding="utf-8") as log:
                    log.write(json.dumps(meta, sort_keys=True) + "\n")
        if not self.quiet:
            print(f"[mock] {summarize(meta)}", flush=True)

    def snapshot(self, since: int = 0) -> dict:
        with self.lock:
            requests = [dict(meta) for meta in self.requests if meta["seq"] > since]
            return {"count": len(requests), "last_seq": self.sequence, "requests": requests}

    def reset(self) -> int:
        with self.lock:
            cleared = len(self.requests)
            self.requests.clear()
            return cleared


# Self-test ---------------------------------------------------------------


def synthetic_wav(seconds=1.0, rate=16000, channels=1, bits=16, amplitude=0.25,
                  frequency=440.0, patch_sizes=True) -> bytes:
    """A synthetic sine tone, laid out like FreeFlow's StreamingWAVWriter output."""
    frames = int(seconds * rate)
    tone = [amplitude * math.sin(2 * math.pi * frequency * i / rate) for i in range(frames)]
    if bits == 16:
        samples = array.array("h", (int(value * 32767) for value in tone for _ in range(channels)))
        if sys.byteorder == "big":
            samples.byteswap()
        pcm = samples.tobytes()
    else:
        pcm = bytes(int(128 + value * 127) for value in tone for _ in range(channels))
    block_align = channels * bits // 8
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * block_align, block_align, bits)
    riff_size = 4 + 8 + len(fmt) + 8 + len(pcm)
    data_size = len(pcm)
    if not patch_sizes:
        riff_size = data_size = 0
    return (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", data_size) + pcm)


def synthetic_multipart(audio: bytes | None, model="whisper-large-v3", response_format="verbose_json",
                        filename="0A1B2C3D-0000-4000-8000-000000000000.wav", file_type="audio/wav",
                        language: str | None = None) -> tuple[bytes, str]:
    """Builds the body the way TranscriptionService.makeMultipartBody does."""
    boundary = str(uuid.uuid4()).upper()
    body = bytearray()

    def field(name: str, value: str) -> None:
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())

    if model is not None:
        field("model", model)
    if response_format is not None:
        field("response_format", response_format)
    if language:
        field("language", language)
    if audio is not None:
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
                    f'Content-Type: {file_type}\r\n\r\n'.encode())
        body.extend(audio)
        body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode())
    return bytes(body), f"multipart/form-data; boundary={boundary}"


def run_self_test() -> int:
    server = MockServer(("127.0.0.1", 0), quiet=True, slow_seconds=0.2)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    thread.start()
    port = server.server_address[1]
    failures = []
    auth = {"Authorization": f"Bearer {API_KEY}"}
    prompt_marker = "SYNTHETIC-PROMPT-MARKER-7f3a"

    def check(name: str, condition: bool, detail: object = "") -> None:
        print(f"{'ok  ' if condition else 'FAIL'} {name}" + (f" ({detail})" if detail and not condition else ""))
        if not condition:
            failures.append(name)

    def call(method, path, body=None, headers=None, connection=None, chunked=False):
        own = connection is None
        conn = connection or http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        if chunked:
            pieces = [body[i:i + 4096] for i in range(0, len(body), 4096)]
            conn.request(method, path, body=iter(pieces), headers=headers or {}, encode_chunked=True)
        else:
            conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        data = response.read()
        if own:
            conn.close()
        try:
            parsed = json.loads(data.decode("utf-8")) if data else None
        except ValueError:
            parsed = None
        return response.status, parsed, data

    def upload(audio, key=API_KEY, **kwargs):
        body, content_type = synthetic_multipart(audio, **kwargs)
        return call("POST", "/v1/audio/transcriptions", body,
                    {"Authorization": f"Bearer {key}", "Content-Type": content_type})

    def chat(payload, key=API_KEY, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return call("POST", "/v1/chat/completions", body,
                    {"Authorization": f"Bearer {key}", "Content-Type": content_type})

    def error_message(parsed) -> str:
        return ((parsed or {}).get("error") or {}).get("message", "")

    try:
        status, parsed, _ = call("GET", "/healthz")
        check("health check answers without auth", status == 200 and parsed == {"ok": True}, status)

        status, parsed, _ = call("GET", "/v1/models")
        check("models without a key is 401", status == 401, status)
        status, parsed, _ = call("GET", "/v1/models", headers={"Authorization": "Bearer not-the-key"})
        check("models with a wrong key is 401", status == 401, status)
        status, parsed, _ = call("GET", "/v1/models", headers=auth)
        check("models with the key is 200", status == 200 and parsed["data"][0]["id"] == MODELS[0], status)
        status, parsed, _ = call("GET", "/models", headers=auth)
        check("the /v1 prefix is optional", status == 200, status)

        status, parsed, _ = upload(synthetic_wav(seconds=1.0))
        check("a valid WAV is transcribed as verbose_json",
              status == 200 and parsed == {"text": TRANSCRIPT_TEXT, "segments": [{"no_speech_prob": 0.01}]},
              (status, parsed))
        status, parsed, _ = upload(synthetic_wav(seconds=0.5), response_format="json", language="en")
        check("response_format json returns only text", status == 200 and parsed == {"text": TRANSCRIPT_TEXT},
              (status, parsed))
        status, _, raw = upload(synthetic_wav(seconds=0.5), response_format="text")
        check("response_format text returns plain text", status == 200 and raw == TRANSCRIPT_TEXT.encode(), status)

        rejections = [
            ("silent audio", synthetic_wav(amplitude=0.0), {}, "silent"),
            ("audio shorter than 0.3 s", synthetic_wav(seconds=0.2), {}, "at least 0.3 s"),
            ("a 44.1 kHz file", synthetic_wav(rate=44100), {}, "16000 Hz"),
            ("a stereo file", synthetic_wav(channels=2), {}, "mono"),
            ("an 8-bit file", synthetic_wav(bits=8), {}, "16-bit"),
            ("an unpatched streaming header", synthetic_wav(patch_sizes=False), {}, "not patched"),
            ("a file that is not WAV", b"ID3" + bytes(4000), {}, "RIFF/WAVE"),
            ("a missing model field", synthetic_wav(), {"model": None}, "'model'"),
            ("a non-.wav file name", synthetic_wav(), {"filename": "clip.m4a"}, "extension"),
            ("a non-audio part type", synthetic_wav(), {"file_type": "application/octet-stream"}, "audio/wav"),
            ("an unsupported response_format", synthetic_wav(), {"response_format": "srt"}, "not supported"),
        ]
        for name, audio, extra, expected in rejections:
            status, parsed, _ = upload(audio, **extra)
            check(f"rejects {name}", status == 400 and expected in error_message(parsed),
                  (status, error_message(parsed)))
        status, parsed, _ = upload(None)
        check("rejects a missing file part", status == 400 and "'file'" in error_message(parsed), status)
        status, parsed, _ = call("POST", "/v1/audio/transcriptions", b"{}",
                                 {"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"})
        check("rejects a non-multipart upload", status == 400, status)

        body, content_type = synthetic_multipart(synthetic_wav(seconds=1.0))
        status, parsed, _ = call("POST", "/v1/audio/transcriptions", body,
                                 {**auth, "Content-Type": content_type}, chunked=True)
        check("accepts a chunked upload", status == 200 and parsed["text"] == TRANSCRIPT_TEXT, status)
        status, parsed, _ = call("POST", "/v1/audio/transcriptions", body,
                                 {**auth, "Content-Type": content_type, "Expect": "100-continue"})
        check("accepts Expect: 100-continue", status == 200, status)

        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        statuses = [call("GET", "/v1/models", headers=auth, connection=connection)[0] for _ in range(3)]
        status, _, _ = call("POST", "/v1/audio/transcriptions", body, {**auth, "Content-Type": content_type},
                            connection=connection)
        statuses.append(status)
        status, _, _ = call("GET", "/v1/models", headers=auth, connection=connection)
        statuses.append(status)
        connection.close()
        check("serves several requests on one kept-alive connection", statuses == [200] * 5, statuses)

        messages = [
            {"role": "system", "content": f"You clean up dictation. {prompt_marker}"},
            {"role": "user", "content": f"RAW_TRANSCRIPTION:\n<<<RAW_TRANSCRIPTION\n{prompt_marker}\nRAW_TRANSCRIPTION"},
        ]
        status, parsed, _ = chat({"model": "openai/gpt-oss-20b", "temperature": 0.0, "messages": messages})
        check("chat completions return the cleanup text",
              status == 200 and parsed["choices"][0]["message"]["content"] == CLEANUP_TEXT, (status, parsed))
        status, parsed, _ = chat(b"{not json")
        check("chat rejects invalid JSON", status == 400, status)
        status, parsed, _ = chat({"model": "m", "messages": []})
        check("chat rejects empty messages", status == 400, status)
        status, parsed, _ = chat({"model": "m", "messages": messages, "stream": True})
        check("chat rejects streaming", status == 400, status)
        status, parsed, _ = chat({"model": "m", "messages": messages}, key="nope")
        check("chat rejects a wrong key", status == 401, status)

        status, parsed, _ = upload(synthetic_wav(), key=f"{API_KEY}/transcription-error")
        check("scenario transcription-error returns 500", status == 500, status)
        status, parsed, _ = upload(synthetic_wav(), key=f"{API_KEY}/empty-transcript")
        check("scenario empty-transcript returns empty text",
              status == 200 and parsed == {"text": "", "segments": []}, (status, parsed))
        status, parsed, _ = chat({"model": "m", "messages": messages}, key=f"{API_KEY}/chat-error")
        check("scenario chat-error returns 500", status == 500, status)
        started = time.monotonic()
        status, parsed, _ = chat({"model": "m", "messages": messages}, key=f"{API_KEY}/slow")
        check("scenario slow delays the response", status == 200 and time.monotonic() - started >= 0.2, status)
        status, parsed, _ = upload(synthetic_wav(), key=f"{API_KEY}/unknown-scenario")
        check("an unknown scenario is a wrong key", status == 401, status)

        status, parsed, _ = call("GET", "/v1/nope", headers=auth)
        check("unknown endpoints are 404", status == 404, status)
        status, parsed, _ = call("GET", "/v1/chat/completions", headers=auth)
        check("wrong methods are 405", status == 405, status)

        status, parsed, raw = call("GET", "/v1/debug/requests")
        requests = (parsed or {}).get("requests", [])
        check("the debug log records provider requests", status == 200 and len(requests) > 20, len(requests))
        good = [r for r in requests if r.get("path") == "/v1/audio/transcriptions" and r.get("status") == 200]
        check("the log describes accepted WAVs",
              bool(good) and good[0]["wav"]["sample_rate"] == 16000 and good[0]["wav"]["duration_s"] == 1.0
              and good[0]["multipart"]["model"] == "whisper-large-v3", good[:1])
        rejected = [r for r in requests if r.get("status") == 400 and "silent" in r.get("error", "")]
        check("the log keeps the rejection reason", bool(rejected), len(rejected))
        chats = [r for r in requests if r.get("chat", {}).get("kind") == "cleanup"]
        check("the log classifies cleanup requests", bool(chats), len(chats))
        text = raw.decode("utf-8")
        check("the log never contains the API key", API_KEY not in text)
        check("the log never contains prompt text", prompt_marker not in text and "clean up dictation" not in text)
        check("the log never contains transcript text", TRANSCRIPT_TEXT not in text and CLEANUP_TEXT not in text)
        last = parsed["last_seq"]
        call("GET", "/v1/models", headers=auth)
        status, parsed, _ = call("GET", f"/v1/debug/requests?since={last}")
        check("?since returns only newer requests", status == 200 and parsed["count"] == 1, parsed and parsed["count"])
        server.latency = 0.3
        started = time.monotonic()
        status, parsed, _ = chat({"model": "m", "messages": messages})
        check("--latency delays provider responses", status == 200 and time.monotonic() - started >= 0.3, status)
        started = time.monotonic()
        status, parsed, _ = call("GET", "/healthz")
        check("--latency leaves the health check alone", status == 200 and time.monotonic() - started < 0.3, status)
        server.latency = 0.0
        status, parsed, _ = call("POST", "/v1/debug/reset")
        check("reset clears the log", status == 200 and parsed["cleared"] > 20, parsed)
        status, parsed, _ = call("GET", "/v1/debug/requests")
        check("the log is empty after a reset", status == 200 and parsed["count"] == 0, parsed)
    except Exception:  # noqa: BLE001 - any crash fails the self-test
        traceback.print_exc()
        failures.append("unexpected exception")
    finally:
        server.shutdown()
        server.server_close()

    if failures:
        print(f"Mock provider self-test FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("Mock provider self-test passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--log", help="append one JSON line of request metadata per request to this file")
    parser.add_argument("--slow-seconds", type=float, default=3.0,
                        help="delay for the ui-test-key/slow scenario (default 3)")
    parser.add_argument("--latency", type=float, default=0.0,
                        help="delay added to every transcription and chat response (default 0)")
    parser.add_argument("--self-test", action="store_true", help="exercise every endpoint on a free port and exit")
    args = parser.parse_args(argv)
    if args.self_test:
        return run_self_test()

    server = MockServer((args.host, args.port), log_path=args.log, slow_seconds=args.slow_seconds,
                        latency=args.latency)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    host, port = server.server_address[:2]
    print(f"FreeFlow mock provider listening on http://{host}:{port}/v1", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
