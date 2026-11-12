#!/usr/bin/env python3
"""Token-free stand-in for the Claude API that drives one tool call, then ends the turn.

usage: fm-claude-tool-call-stub.py <port-file> <command>

Binds an ephemeral loopback port and writes it to <port-file>. A /v1/messages request whose
latest message carries no tool_result is answered with one Bash tool_use running <command>;
every other request is answered with a short text reply that ends the turn. Replies stream
when the request asks for a stream. No model is contacted, so a run costs no tokens.
"""
import http.server
import json
import sys

port_file, command = sys.argv[1], sys.argv[2]


def has_tool_result(body):
    messages = body.get("messages") or []
    if not messages:
        return False
    content = messages[-1].get("content")
    return isinstance(content, list) and any(
        isinstance(part, dict) and part.get("type") == "tool_result" for part in content
    )


def wants_tool(body):
    names = [tool.get("name") for tool in body.get("tools") or []]
    return "Bash" in names and not has_tool_result(body)


def events(body):
    model = body.get("model", "stub")
    usage = {"input_tokens": 1, "output_tokens": 1}
    yield "message_start", {"type": "message_start", "message": {
        "id": "msg_stub", "type": "message", "role": "assistant", "model": model,
        "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}
    if wants_tool(body):
        yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
            "type": "tool_use", "id": "toolu_stub", "name": "Bash", "input": {}}}
        yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
            "type": "input_json_delta",
            "partial_json": json.dumps({"command": command, "description": "stub"})}}
        stop = "tool_use"
    else:
        yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
            "type": "text", "text": ""}}
        yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
            "type": "text_delta", "text": "done"}}
        stop = "end_turn"
    yield "content_block_stop", {"type": "content_block_stop", "index": 0}
    yield "message_delta", {"type": "message_delta", "delta": {
        "stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}


def whole_message(body):
    message = None
    for name, event in events(body):
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
        if body.get("stream"):
            data = b"".join(
                b"event: " + name.encode() + b"\ndata: " + json.dumps(event).encode() + b"\n\n"
                for name, event in events(body))
            self.reply(200, "text/event-stream", data)
        else:
            self.reply(200, "application/json", json.dumps(whole_message(body)).encode())

    def do_GET(self):
        self.reply(200, "application/json", b"{}")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
