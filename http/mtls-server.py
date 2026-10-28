import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ca, chain, key, ports_path = sys.argv[1:5]
ports = []

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        port = self.server.server_port
        required, optional = ports
        if port == required and self.path == '/same':
            status, body, location = 302, b'', f'https://localhost:{required}/who'
        elif port == required and self.path in ('/cross', '/back'):
            status, body, location = 302, b'', f'https://localhost:{optional}/' + ('inspect' if self.path == '/cross' else 'back')
        elif port == optional and self.path == '/back':
            status, body, location = 302, b'', f'https://localhost:{required}/who'
        elif port == optional:
            status, body, location = 200, b'leaked' if self.connection.getpeercert() else b'clean', None
        else:
            cert = self.connection.getpeercert()
            name = next((v for rdn in cert['subject'] for k, v in rdn if k == 'commonName'), '')
            status, body, location = 200, name.encode(), None
        self.send_response(status)
        if location:
            self.send_header('Location', location)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

for required in (True, False):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    ports.append(server.server_port)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(chain, key)
    ctx.load_verify_locations(ca)
    ctx.verify_mode = ssl.CERT_REQUIRED if required else ssl.CERT_OPTIONAL
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()

with open(ports_path + '.tmp', 'w') as f:
    f.write(' '.join(map(str, ports)) + '\n')
os.replace(ports_path + '.tmp', ports_path)
threading.Event().wait()
