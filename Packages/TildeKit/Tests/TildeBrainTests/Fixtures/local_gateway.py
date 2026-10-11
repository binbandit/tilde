"""Loopback-only Responses gateway. Dummy auth, deterministic SSE, no upstream calls."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        # Only synthetic request data reaches this fixture. Save the routing contract.
        with open(sys.argv[1], "a") as log:
            log.write(json.dumps({"path": self.path, "model": body.get("model"),
                                  "stream": body.get("stream"),
                                  "provider": self.headers.get("x-portkey-provider"),
                                  "key": self.headers.get("x-portkey-api-key"),
                                  "authorization": self.headers.get("Authorization")}) + "\n")
        routed = self.headers.get("x-portkey-provider") or body.get("model", "").startswith("@")
        if not routed:
            error = {"status": "failure", "message": "Passthrough target requires a provider. Provide x-portkey-provider header or model in the request body."}
            payload = json.dumps(error).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        response = {"id": "response-1", "object": "response", "created_at": 1,
                    "status": "in_progress", "model": body["model"], "output": []}
        item = {"id": "message-1", "type": "message", "role": "assistant",
                "status": "in_progress", "content": []}
        part = {"type": "output_text", "text": "", "annotations": []}
        self.event("response.created", response=response)
        self.event("response.output_item.added", output_index=0, item=item)
        self.event("response.content_part.added", item_id=item["id"], output_index=0, content_index=0, part=part)
        for delta in ("Hello ", "once."):
            self.event("response.output_text.delta", item_id=item["id"], output_index=0, content_index=0, delta=delta)
        part["text"] = "Hello once."
        self.event("response.output_text.done", item_id=item["id"], output_index=0, content_index=0, text=part["text"])
        self.event("response.content_part.done", item_id=item["id"], output_index=0, content_index=0, part=part)
        item.update(status="completed", content=[part])
        self.event("response.output_item.done", output_index=0, item=item)
        response.update(status="completed", output=[item], usage={"input_tokens": 1, "output_tokens": 2, "total_tokens": 3})
        self.event("response.completed", response=response)

    def event(self, kind, **data):
        payload = json.dumps({"type": kind, **data})
        self.wfile.write(f"event: {kind}\ndata: {payload}\n\n".encode())
        self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
print(server.server_port, flush=True)
server.serve_forever()
