#!/usr/bin/python3
"""serve.py DIRECTORY [PORT]: serve DIRECTORY's files over HTTP (default port
8099) with Range requests, which CIMC's virtual media needs and Python's
http.server lacks; logs every request. /phone-home (the installer's last
command) is logged too."""
import http.server, os, re, sys, time
ROOT = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
	protocol_version = "HTTP/1.1"
	def log_message(self, fmt, *args):
		sys.stdout.write("%s %s %s %s\n" % (time.strftime("%H:%M:%S"), self.client_address[0], fmt % args, self.headers.get("Range", "")))
		sys.stdout.flush()
	def do_HEAD(self): self.serve(False)
	def do_GET(self): self.serve(True)
	def serve(self, body):
		path = self.path.split("?")[0]
		if path == "/phone-home":
			sys.stdout.write("PHONE-HOME %s %s\n" % (self.client_address[0], self.path)); sys.stdout.flush()
			self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers(); return
		name = os.path.basename(path)
		full = os.path.join(ROOT, name)
		if not name or not os.path.isfile(full):
			self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
		size = os.path.getsize(full)
		start, end = 0, size - 1
		m = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
		if m and (m.group(1) or m.group(2)):
			if m.group(1):
				start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
			else:
				start = max(0, size - int(m.group(2)))
			end = min(end, size - 1)
			if start > end:
				self.send_response(416); self.send_header("Content-Range", "bytes */%d" % size)
				self.send_header("Content-Length", "0"); self.end_headers(); return
			self.send_response(206)
			self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
		else:
			self.send_response(200)
		self.send_header("Content-Type", "application/octet-stream")
		self.send_header("Accept-Ranges", "bytes")
		self.send_header("Content-Length", str(end - start + 1))
		self.end_headers()
		if not body: return
		with open(full, "rb") as f:
			f.seek(start); left = end - start + 1
			while left > 0:
				chunk = f.read(min(1 << 20, left))
				if not chunk: break
				self.wfile.write(chunk); left -= len(chunk)
http.server.ThreadingHTTPServer(("", int(sys.argv[2]) if len(sys.argv) > 2 else 8099), H).serve_forever()
