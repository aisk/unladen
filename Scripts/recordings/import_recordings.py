#!/usr/bin/env python3
"""Imports recorded vendor traffic into Unladen's replay fixtures.

Reads the cases listed in `manifest.json` (next to this script) from three
reference checkouts, treated as read-only data (nothing in them is
executed):

- pydantic-ai: VCR cassettes of real API traffic (MIT)
- vercel-ai:   per-provider `__fixtures__` captured from real APIs (Apache-2.0)
- magpie:      gateway test data: real client requests and upstream streams (MIT)

and writes one directory per case under
`Tests/UnladenReplayTests/Recordings/<vendor>/<case>/`:

- `case.json`     provenance (repo, path, commit), vendor, protocol, model,
                  status, kept response headers, and `facts`: what the
                  recorded response says (text, reasoning, tool calls, finish
                  reason, usage, error), extracted here independently of
                  Unladen's codecs so the Swift tests can compare against it;
- `request.json`  the request body as recorded (when the source has one);
- `response.json` / `response.sse` the response body as recorded.

Bodies are copied verbatim except for scrubbing: anything that looks like a
credential is replaced, request headers are never copied, and only an
allowlist of response headers is kept. The output is deterministic: the
same checkouts give the same bytes.

Usage (from the package root):

    python3 -I Scripts/recordings/import_recordings.py [--repos DIR] [--only PREFIX] [--check]

`--repos` is the directory holding the three checkouts (default: the
package's parent directory); `--check` exits non-zero if any written file
would change (CI-style drift check) without writing anything.
"""

import argparse
import json
import os
import re
import subprocess
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(PACKAGE, "Tests", "UnladenReplayTests", "Recordings")

REPOS = {
    # key: (checkout directory name, upstream, licence)
    "pydantic-ai": ("pydantic-ai", "github.com/pydantic/pydantic-ai", "MIT"),
    "vercel-ai": ("ai", "github.com/vercel/ai", "Apache-2.0"),
    "magpie": ("magpie", "github.com/yetone/magpie", "MIT"),
    "unladen": ("unladen", "this package", "-"),
}

KEPT_RESPONSE_HEADERS = {"content-type", "retry-after", "request-id", "x-request-id", "x-should-retry"}

# --- Scrubbing ---------------------------------------------------------------

SECRET_PATTERNS = [
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}"), "sk-ant-REDACTED"),
    (re.compile(r"sk-(?:proj-|or-v1-)?[A-Za-z0-9_\-]{20,}"), "sk-REDACTED"),
    (re.compile(r"AIza[0-9A-Za-z_\-]{30,}"), "AIza-REDACTED"),
    (re.compile(r"gsk_[A-Za-z0-9]{20,}"), "gsk_REDACTED"),
    (re.compile(r"xai-[A-Za-z0-9]{30,}"), "xai-REDACTED"),
    (re.compile(r"(?:ghp|gho|ghu|ghs)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"), "gh-REDACTED"),
    (re.compile(r"Bearer [A-Za-z0-9._\-]{16,}"), "Bearer REDACTED"),
    (re.compile(r"\borg-[A-Za-z0-9]{16,}"), "org-REDACTED"),
    (re.compile(r"\buser_[A-Za-z0-9]{20,}"), "user_REDACTED"),
    (re.compile(r'("(?:api[_-]?key|authorization|x-api-key|x-goog-api-key|cookie|set-cookie|access_token|refresh_token)"\s*:\s*")[^"]*(")', re.I),
     r"\1REDACTED\2"),
]

UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")


def scrub(text):
    count = 0
    for pattern, replacement in SECRET_PATTERNS:
        text, n = pattern.subn(replacement, text)
        count += n
    return text, count


def scrub_client_ids(text):
    """Replaces UUIDs (session, device, installation ids) with fixed ones,
    in order of first appearance. Only for client request samples."""
    mapping = {}

    def replace(match):
        value = match.group(0)
        if value not in mapping:
            mapping[value] = "00000000-0000-4000-8000-%012d" % (len(mapping) + 1)
        return mapping[value]

    return UUID.sub(replace, text)


# --- Reading sources -----------------------------------------------------------


class Loader(yaml.CSafeLoader):
    """YAML without implicit timestamps: dates stay the strings they were."""


Loader.yaml_implicit_resolvers = {
    key: [(tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:timestamp"]
    for key, resolvers in yaml.CSafeLoader.yaml_implicit_resolvers.items()
}

_cassettes = {}


def cassette(path):
    if path not in _cassettes:
        with open(path, encoding="utf-8") as handle:
            _cassettes[path] = yaml.load(handle, Loader=Loader)
    return _cassettes[path]


def body_of(message):
    """(text, parsed JSON or None) of a cassette request/response body."""
    body = message.get("body")
    if isinstance(body, dict) and "type" in body:  # pydantic-ai's own format
        if body["type"] == "json":
            return None, body["content"]
        if body["type"] == "none":
            return "", None
        content = body.get("content")
        if isinstance(content, bytes):
            content = content.decode("utf-8")
        return content, None
    if message.get("parsed_body") is not None:  # vcrpy + pydantic-ai's serializer
        return None, message["parsed_body"]
    if isinstance(body, dict):
        content = body.get("string")
        if isinstance(content, bytes):
            content = content.decode("utf-8")
        return content, None
    return body, None


def read_cassette(path, index):
    interactions = cassette(path)["interactions"]
    interaction = interactions[index]
    request, response = interaction["request"], interaction["response"]
    req_text, req_json = body_of(request)
    if req_json is None and req_text:
        req_json = json.loads(req_text)
    res_text, res_json = body_of(response)
    status = response.get("status")
    if isinstance(status, dict):
        status = status.get("code")
    headers = {}
    for name, values in (response.get("headers") or {}).items():
        if name.lower() in KEPT_RESPONSE_HEADERS:
            headers[name.lower()] = values[0] if isinstance(values, list) else values
    return {
        "uri": request["uri"],
        "request": req_json,
        "responseText": res_text,
        "responseJSON": res_json,
        "status": status,
        "headers": headers,
    }


def frame_chunks(lines, protocol):
    """Vercel's `.chunks.txt` (one JSON payload per line) as the SSE stream
    the provider sends: Chat `data:` lines ending in `[DONE]`; Anthropic and
    Responses with `event:` names equal to the payload type; Gemini bare
    `data:` frames."""
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line == "[DONE]":
            continue
        payload = json.loads(line)
        if protocol in ("anthropic", "responses") and isinstance(payload, dict) and "type" in payload:
            out.append("event: %s\ndata: %s\n\n" % (payload["type"], line))
        else:
            out.append("data: %s\n\n" % line)
    if protocol == "chat":
        out.append("data: [DONE]\n\n")
    return "".join(out)


# --- Facts: what a recorded response says, read independently of Unladen -------


def sse_events(text):
    """(event name, data) pairs of an SSE body; comments dropped."""
    events = []
    name, data = None, []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw == "":
            if data:
                events.append((name, "\n".join(data)))
            name, data = None, []
            continue
        if raw.startswith(":"):
            continue
        field, _, value = raw.partition(":")
        if value.startswith(" "):
            value = value[1:]
        if field == "event":
            name = value
        elif field == "data":
            data.append(value)
    if data:
        events.append((name, "\n".join(data)))
    return events


def parse_args(text):
    try:
        return json.loads(text) if text.strip() else {}
    except ValueError:
        return {"$raw": text}


class Facts:
    def __init__(self):
        self.text = []
        self.reasoning = []
        self.signed = False
        self.calls = []
        self.finish = None
        self.input = None
        self.output = None
        self.error = None
        self.refusal = []
        self.blocked = None

    def as_json(self):
        facts = {
            "text": "".join(self.text),
            "reasoning": "".join(self.reasoning),
            "signedReasoning": self.signed,
            "toolCalls": [{"name": name, "arguments": parse_args(args)} for name, args in self.calls],
        }
        if self.refusal:
            facts["refusal"] = "".join(self.refusal)
        if self.finish is not None:
            facts["finish"] = self.finish
        if self.blocked is not None:
            facts["blocked"] = self.blocked
        usage = {}
        if self.input is not None:
            usage["input"] = self.input
        if self.output is not None:
            usage["output"] = self.output
        if usage:
            facts["usage"] = usage
        if self.error is not None:
            facts["error"] = self.error
        return facts


def error_message(value):
    if isinstance(value, dict):
        inner = value.get("error", value)
        if isinstance(inner, dict):
            return inner.get("message") or json.dumps(inner, sort_keys=True)
        return str(inner)
    if isinstance(value, list) and value:
        return error_message(value[0])
    return str(value)


def chat_content(facts, content):
    if isinstance(content, str):
        facts.text.append(content)
    elif isinstance(content, list):  # Mistral's typed parts
        for part in content:
            kind = part.get("type")
            if kind == "text":
                facts.text.append(part.get("text", ""))
            elif kind == "thinking":
                for inner in part.get("thinking", []):
                    if inner.get("type") == "text":
                        facts.reasoning.append(inner.get("text", ""))


def chat_reasoning(message):
    """Reasoning text in any of the Chat dialects' fields: DeepSeek/Kimi
    `reasoning_content`, OpenRouter/Groq `reasoning`, Copilot
    `reasoning_text`."""
    for key in ("reasoning_content", "reasoning", "reasoning_text"):
        if isinstance(message.get(key), str):
            return message[key]
    return None


def is_thought(message):
    """Gemini's OpenAI-compatible API marks thought text in `content` with
    `extra_content.google.thought`."""
    return ((message.get("extra_content") or {}).get("google") or {}).get("thought") is True


def gemini_signed(holder):
    """Gemini's OpenAI-compatible API gives a thought signature in
    `extra_content.google.thought_signature` (on messages, stream deltas and
    tool calls)."""
    return bool(((holder.get("extra_content") or {}).get("google") or {}).get("thought_signature"))


def chat_signed(message):
    """Signed reasoning in a Chat message or delta: a Gemini thought
    signature (on it or its tool calls), or an OpenRouter
    `reasoning_details` entry with a signature or encrypted data."""
    if gemini_signed(message) or any(gemini_signed(call) for call in message.get("tool_calls") or []):
        return True
    return any(entry.get("signature") or entry.get("data") for entry in message.get("reasoning_details") or [])


def chat_usage(facts, usage):
    if isinstance(usage, dict):
        facts.input = usage.get("prompt_tokens", facts.input)
        facts.output = usage.get("completion_tokens", facts.output)


def chat_facts(json_body, text_body):
    facts = Facts()
    if json_body is not None:
        if "error" in json_body:
            facts.error = error_message(json_body)
            return facts
        choice = (json_body.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        reasoning = chat_reasoning(message)
        if isinstance(reasoning, str):
            facts.reasoning.append(reasoning)
        if is_thought(message):
            facts.reasoning.append(message.get("content") or "")
        else:
            chat_content(facts, message.get("content"))
        if message.get("refusal"):
            facts.refusal.append(message["refusal"])
        facts.signed = chat_signed(message)
        for call in message.get("tool_calls") or []:
            function = call.get("function", {})
            facts.calls.append((function.get("name"), function.get("arguments") or ""))
        facts.finish = choice.get("finish_reason")
        chat_usage(facts, json_body.get("usage"))
        return facts
    calls, current = [], {}
    for _, data in sse_events(text_body):
        if data == "[DONE]":
            continue
        chunk = json.loads(data)
        if "error" in chunk:
            facts.error = error_message(chunk)
            continue
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            reasoning = chat_reasoning(delta)
            if isinstance(reasoning, str):
                facts.reasoning.append(reasoning)
            if is_thought(delta):
                facts.reasoning.append(delta.get("content") or "")
            else:
                chat_content(facts, delta.get("content"))
            if delta.get("refusal"):
                facts.refusal.append(delta["refusal"])
            facts.signed = facts.signed or chat_signed(delta)
            for position, call in enumerate(delta.get("tool_calls") or []):
                index = call.get("index", position)
                entry = current.get(index)
                if entry is None or (call.get("id") and entry[2] and call["id"] != entry[2]):
                    # A new call: a new index, or (relays that send no
                    # index) a new id at the same position.
                    entry = ["", "", call.get("id")]
                    calls.append(entry)
                    current[index] = entry
                function = call.get("function") or {}
                if function.get("name"):
                    entry[0] = function["name"]
                entry[1] += function.get("arguments") or ""
            if choice.get("finish_reason"):
                facts.finish = choice["finish_reason"]
        chat_usage(facts, chunk.get("usage"))
    facts.calls = [(name, arguments) for name, arguments, _ in calls]
    return facts


def responses_output(facts, response):
    for item in response.get("output") or []:
        kind = item.get("type")
        if kind == "message":
            for part in item.get("content") or []:
                if part.get("type") == "output_text":
                    facts.text.append(part.get("text", ""))
                elif part.get("type") == "refusal":
                    facts.refusal.append(part.get("refusal", ""))
        elif kind == "reasoning":
            for part in item.get("summary") or []:
                facts.reasoning.append(part.get("text", ""))
            for part in item.get("content") or []:
                facts.reasoning.append(part.get("text", ""))
            if item.get("encrypted_content"):
                facts.signed = True
        elif kind == "function_call":
            facts.calls.append((item.get("name"), item.get("arguments") or ""))
    status = response.get("status")
    incomplete = (response.get("incomplete_details") or {}).get("reason")
    facts.finish = incomplete or status
    usage = response.get("usage") or {}
    if usage:
        facts.input = usage.get("input_tokens")
        facts.output = usage.get("output_tokens")
    if response.get("error"):
        facts.error = error_message(response["error"])


def responses_facts(json_body, text_body):
    facts = Facts()
    if json_body is not None:
        if "error" in json_body and "output" not in json_body:
            facts.error = error_message(json_body)
            return facts
        responses_output(facts, json_body)
        return facts
    for name, data in sse_events(text_body):
        event = json.loads(data)
        kind = event.get("type", name)
        if kind in ("response.completed", "response.incomplete", "response.failed"):
            responses_output(facts, event.get("response") or {})
        elif kind == "error":
            facts.error = error_message(event)
    return facts


def anthropic_usage(facts, usage, start):
    if not isinstance(usage, dict):
        return
    if "input_tokens" in usage and (start or usage.get("input_tokens") is not None):
        facts.input = (usage.get("input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0) + (
            usage.get("cache_creation_input_tokens") or 0)
    if "output_tokens" in usage:
        facts.output = usage["output_tokens"]


def anthropic_block(facts, block):
    kind = block.get("type")
    if kind == "text":
        facts.text.append(block.get("text", ""))
    elif kind == "thinking":
        facts.reasoning.append(block.get("thinking", ""))
        if block.get("signature"):
            facts.signed = True
    elif kind == "redacted_thinking":
        facts.signed = True
    elif kind == "tool_use":
        facts.calls.append((block.get("name"), json.dumps(block.get("input", {}))))


def anthropic_facts(json_body, text_body):
    facts = Facts()
    if json_body is not None:
        if json_body.get("type") == "error":
            facts.error = error_message(json_body)
            return facts
        for block in json_body.get("content") or []:
            anthropic_block(facts, block)
        facts.finish = json_body.get("stop_reason")
        anthropic_usage(facts, json_body.get("usage"), True)
        return facts
    blocks = {}
    for name, data in sse_events(text_body):
        event = json.loads(data)
        kind = event.get("type", name)
        if kind == "message_start":
            anthropic_usage(facts, event["message"].get("usage"), True)
        elif kind == "content_block_start":
            block = dict(event["content_block"])
            if block.get("type") == "tool_use":
                block["partial"] = ""
            blocks[event["index"]] = block
        elif kind == "content_block_delta":
            block, delta = blocks[event["index"]], event["delta"]
            dtype = delta.get("type")
            if dtype == "text_delta":
                block["text"] = block.get("text", "") + delta["text"]
            elif dtype == "thinking_delta":
                block["thinking"] = block.get("thinking", "") + delta["thinking"]
            elif dtype == "signature_delta":
                block["signature"] = block.get("signature", "") + delta["signature"]
            elif dtype == "input_json_delta":
                block["partial"] = block.get("partial", "") + delta["partial_json"]
        elif kind == "content_block_stop":
            pass
        elif kind == "message_delta":
            facts.finish = (event.get("delta") or {}).get("stop_reason") or facts.finish
            anthropic_usage(facts, event.get("usage"), False)
        elif kind == "error":
            facts.error = error_message(event)
    for index in sorted(blocks):
        block = blocks[index]
        if block.get("type") == "tool_use":
            facts.calls.append((block.get("name"), block.get("partial") or json.dumps(block.get("input") or {})))
        else:
            anthropic_block(facts, block)
    return facts


def gemini_chunk(facts, chunk):
    if "error" in chunk:
        facts.error = error_message(chunk)
        return
    for candidate in (chunk.get("candidates") or [])[:1]:
        for part in (candidate.get("content") or {}).get("parts") or []:
            if part.get("thoughtSignature"):
                facts.signed = True
            if "functionCall" in part:
                call = part["functionCall"]
                facts.calls.append((call.get("name"), json.dumps(call.get("args", {}))))
            elif "text" in part:
                (facts.reasoning if part.get("thought") else facts.text).append(part["text"])
        if candidate.get("finishReason"):
            facts.finish = candidate["finishReason"]
    if not chunk.get("candidates") and (chunk.get("promptFeedback") or {}).get("blockReason"):
        facts.blocked = chunk["promptFeedback"]["blockReason"]
    usage = chunk.get("usageMetadata")
    if usage:
        facts.input = usage.get("promptTokenCount", facts.input)
        if "candidatesTokenCount" in usage:
            facts.output = usage["candidatesTokenCount"] + (usage.get("thoughtsTokenCount") or 0)


def gemini_facts(json_body, text_body):
    facts = Facts()
    if json_body is not None:
        chunks = json_body if isinstance(json_body, list) else [json_body]
    else:
        chunks = [json.loads(data) for _, data in sse_events(text_body)]
    for chunk in chunks:
        gemini_chunk(facts, chunk)
    return facts


FACTS = {"chat": chat_facts, "responses": responses_facts, "anthropic": anthropic_facts, "gemini": gemini_facts}

# --- Writing -------------------------------------------------------------------


def git_commit(repo_dir):
    return subprocess.run(
        ["git", "-C", repo_dir, "rev-parse", "--short", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def dump_json(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def model_from_uri(uri):
    match = re.search(r"/models/([^/:?]+)", uri or "")
    return match.group(1) if match else None


def build_case(entry, repos_root, commits):
    source = entry["source"]
    repo_dir = os.path.join(repos_root, REPOS[source][0])
    path = os.path.join(repo_dir, entry["path"])
    protocol = entry["protocol"]
    kind = entry.get("kind", "cassette")
    files = {}
    scrubbed = 0
    status, headers, uri, request = entry.get("status", 200), dict(entry.get("headers", {})), None, None
    response_text = response_json = None

    if kind == "cassette":
        recorded = read_cassette(path, entry.get("interaction", 0))
        status, uri, request = recorded["status"], recorded["uri"], recorded["request"]
        headers.update(recorded["headers"])
        response_text, response_json = recorded["responseText"], recorded["responseJSON"]
        if response_json is None and response_text and response_text.lstrip().startswith(("{", "[")):
            response_json = json.loads(response_text)
            response_text = None
    elif kind == "chunks":
        with open(path, encoding="utf-8") as handle:
            response_text = frame_chunks(handle.read().splitlines(), protocol)
    elif kind == "sse":
        with open(path, encoding="utf-8") as handle:
            response_text = handle.read()
    elif kind == "json":
        with open(path, encoding="utf-8") as handle:
            response_json = json.load(handle)
    elif kind == "request":
        with open(path, encoding="utf-8") as handle:
            request = json.load(handle)
    elif kind == "inline":
        # A body quoted in the source's tests (not a capture of its own):
        # the manifest carries it, `path` names where it is quoted.
        if not os.path.exists(path):
            raise SystemExit("%s: source %s is missing" % (entry["id"], path))
        response_json = entry["body"]
    else:
        raise SystemExit("unknown kind %r in %s" % (kind, entry["id"]))

    if entry.get("requestPath"):
        with open(os.path.join(repo_dir, entry["requestPath"]), encoding="utf-8") as handle:
            request = json.load(handle)

    if request is not None:
        text = dump_json(request)
        if entry.get("scrubClientIDs"):
            text = scrub_client_ids(text)
        text, n = scrub(text)
        scrubbed += n
        files["request.json"] = text
    if response_json is not None:
        text, n = scrub(dump_json(response_json))
        scrubbed += n
        files["response.json"] = text
    elif response_text is not None:
        text, n = scrub(response_text)
        scrubbed += n
        files["response.sse"] = text

    meta = {
        "id": entry["id"],
        "source": {
            "repo": REPOS[source][1],
            "licence": REPOS[source][2],
            "commit": commits[source],
            "path": entry["path"],
        },
        "vendor": entry["id"].split("/")[0],
        "protocol": protocol,
        "status": status,
    }
    if kind == "cassette":
        meta["source"]["interaction"] = entry.get("interaction", 0)
    if entry.get("requestPath"):
        meta["source"]["requestPath"] = entry["requestPath"]
    if kind == "chunks":
        meta["source"]["note"] = "one JSON payload per line in the source; SSE framing added by the importer"
    for key in ("target", "model", "notes", "expect", "client"):
        if key in entry:
            meta[key] = entry[key]
    if "model" not in meta:
        model = (request or {}).get("model") if isinstance(request, dict) else None
        meta["model"] = model or model_from_uri(uri)
    if uri:
        host, _, rest = uri.split("://", 1)[-1].partition("/")
        meta["host"] = host
        meta["path"] = re.sub(r"[?&]key=[^&]*", "", "/" + rest)
    if headers:
        meta["headers"] = dict(sorted(headers.items()))
    meta["stream"] = "response.sse" in files
    if scrubbed:
        meta["scrubbed"] = scrubbed
    if "response.json" in files or "response.sse" in files:
        body_json = json.loads(files["response.json"]) if "response.json" in files else None
        body_text = files.get("response.sse")
        if status is not None and status >= 400:
            meta["facts"] = {"error": error_message(body_json) if body_json is not None else body_text}
        else:
            meta["facts"] = FACTS[protocol](body_json, body_text).as_json()
    files["case.json"] = dump_json(meta)
    return files


def audit(files, case_id):
    for name, text in files.items():
        for pattern, _ in SECRET_PATTERNS[:-1]:
            for match in pattern.finditer(text):
                if "REDACTED" not in match.group(0):
                    raise SystemExit("%s/%s still matches %s" % (case_id, name, pattern.pattern))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repos", default=os.path.dirname(PACKAGE), help="directory holding the reference checkouts")
    parser.add_argument("--only", default="", help="import only case ids starting with this")
    parser.add_argument("--check", action="store_true", help="report drift instead of writing")
    args = parser.parse_args()

    with open(os.path.join(HERE, "manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    commits = {key: git_commit(os.path.join(args.repos, value[0])) for key, value in REPOS.items() if key != "unladen"}
    commits["unladen"] = "-"
    ids = set()
    drift = []
    for entry in manifest["cases"]:
        if entry["id"] in ids:
            raise SystemExit("duplicate case id %s" % entry["id"])
        ids.add(entry["id"])
        if not entry["id"].startswith(args.only):
            continue
        files = build_case(entry, args.repos, commits)
        audit(files, entry["id"])
        directory = os.path.join(OUT, *entry["id"].split("/"))
        for name, text in sorted(files.items()):
            target = os.path.join(directory, name)
            old = open(target, encoding="utf-8", newline="").read() if os.path.exists(target) else None
            if old == text:
                continue
            if args.check:
                drift.append(target)
                continue
            os.makedirs(directory, exist_ok=True)
            with open(target, "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
    if not args.only and os.path.isdir(OUT):
        for vendor in sorted(os.listdir(OUT)):
            if not os.path.isdir(os.path.join(OUT, vendor)):
                continue  # e.g. THIRD_PARTY_NOTICES.md
            for case in sorted(os.listdir(os.path.join(OUT, vendor))):
                if "%s/%s" % (vendor, case) not in ids:
                    drift.append(os.path.join(OUT, vendor, case) + " (not in the manifest)")
    if drift:
        print("\n".join(drift))
        if args.check:
            sys.exit(1)
    print("%d cases" % len(ids))


if __name__ == "__main__":
    main()
