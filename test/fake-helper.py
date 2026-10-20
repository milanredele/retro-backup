#!/usr/bin/env python3
"""Minimal stand-in for retro-helper's HTTP API (CONTRACTS.md section 4), for client tests.

usage: fake-helper.py PORT DESTDIR

Implements GET /status, /free, /resume and POST /upload, /log. Every upload body is kept in
DESTDIR/uploads/NNN.tar and checked: it must be ONE valid tar archive (read in strict mode,
nothing but zero padding after the end-of-archive marker) whose last member is
.retro-manifest.tsv. Files are written to DESTDIR/BACKUP/<machine>/<volume>/<name> with the
contract's name rules, md5-checked against the manifest; mismatches are stored as .CORRUPT.
A line per request is appended to DESTDIR/requests.log.
"""
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
DEST = sys.argv[2]
LOCK = threading.Lock()
STATE = {}  # (machine, volume, group) -> {path: (size, md5)}


def clean_name(s):
    s = re.sub(r'[\\:*?"<>|\x00-\x1f]', '_', s)
    if s.endswith('.') or s.endswith(' '):
        s = s[:-1] + '_'
    return s


def clean_path(p):
    return '/'.join(clean_name(c) for c in p.split('/'))


def log_line(text):
    with LOCK, open(os.path.join(DEST, 'requests.log'), 'a', encoding='utf-8') as f:
        f.write(text + '\n')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        pass

    def reply(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            out = io.BytesIO()
            while True:
                line = self.rfile.readline()
                if not line:
                    break
                size = int(line.split(b';')[0].strip() or b'0', 16)
                if size == 0:
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                        pass
                    break
                out.write(self.rfile.read(size))
                self.rfile.readline()
            return out.getvalue()
        n = int(self.headers.get('Content-Length', '0'))
        return self.rfile.read(n)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        log_line('GET ' + self.path)
        if u.path == '/status':
            self.reply({'name': 'retro-helper', 'version': 'test', 'dest': DEST,
                        'free_bytes': 123456789012})
        elif u.path == '/free':
            self.reply({'free_bytes': 123456789012})
        elif u.path == '/resume':
            key = (q.get('machine'), q.get('volume'), q.get('group'))
            files = [{'path': p, 'size': s, 'md5': m}
                     for p, (s, m) in sorted(STATE.get(key, {}).items())]
            self.reply({'files': files})
        else:
            self.reply({'error': 'not found'}, 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        machine, volume, group = q.get('machine'), q.get('volume'), q.get('group')
        if u.path == '/log':
            data = self.body()
            d = os.path.join(DEST, 'BACKUP', machine)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, 'retro-backup.log'), 'ab') as f:
                f.write(data)
            log_line('POST ' + self.path + ' bytes=%d' % len(data))
            self.reply({'ok': True})
            return
        if u.path != '/upload':
            self.reply({'error': 'not found'}, 404)
            return
        try:
            data = self.body()
        except Exception as e:  # probe connections are cut by the client
            log_line('POST %s aborted %s' % (self.path, e))
            return
        if machine == '_probe':
            log_line('POST %s probe bytes=%d' % (self.path, len(data)))
            self.reply({'received': 0, 'bytes': len(data), 'verified': 0,
                        'mismatched': [], 'renamed': []})
            return
        updir = os.path.join(DEST, 'uploads')
        os.makedirs(updir, exist_ok=True)
        with LOCK:
            n = len(os.listdir(updir)) + 1
        tar_path = os.path.join(updir, '%03d.tar' % n)
        with open(tar_path, 'wb') as f:
            f.write(data)
        problems = []
        try:
            tf = tarfile.open(fileobj=io.BytesIO(data), mode='r:')
            members = tf.getmembers()
            end = tf.offset
        except Exception as e:
            log_line('POST %s INVALID-TAR %s' % (self.path, e))
            self.reply({'error': 'invalid tar: %s' % e}, 400)
            return
        if data[end:].strip(b'\0'):
            problems.append('data after the end-of-archive marker')
        if not members or members[-1].name != '.retro-manifest.tsv':
            problems.append('last member is %r' % (members[-1].name if members else None))
        manifest = {}
        man = [m for m in members if m.name == '.retro-manifest.tsv']
        if man:
            for line in tf.extractfile(man[-1]).read().decode('utf-8').splitlines():
                p, size, mtime, md5 = line.split('\t')
                manifest[p] = (int(size), int(mtime), md5)
        base = os.path.join(DEST, 'BACKUP', machine, volume)
        received = verified = total = 0
        mismatched, renamed = [], []
        for m in members:
            if not m.isfile() or m.name == '.retro-manifest.tsv':
                continue
            content = tf.extractfile(m).read()
            md5 = hashlib.md5(content).hexdigest()
            name = clean_path(m.name)
            if name != m.name:
                renamed.append([m.name, name])
            target = os.path.join(base, name)
            exp = manifest.get(m.name)
            if exp is None or exp[2] != md5 or exp[0] != len(content):
                mismatched.append(m.name)
                target += '.CORRUPT'
            else:
                verified += 1
                with LOCK:
                    STATE.setdefault((machine, volume, group), {})[m.name] = (len(content), md5)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'wb') as f:
                f.write(content)
            os.utime(target, (m.mtime, m.mtime))
            received += 1
            total += len(content)
        log_line('POST %s tar=%s members=%d last=%s problems=%s' % (
            self.path, os.path.basename(tar_path), len(members),
            members[-1].name if members else '-', ';'.join(problems) or 'none'))
        self.reply({'received': received, 'bytes': total, 'verified': verified,
                    'mismatched': mismatched, 'renamed': renamed})


os.makedirs(DEST, exist_ok=True)
ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
