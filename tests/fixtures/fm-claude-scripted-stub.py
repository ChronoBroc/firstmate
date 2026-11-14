#!/usr/bin/env python3
"""Token-free stand-in for the Claude API that plays a worker from its own brief.

usage: fm-claude-scripted-stub.py <port-file> <log-file>

Binds an ephemeral loopback port and writes it to <port-file>. Each /v1/messages request is
answered from the latest user turn, so a real Claude Code session behaves like a worker with
no model behind it:

  - A turn whose text names a readable file (the launch prompt names the brief) reads it. When
    that brief carries a "## Progress note" (a relaunch), the worker reads its steering inbox:
    every *.msg under $FM_TASK_INBOX is appended to "$FM_TASK_INBOX.read" and moved into
    handled/. Otherwise every "STUB-RUN: <command>" line in it becomes one foreground Bash call,
    and every "STUB-BG: <command>" line one background Bash call.
  - A turn that is the steering doorbell reads the inbox the same way.
  - A turn carrying a tool result, or anything else, ends with a short text reply.

Each request is logged to <log-file> as one line: the action taken. No model is contacted.
"""
import http.server
import json
import os
import re
import sys

port_file, log_file = sys.argv[1], sys.argv[2]

INBOX = ('for f in "$FM_TASK_INBOX"/*.msg; do [ -e "$f" ] || continue; '
         'cat "$f" >> "$FM_TASK_INBOX.read"; mv "$f" "$FM_TASK_INBOX/handled/"; done')


def log(line):
    with open(log_file, "a") as out:
        out.write(line + "\n")


def latest_user(body):
    """The text of every user message since the last assistant message, and whether the
    newest one carries a tool result. Claude Code may send the typed prompt and its system
    reminders as separate parts or messages, so all of them are read together."""
    messages = body.get("messages") or []
    if not messages:
        return "", False
    text, tool_result = [], False
    for index in range(len(messages) - 1, -1, -1):
        message = messages[index]
        if message.get("role") == "assistant":
            break
        content = message.get("content")
        if isinstance(content, str):
            text.append(content)
            continue
        for part in content or []:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "tool_result" and index == len(messages) - 1:
                tool_result = True
            elif part.get("type") == "text":
                text.append(part.get("text", ""))
    return "\n".join(reversed(text)), tool_result


def plan(body):
    """Returns a list of (command, background) Bash calls for this turn, or []."""
    names = [tool.get("name") for tool in body.get("tools") or []]
    if "Bash" not in names:
        return []
    text, tool_result = latest_user(body)
    if tool_result:
        return []
    if "steering inbox" in text and "FM_TASK_INBOX" in text:
        return [(INBOX, False)]
    for path in re.findall(r"(/[^\s'\"`]+)", text):
        if not os.path.isfile(path):
            continue
        try:
            brief = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        # The launch prompt may name an operational record that names the brief.
        inner = [p for p in re.findall(r"(/[^\s'\"`]+\.md)", brief) if os.path.isfile(p)]
        for p in inner:
            try:
                brief += "\n" + open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                pass
        if "## Progress note" in brief:
            return [(INBOX, False)]
        calls = [(m.strip(), False) for m in re.findall(r"^STUB-RUN: (.+)$", brief, re.M)]
        calls += [(m.strip(), True) for m in re.findall(r"^STUB-BG: (.+)$", brief, re.M)]
        if calls:
            return calls
    return []


def events(body, calls):
    model = body.get("model", "stub")
    usage = {"input_tokens": 1, "output_tokens": 1}
    yield "message_start", {"type": "message_start", "message": {
        "id": "msg_stub", "type": "message", "role": "assistant", "model": model,
        "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}
    if calls:
        for i, (command, background) in enumerate(calls):
            tool_input = {"command": command, "description": "stub step %d" % i}
            if background:
                tool_input["run_in_background"] = True
            yield "content_block_start", {"type": "content_block_start", "index": i, "content_block": {
                "type": "tool_use", "id": "toolu_stub_%d" % i, "name": "Bash", "input": {}}}
            yield "content_block_delta", {"type": "content_block_delta", "index": i, "delta": {
                "type": "input_json_delta", "partial_json": json.dumps(tool_input)}}
            yield "content_block_stop", {"type": "content_block_stop", "index": i}
        stop = "tool_use"
    else:
        yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
            "type": "text", "text": ""}}
        yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
            "type": "text_delta", "text": "done"}}
        yield "content_block_stop", {"type": "content_block_stop", "index": 0}
        stop = "end_turn"
    yield "message_delta", {"type": "message_delta", "delta": {
        "stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}


def whole_message(body, calls):
    message = None
    for name, event in events(body, calls):
        if name == "message_start":
            message = event["message"]
        elif name == "content_block_start":
            message["content"].append(event["content_block"])
        elif name == "content_block_delta":
            block, delta = message["content"][-1], event["delta"]
            if delta["type"] == "text_delta":
                block["text"] += delta["text"]
            else:
                block["input"] = json.loads(delta["partial_json"])
        elif name == "message_delta":
            message["stop_reason"] = event["delta"]["stop_reason"]
    return message


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, ctype, data):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        if "/v1/messages" not in self.path or "count_tokens" in self.path:
            self.reply(200, "application/json", b'{"input_tokens":1}')
            return
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        calls = plan(body)
        text, tool_result = latest_user(body)
        names = [tool.get("name") for tool in body.get("tools") or []]
        log(("tools " + " | ".join(c for c, _ in calls) if calls else "text")
            + "\t[%d tools, bash=%s, tool_result=%s] %s" % (
                len(names), "Bash" in names, tool_result,
                " ".join(line for line in text.splitlines() if "Firstmate" in line)[:200]))
        if body.get("stream"):
            data = b"".join(
                b"event: " + name.encode() + b"\ndata: " + json.dumps(event).encode() + b"\n\n"
                for name, event in events(body, calls))
            self.reply(200, "text/event-stream", data)
        else:
            self.reply(200, "application/json", json.dumps(whole_message(body, calls)).encode())

    def do_GET(self):
        self.reply(200, "application/json", b"{}")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
