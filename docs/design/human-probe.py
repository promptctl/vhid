"""Serves human-probe.html and appends each batch it posts to events.jsonl, one event a line.

Run beside the page: python3 human-probe.py, then open http://localhost:8765/.
"""
import http.server
import json
import pathlib
import threading

here = pathlib.Path(__file__).parent
out = pathlib.Path.cwd() / "events.jsonl"
written = {}  # events written, by page load
lock = threading.Lock()


class Probe(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (here / "human-probe.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        batch = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with lock, out.open("a") as f:
            # A batch resent after a lost response overlaps what is written; skip that part.
            for i, event in enumerate(batch["events"], batch["from"]):
                if i >= written.get(batch["page"], 0):
                    f.write(json.dumps(event) + "\n")
                    written[batch["page"]] = i + 1
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", 8765), Probe).serve_forever()
