import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POD_NAME = socket.gethostname()


class Handler(BaseHTTPRequestHandler):
    def _respond(self, status, body):
        encoded = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, "ok")
        elif self.path == "/":
            self._respond(200, f"Hello, Kube! (from {POD_NAME})")
        else:
            self._respond(404, "not found")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 5000), Handler).serve_forever()
