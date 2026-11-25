#!/usr/bin/env python3
"""Host the local Comet fixture outside the sandboxed macOS UI runner."""
import json
import os
import tempfile
import urllib.request
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
server = subprocess.Popen([sys.executable, str(root / 'scripts/mock-comet.py')],
                          stdout=subprocess.PIPE, text=True)
credentials_path = None
try:
    port = server.stdout.readline().strip()
    if not port.isdigit():
        raise RuntimeError('The local Comet fixture did not start')
    request = urllib.request.Request(f'http://127.0.0.1:{port}/api/auth/login',
        data=b'user=admin&passwd=test-password', headers={'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(request) as response:
        token = json.load(response)['result']['token']
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', prefix='asteroid-paste-ui-', delete=False) as file:
        credentials_path = file.name
        json.dump({'host': f'http://127.0.0.1:{port}', 'username': 'admin', 'token': token}, file)
    environment = dict(os.environ, TEST_RUNNER_ASTEROID_PASTE_FIXTURE_PORT=port,
                       TEST_RUNNER_ASTEROID_PASTE_SESSION_FILE=credentials_path)
    result = subprocess.run([
        'xcodebuild', '-project', 'AsteroidKVM.xcodeproj', '-scheme', 'AsteroidKVM',
        '-destination', 'platform=macOS', '-derivedDataPath', 'build/DerivedData',
        '-clonedSourcePackagesDirPath', '.build/xcode-packages',
        '-only-testing:AsteroidKVMUITests/CometUITests/testPastePreviewCancelLayoutOptionsAndReturnSubmission',
        'test'], cwd=root, env=environment)
    sys.exit(result.returncode)
finally:
    if credentials_path:
        Path(credentials_path).unlink(missing_ok=True)
    server.terminate()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
