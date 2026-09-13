import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
out = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n)
        with open(out, 'ab') as f:
            f.write(json.dumps({"path": self.path, "content_type": self.headers.get('Content-Type'), "body": json.loads(body)}).encode() + b"\n")
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
