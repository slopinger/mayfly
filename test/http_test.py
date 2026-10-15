#!/usr/bin/env python3
"""Isolated HTTP regression test against a production Erlang shipment."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    PORT = sock.getsockname()[1]
BASE = f'http://127.0.0.1:{PORT}'


def request(path, data=None, method='GET', headers=None):
    req = urllib.request.Request(BASE + path if path.startswith('/') else path,
                                 data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, response.read(), response.headers
    except urllib.error.HTTPError as response:
        return response.code, response.read(), response.headers


def upload(fields=None, content=b'hello from the temporary internet', path='/api/upload', ip='test'):
    boundary = 'mayfly-regression-boundary'
    fields = [('reqtype', 'fileupload'), ('time', '24h')] if fields is None else fields
    body = b''
    for name, value in fields:
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
    body += f'--{boundary}\r\nContent-Disposition: form-data; name="fileToUpload"; filename="hello.txt"\r\nContent-Type: text/plain\r\n\r\n'.encode()
    body += content + f'\r\n--{boundary}--\r\n'.encode()
    return request(path, body, 'POST', {'Content-Type': f'multipart/form-data; boundary={boundary}', 'X-Real-IP': ip})


with tempfile.TemporaryDirectory(prefix='mayfly-http-', dir=os.environ.get('MAYFLY_TEST_TMPDIR')) as directory:
    logfile = open(Path(directory) / 'server.log', 'w+')
    env = dict(os.environ, MAYFLY_DATA=directory, MAYFLY_URL=BASE, MAYFLY_PORT=str(PORT), ERL_FLAGS='+S 2:2')
    server = None

    def stop():
        global server
        if server:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            server = None

    def start():
        global server
        server = subprocess.Popen([str(ROOT / 'build/erlang-shipment/entrypoint.sh'), 'run'],
                                  cwd=ROOT, env=env, stdout=logfile, stderr=logfile)
        for _ in range(100):
            if server.poll() is not None:
                logfile.seek(0)
                raise AssertionError(logfile.read())
            try:
                if request('/healthz')[0] == 200:
                    return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(.1)
        raise AssertionError('server did not become ready')

    try:
        start()
        for path, kind in [('/', 'text/html'), ('/style.css', 'text/css'), ('/app.js', 'text/javascript')]:
            status, body, headers = request(path)
            assert status == 200 and headers['Content-Type'].startswith(kind), (path, status)
            assert body and headers['X-Content-Type-Options'] == 'nosniff'
        assert (Path(directory) / 'tmp').is_dir(), 'upload staging must use the data filesystem'
        assert request('/api/upload')[0] == 405
        assert request('/f/../../etc/passwd')[0] == 404
        assert request('/api/upload', b'', 'POST', {'Origin': 'https://evil.invalid'})[0] == 403
        assert upload([('time', '2h')])[0] == 400
        assert upload([('time', '1h'), ('time', '72h')])[0] == 400
        assert upload([('reqtype', 'urlupload')])[0] == 400
        assert upload(content=b'')[0] == 503
        assert upload([('time', 'x' * 9000)])[0] == 413
        status, body, _ = upload()
        assert status == 200, (status, body)
        result = json.loads(body)
        assert result['expires'] > time.time() * 1000 + 23 * 3600 * 1000
        status, body, headers = request(result['url'])
        assert status == 200 and body == b'hello from the temporary internet'
        assert headers['Content-Disposition'].startswith('attachment;')
        assert headers['Content-Type'] == 'application/octet-stream'
        assert headers['Content-Security-Policy'] == "sandbox; default-src 'none'"
        assert request(result['url'], method='HEAD')[0] == 200
        assert request(result['delete_url'])[0] == 405
        assert request(result['delete_url'][:-1] + 'z', method='DELETE')[0] == 404
        assert request(result['delete_url'], method='DELETE')[0] == 204
        assert request(result['url'])[0] == 404
        status, body, headers = upload(path='/resources/internals/api.php', fields=[('time', '12h')])
        assert status == 200 and body.decode().startswith(BASE + '/f/')
        assert headers['Content-Type'].startswith('text/plain')
        # Restart proves persisted links survive a new VM/runtime.
        survivor = body.decode().strip()
        stop()
        start()
        assert request(survivor)[0] == 200
        # Expired metadata is rejected and physically removed on startup.
        stop()
        metadata = Path(directory) / (survivor.rsplit('/', 1)[1] + '.json')
        entry = json.loads(metadata.read_text())
        entry['expires'] = int(time.time()) - 1
        metadata.write_text(json.dumps(entry))
        start()
        assert request(survivor)[0] == 404 and not metadata.exists()
        assert not Path(str(metadata)[:-5]).exists()
        for _ in range(20):
            status, body, _ = upload(ip='rate-test')
            assert status == 200, (status, body)
        assert upload(ip='rate-test')[0] == 429
        # Stream an oversized upload without allocating a huge request in RAM.
        boundary = 'oversize-test'
        prefix = f'--{boundary}\r\nContent-Disposition: form-data; name="fileToUpload"; filename="big.bin"\r\n\r\n'.encode()
        suffix = f'\r\n--{boundary}--\r\n'.encode()
        conn = http.client.HTTPConnection('127.0.0.1', PORT, timeout=60)
        conn.putrequest('POST', '/api/upload')
        conn.putheader('Content-Type', f'multipart/form-data; boundary={boundary}')
        conn.putheader('Content-Length', str(len(prefix) + 201*1024*1024 + len(suffix)))
        conn.putheader('X-Real-IP', 'size-test')
        conn.endheaders()
        try:
            conn.send(prefix)
            for _ in range(201):
                conn.send(b'x' * (1024*1024))
            conn.send(suffix)
        except (BrokenPipeError, ConnectionResetError):
            pass
        response = conn.getresponse()
        assert response.status == 413, response.status
        response.read()
        conn.close()
        print('HTTP checks passed: assets, upload/download, deletion, persistence, expiry, validation, rate and size limits')
    finally:
        stop()
        logfile.close()
