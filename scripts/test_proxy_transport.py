#!/usr/bin/env python3
"""Local-only proxy transport regression checks; pass the Zig harness executable."""
import base64
import hashlib
import http.client
import http.server
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.parse

hits, requests = [], []
class Origin(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        requests.append((self.path, dict(self.headers)))
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', f'http://localhost:{self.server.server_port}/payload')
            self.end_headers()
        else:
            self.send_response(404 if self.path == '/missing' else 200)
            self.send_header('Content-Length', '7')
            self.end_headers()
            self.wfile.write(b'payload')
    def do_POST(self):
        assert self.rfile.read(int(self.headers['Content-Length'])) == b'accepted=yes'
        self.send_response(303)
        self.send_header('Location', '/payload')
        self.end_headers()

class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_CONNECT(self):
        hits.append(('CONNECT', self.path, self.headers.get('Proxy-Authorization')))
        host, port = self.path.rsplit(':', 1)
        with socket.create_connection((host, int(port))) as upstream:
            self.send_response(200)
            self.end_headers()
            while True:
                ready, _, _ = select.select([upstream, self.connection], [], [], 5)
                if not ready: break
                for source in ready:
                    data = source.recv(65536)
                    if not data: return
                    (self.connection if source is upstream else upstream).sendall(data)
    def forward(self):
        hits.append((self.command, self.path, self.headers.get('Proxy-Authorization')))
        url = urllib.parse.urlsplit(self.path)
        conn = http.client.HTTPConnection(url.hostname, url.port)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ('proxy-authorization', 'proxy-connection')}
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        conn.request(self.command, url.path, body or None, headers)
        response = conn.getresponse()
        data = response.read()
        self.send_response(response.status)
        for k, v in response.getheaders():
            if k.lower() not in ('connection', 'transfer-encoding', 'content-length'):
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        conn.close()
    do_GET = forward
    do_POST = forward

def serve(handler):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

with tempfile.TemporaryDirectory() as temp:
    cert, key = str(Path(temp) / 'cert.pem'), str(Path(temp) / 'key.pem')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], check=True, capture_output=True)
    origin, tls, proxy = serve(Origin), serve(Origin), serve(Proxy)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    direct = f'http://127.0.0.1:{origin.server_port}'
    secure = f'https://localhost:{tls.server_port}'
    proxy_url = f'http://user:pass@127.0.0.1:{proxy.server_port}'
    env = {k: v for k, v in os.environ.items() if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy') and k != 'REQUEST_METHOD'}
    env['CURL_CA_BUNDLE'] = cert
    def run(kind, url, extra=None, args=(), success=True):
        result = subprocess.run([sys.argv[1], kind, url, *args], env={**env, **(extra or {})}, capture_output=True, timeout=15)
        assert (result.returncode == 0) == success, (result.returncode, result.stderr)
        if success and kind in ('get', 'post'): assert result.stdout == b'payload', result.stdout
        return result
    run('get', direct + '/payload')  # native transport
    run('get', direct + '/payload', {'HTTP_PROXY': proxy_url})
    assert hits[-1][0] == 'GET'
    assert hits[-1][2] == 'Basic ' + base64.b64encode(b'user:pass').decode()
    run('get', secure + '/payload', {'HTTPS_PROXY': proxy_url})
    assert hits[-1][0] == 'CONNECT'
    before = len(hits)
    run('get', direct + '/payload', {'HTTP_PROXY': proxy_url, 'NO_PROXY': '127.0.0.1'})
    run('get', secure + '/payload', {'HTTPS_PROXY': proxy_url, 'no_proxy': '*'})
    run('get', direct + '/payload', {'HTTP_PROXY': 'http://127.0.0.1:1', 'REQUEST_METHOD': 'GET'})
    assert len(hits) == before
    run('get', direct + '/redirect', {'http_proxy': proxy_url, 'NO_PROXY': 'localhost'})
    assert len(hits) == before + 1  # redirected host bypasses proxy
    assert 'Authorization' not in requests[-1][1]
    run('get', direct + '/payload', {'http_proxy': proxy_url, 'HTTP_PROXY': 'http://127.0.0.1:1'})
    run('post', direct + '/form', {'http_proxy': proxy_url})
    assert 'Content-Type' not in requests[-1][1]
    assert all('Proxy-Authorization' not in headers for _, headers in requests)
    out = str(Path(temp) / 'download')
    sha = hashlib.sha256(b'payload').hexdigest()
    run('download', direct + '/payload', {'ALL_PROXY': proxy_url}, (out, sha))
    assert Path(out).read_bytes() == b'payload'
    run('download', direct + '/payload', {'ALL_PROXY': proxy_url}, (out, '0' * 64), False)
    assert Path(out).read_bytes() == b'payload'  # preserve the previous valid file
    Path(out).unlink()
    run('download', direct + '/missing', {'ALL_PROXY': proxy_url}, (out, sha), False)
    assert not Path(out).exists()
    assert not list(Path(temp).glob('*.proxy'))
    for server in (origin, tls, proxy): server.shutdown()
print('Proxy transport: native, HTTP, CONNECT/TLS, auth isolation, bypass, redirect, POST, SHA and failure cleanup passed')
