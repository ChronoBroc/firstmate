#!/usr/bin/env python3
"""Local Claude API stand-in: answers with a Bash `sleep <secs>` tool call until <n> tool
results have come back, then ends the turn. One long healthy turn, no tokens spent."""
import http.server, json, sys
port_file, n, secs = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def results(body):
    c = 0
    for m in body.get("messages") or []:
        if isinstance(m.get("content"), list):
            c += sum(1 for p in m["content"] if isinstance(p, dict) and p.get("type") == "tool_result")
    return c
def events(body):
    usage = {"input_tokens": 1, "output_tokens": 1}
    yield "message_start", {"type": "message_start", "message": {"id": "msg_stub", "type": "message", "role": "assistant", "model": body.get("model", "stub"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}
    names = [t.get("name") for t in body.get("tools") or []]
    k = results(body)
    if "Bash" in names and k < n:
        yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_%d" % k, "name": "Bash", "input": {}}}
        yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps({"command": "python3 -c \"import time; time.sleep(%s)\"; echo step %d" % (secs, k), "description": "step"})}}
        stop = "tool_use"
    else:
        yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}
        yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "done"}}
        stop = "end_turn"
    yield "content_block_stop", {"type": "content_block_stop", "index": 0}
    yield "message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}
def whole(body):
    msg = None
    for name, ev in events(body):
        if name == "message_start": msg = ev["message"]
        elif name == "content_block_start": msg["content"].append(ev["content_block"])
        elif name == "content_block_delta":
            b, d = msg["content"][-1], ev["delta"]
            if d["type"] == "text_delta": b["text"] += d["text"]
            else: b["input"] = json.loads(d["partial_json"])
        elif name == "message_delta": msg["stop_reason"] = ev["delta"]["stop_reason"]
    return msg
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, ct, data):
        self.send_response(200); self.send_header("content-type", ct); self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        if "/v1/messages" not in self.path or "count_tokens" in self.path:
            return self.reply("application/json", b'{"input_tokens":1}')
        try: body = json.loads(raw or b"{}")
        except ValueError: body = {}
        if body.get("stream"):
            self.reply("text/event-stream", b"".join(b"event: " + a.encode() + b"\ndata: " + json.dumps(e).encode() + b"\n\n" for a, e in events(body)))
        else:
            self.reply("application/json", json.dumps(whole(body)).encode())
    def do_GET(self): self.reply("application/json", b"{}")
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
