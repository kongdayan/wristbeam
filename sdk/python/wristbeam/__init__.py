"""Dependency-free WristBeam v1 REST/MCP client. Health data is never logged."""
import hashlib
import hmac
import json
import ssl
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPSHandler, HTTPRedirectHandler

__all__ = ['WristBeamClient', 'verify_webhook']


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class WristBeamClient:
    def __init__(self, base_url, api_key, *, ca_file=None, timeout=10):
        parsed = urlsplit(base_url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
            raise ValueError('Use an HTTP(S) base URL without credentials, path or query')
        if parsed.scheme == 'http' and parsed.hostname not in ('127.0.0.1', 'localhost', '::1'):
            raise ValueError('Remote connections require HTTPS')
        if not api_key or '\r' in api_key or '\n' in api_key:
            raise ValueError('A valid API key is required')
        self.base_url, self._key, self.timeout = base_url.rstrip('/'), api_key, timeout
        self._opener = build_opener(_NoRedirect(), HTTPSHandler(context=ssl.create_default_context(cafile=ca_file)))

    def _request(self, path, message=None):
        headers = {'Authorization': 'Bearer ' + self._key, 'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18'}
        payload = None
        if message is not None:
            payload = json.dumps(message, separators=(',', ':')).encode()
            headers['Content-Type'] = 'application/json'
        request = Request(self.base_url + path, data=payload, headers=headers)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise ValueError('Response exceeds size budget')
                return json.loads(raw) if raw else None
        except HTTPError as error:
            raise RuntimeError('WristBeam returned HTTP ' + str(error.code)) from None

    def status(self):
        return self._request('/api/v1/status')

    def metrics(self):
        return self._request('/api/v1/metrics')

    def catalog(self):
        return self._request('/api/v1/catalog')

    def series(self, metric, date, *, offset=0, limit=1440):
        return self._request('/api/v1/series?' + urlencode(dict(metric=metric, date=date, offset=offset, limit=limit)))

    def hrv(self, date=None):
        return self._request('/api/v1/hrv' + ('?' + urlencode(dict(date=date)) if date else ''))

    def rpc(self, message):
        return self._request('/mcp', message)

    def initialize(self):
        return self.rpc({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'wristbeam-python', 'version': '1.0.0'}}})


def verify_webhook(secret, timestamp, signature, body, *, now=None, tolerance=300):
    """Verify untouched HTTP body before JSON parsing. Persist event IDs to reject replays."""
    try:
        if not secret or tolerance < 0 or len(body) > 4 * 1024 * 1024 or abs((time.time() if now is None else now) - int(timestamp)) > tolerance:
            return False
        expected = 'sha256=' + hmac.new(secret.encode(), timestamp.encode() + b'.' + body, hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, signature)
    except (TypeError, ValueError, AttributeError):
        return False
