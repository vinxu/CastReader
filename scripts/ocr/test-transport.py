#!/usr/bin/env python3
"""Exercise production URLSession delegates against real bounded HTTP faults."""
import http.server,threading,time,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
data=bytes(i%251 for i in range(1024))
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  path=self.path
  if path=='/unavailable':self.send_error(503);return
  if path=='/redirect':self.send_response(302);self.send_header('Location','/good');self.end_headers();return
  if path=='/timeout':time.sleep(12)
  body=bytes(len(data)) if path=='/corrupt' else data*256 if path=='/oversize' else data
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers()
  try:self.wfile.write(body[:12] if path=='/short' else body)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory() as d:
 binary=Path(d)/'probe'
 subprocess.run(['swiftc','-parse-as-library','CastReader/Services/OCRModelCatalog.swift','CastReader/Services/OCRModelStore.swift','scripts/ocr/transport-probe.swift','-o',str(binary)],cwd=root,check=True)
 subprocess.run([str(binary),f'http://127.0.0.1:{server.server_port}'],cwd=root,check=True,timeout=100)
server.shutdown()
