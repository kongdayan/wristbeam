"""Optional stdio-to-HTTP bridge: python3 -m wristbeam. Credentials only via env."""
import json
import os
import sys
from . import WristBeamClient


def main():
    try:
        client = WristBeamClient(os.environ.get('WRISTBEAM_URL', 'http://127.0.0.1:17890'), os.environ['WRISTBEAM_API_KEY'], ca_file=os.environ.get('WRISTBEAM_CA_FILE'))
    except (KeyError, ValueError):
        print('Set WRISTBEAM_API_KEY and a valid WRISTBEAM_URL.', file=sys.stderr)
        return 1
    while True:
        line = sys.stdin.buffer.readline(49153)
        if not line:
            return 0
        if len(line) > 49152:
            print('MCP request exceeds 48 KiB.', file=sys.stderr)
            return 1
        message = None
        try:
            message = json.loads(line)
            response = client.rpc(message)
            if response is not None:
                print(json.dumps(response, separators=(',', ':')), flush=True)
        except Exception:
            if isinstance(message, dict) and 'id' in message:
                print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32603, 'message': 'WristBeam request failed; check app, URL and key.'}}), flush=True)
            else:
                print('Invalid notification or unavailable WristBeam server.', file=sys.stderr)


if __name__ == '__main__':
    raise SystemExit(main())
