#!/usr/bin/env python3
"""Local JSON-RPC fixture: never reads credentials or contacts a service."""
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[0])
mode = path.stem
counter = path.with_suffix('.count')
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
if mode == 'crash' or (mode == 'recover-crash' and attempt == 1):
    sys.exit(7)
if mode == 'timeout':
    time.sleep(10)
    sys.exit(0)
for line in sys.stdin:
    request = json.loads(line)
    if request.get('id') == 1:
        response = {'id': 1, 'result': {}}
    elif request.get('id') == 2:
        message = None
        if mode == 'auth': message = 'not logged in: HTTP 401'
        if mode == 'busy': message = 'HTTP 429'
        if mode == 'recover' and attempt == 1: message = 'error sending request'
        if message:
            response = {'id': 2, 'error': {'code': -32000, 'message': message}}
        elif mode == 'invalid':
            response = {'id': 2, 'result': {'rateLimits': 'invalid'}}
        else:
            response = {'id': 2, 'result': {'rateLimits': {'primary': {'usedPercent': 33, 'windowDurationMins': 300}}}}
    else:
        continue
    data = json.dumps(response)
    # A notification and split JSON lines must not break response parsing.
    print(json.dumps({'method': 'account/rateLimits/updated', 'params': {}}), flush=True)
    sys.stdout.write(data[:5]); sys.stdout.flush()
    time.sleep(.01)
    print(data[5:], flush=True)
