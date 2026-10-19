#!/usr/bin/env python3
"""Real loopback HTTP/TLS/MCP tests, synthetic data only, no app/account writes."""
from pathlib import Path
import hashlib
import hmac
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'sdk/python'))
from wristbeam import WristBeamClient, verify_webhook


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='wristbeam-api-test-') as temporary:
    stage = Path(temporary)
    runner = stage / 'Runner.swift'
    runner.write_text(r'''
import Foundation
import Security
// Production secret store is compiled but never called by this fixture.
enum PulseRuntime { static let isPreview = true }
@main struct Runner {
 @MainActor static func main() async throws {
  let args = CommandLine.arguments
  if args[1] == "webhook" {
   let delegate = WebhookNoRedirect()
   let session = URLSession(configuration:.ephemeral,delegate:delegate,delegateQueue:nil)
   let success = await DeveloperWebhook.deliver(url:URL(string:args[2])!,body:Data("{\"synthetic\":true}".utf8),secret:"fixture-webhook",session:session)
   print(success ? "delivered" : "rejected"); return
  }
  let port = UInt16(args[1])!
  let requireAPIKey = ProcessInfo.processInfo.environment["WRISTBEAM_TEST_KEYLESS"] != "1"
  let secure = args.count > 2
  let identity = secure ? try DeveloperServer.identity(data:Data(contentsOf:URL(fileURLWithPath:args[2])),password:"fixture-only") : nil
  let server = DeveloperServer()
  server.handle = { request, finish in Task { @MainActor in
   finish(DeveloperProtocol.route(request,token:"fixture-only",allowedHosts:["127.0.0.1:\(port)"],origin:"\(secure ? "https" : "http")://127.0.0.1:\(port)",requireAPIKey:requireAPIKey) { name,arguments in ["schemaVersion":1,"synthetic":true,"query":name,"arguments":arguments] })
  } }
  try server.start(host:"127.0.0.1",port:port,identity:identity)
  while true { try await Task.sleep(nanoseconds:1_000_000_000) }
 }
}
''')
    binary = stage / 'api-server'
    subprocess.run(['swiftc', '-swift-version', '5', '-o', str(binary),
                    str(root / 'Sources/GarminBar/Developer/DeveloperProtocol.swift'),
                    str(root / 'Sources/GarminBar/Developer/DeveloperServer.swift'), str(runner)], check=True)
    config = stage / 'certificate.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n')
    cert, key, identity = stage / 'ca.pem', stage / 'key.pem', stage / 'identity.p12'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(config), '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    subprocess.run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert), '-out', str(identity), '-passout', 'pass:fixture-only', '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'], check=True, capture_output=True)
    checks = 0
    for secure in (False, True):
        listen = port()
        base = ('https' if secure else 'http') + '://127.0.0.1:' + str(listen)
        with (stage / 'server.log').open('w') as log:
            process = subprocess.Popen([str(binary), str(listen)] + ([str(identity)] if secure else []), stdout=log, stderr=log, env=dict(os.environ, WRISTBEAM_TEST_KEYLESS="0"))
            try:
                client = WristBeamClient(base, 'fixture-only', ca_file=str(cert) if secure else None)
                for _ in range(60):
                    try:
                        assert client.status()['synthetic'] is True
                        break
                    except Exception:
                        if process.poll() is not None:
                            raise RuntimeError('Native test server exited')
                        time.sleep(.1)
                else:
                    raise RuntimeError('Native test server did not become ready')
                checks += 1
                assert client.initialize()['result']['protocolVersion'] == '2025-06-18'; checks += 1
                assert client.rpc({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) is None; checks += 1
                tools = client.rpc({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})['result']['tools']
                assert len(tools) == 9 and all(t['annotations']['readOnlyHint'] for t in tools); checks += 1
                result = client.rpc({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'wristbeam_metrics', 'arguments': {}}})['result']
                assert result['structuredContent']['synthetic'] and not result['isError']; checks += 1
                assert client.activities(start_date='2026-01-01', activity_type='running')['query'] == 'activities'; checks += 1
                assert client.activity('1001')['query'] == 'activity'; checks += 1
                assert client.activity_series('1001', 'directHeartRate')['query'] == 'activity_series'; checks += 1
                summary = client.summary('2026-01-01', '2026-01-02', metrics=['heartRate', 'stress'])
                assert summary['query'] == 'summary' and summary['arguments'] == {'startDate': '2026-01-01', 'endDate': '2026-01-02', 'metrics': 'heartRate,stress'}; checks += 1
                summary_rpc = client.rpc({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'wristbeam_summary', 'arguments': {'startDate': '2026-01-01', 'endDate': '2026-01-02', 'metrics': ['heartRate']}}})['result']['structuredContent']
                assert summary_rpc['query'] == 'summary' and summary_rpc['arguments']['metrics'] == ['heartRate']; checks += 1
                context = ssl.create_default_context(cafile=str(cert)) if secure else None
                for headers, code in [({}, 401), ({'Authorization': 'Bearer fixture-only', 'Origin': 'https://evil.example'}, 403), ({'Authorization': 'Bearer fixture-only', 'Host': 'evil.example'}, 403)]:
                    try:
                        urlopen(Request(base + '/api/v1/status', headers=headers), context=context, timeout=3)
                        raise AssertionError('Expected rejection')
                    except HTTPError as error:
                        assert error.code == code
                    checks += 1
                env = dict(os.environ, PYTHONPATH=str(root / 'sdk/python'), WRISTBEAM_URL=base, WRISTBEAM_API_KEY='fixture-only')
                if secure:
                    env['WRISTBEAM_CA_FILE'] = str(cert)
                bridge = subprocess.run([sys.executable, '-m', 'wristbeam'], input=json.dumps({'jsonrpc':'2.0','id':9,'method':'tools/list'})+'\n', text=True, capture_output=True, env=env, check=True)
                assert len(json.loads(bridge.stdout)['result']['tools']) == 9; checks += 1
                print('PASS native', 'HTTPS (trusted certificate)' if secure else 'HTTP', 'REST / MCP / auth / Origin / Host / stdio bridge')
            finally:
                process.terminate()
                process.wait(timeout=5)
    for secure in (False, True):
        listen = port()
        base = ('https' if secure else 'http') + '://127.0.0.1:' + str(listen)
        context = ssl.create_default_context(cafile=str(cert)) if secure else None
        with (stage / 'keyless-server.log').open('w') as log:
            process = subprocess.Popen([str(binary), str(listen)] + ([str(identity)] if secure else []),
                                       stdout=log, stderr=log, env=dict(os.environ, WRISTBEAM_TEST_KEYLESS='1'))
            try:
                for _ in range(60):
                    try:
                        with urlopen(base + '/api/v1/status', context=context, timeout=3) as response:
                            assert json.load(response)['synthetic'] is True
                        break
                    except Exception:
                        if process.poll() is not None:
                            raise RuntimeError('Native keyless server exited')
                        time.sleep(.1)
                else:
                    raise RuntimeError('Native keyless server did not become ready')
                checks += 1
                messages = [
                    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
                    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
                    {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'wristbeam_metrics', 'arguments': {}}},
                ]
                for message in messages:
                    request = Request(base + '/mcp', data=json.dumps(message).encode(),
                                      headers={'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'})
                    with urlopen(request, context=context, timeout=3) as response:
                        result = json.load(response)['result']
                        assert result.get('isError') is not True
                        if message['method'] == 'initialize':
                            assert result['protocolVersion'] == '2025-06-18'
                        elif message['method'] == 'tools/list':
                            assert len(result['tools']) == 9
                        else:
                            assert result['structuredContent']['synthetic'] is True
                    checks += 1
                for headers, code in [({'Origin': 'https://evil.example'}, 403), ({'Host': 'evil.example'}, 403),
                                      ({'Authorization': 'Bearer invalid-fixture'}, 401), ({'Authorization': ''}, 401)]:
                    try:
                        urlopen(Request(base + '/api/v1/status', headers=headers), context=context, timeout=3)
                        raise AssertionError('Expected keyless-mode rejection')
                    except HTTPError as error:
                        assert error.code == code
                    checks += 1
                assert WristBeamClient(base, 'fixture-only', ca_file=str(cert) if secure else None).status()['synthetic']; checks += 1
                print('PASS native keyless', 'HTTPS' if secure else 'HTTP', 'REST / MCP / Host / Origin / invalid credentials')
            finally:
                process.terminate()
                process.wait(timeout=5)
    events = []
    class Receiver(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_POST(self):
            body = self.rfile.read(int(self.headers['Content-Length']))
            assert verify_webhook('fixture-webhook', self.headers['X-WristBeam-Timestamp'], self.headers['X-WristBeam-Signature'], body)
            events.append((self.path, body))
            code = 302 if self.path == '/redirect' else 503 if len(events) == 1 else 204
            self.send_response(code)
            if code == 302:
                self.send_header('Location', '/trap')
            self.send_header('Content-Length', '0')
            self.end_headers()
    receiver = HTTPServer(('127.0.0.1', 0), Receiver)
    thread = threading.Thread(target=receiver.serve_forever, daemon=True)
    thread.start()
    try:
        base = 'http://127.0.0.1:' + str(receiver.server_port)
        delivery = subprocess.run([str(binary), 'webhook', base + '/hook'], capture_output=True, text=True, check=True)
        assert delivery.stdout.strip() == 'delivered' and len(events) == 2 and events[0][1] == events[1][1]; checks += 1
        rejected = subprocess.run([str(binary), 'webhook', base + '/redirect'], capture_output=True, text=True, check=True)
        assert rejected.stdout.strip() == 'rejected' and len(events) == 3 and not any(p == '/trap' for p, _ in events); checks += 1
        print('PASS real webhook delivery, signature, retry and redirect refusal')
    finally:
        receiver.shutdown()
        receiver.server_close()
    body = b'{"synthetic":true}'
    stamp, secret = str(int(time.time())), 'fixture-webhook'
    signature = 'sha256=' + hmac.new(secret.encode(), stamp.encode()+b'.'+body, hashlib.sha256).hexdigest()
    assert verify_webhook(secret, stamp, signature, body); checks += 1
    assert not verify_webhook(secret, stamp, signature, body+b' '); checks += 1
    assert not verify_webhook(secret, stamp, signature, body, now=int(stamp)+301); checks += 1
    assert not verify_webhook('wrong', stamp, signature, body); checks += 1
    try:
        WristBeamClient('http://remote.example', 'fixture')
        raise AssertionError('Remote HTTP must be rejected')
    except ValueError:
        checks += 1
    print('PASS:', checks, 'developer integration checks; synthetic loopback data only')
