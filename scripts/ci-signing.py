#!/usr/bin/env python3
"""Keep release credentials temporary on the persistent personal CI runner."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def security(*args):
    return subprocess.check_output(['security', *args], text=True).strip()


def prepare(root, environment):
    state = root / 'transcripts-signing-state.json'
    if state.exists():
        raise RuntimeError('Signing state already exists; clean up the previous job first')
    keychains = shlex.split(security('list-keychains', '-d', 'user'))
    state.write_text(json.dumps(keychains))
    state.chmod(0o600)
    keys = root / 'transcripts-api-keys'
    keys.mkdir(mode=0o700)
    key_id = os.environ.get('ASC_KEY_ID', '')
    if key_id and not key_id.isalnum():
        raise ValueError('Invalid App Store Connect key ID')
    with environment.open('a') as env:
        env.write(f'API_PRIVATE_KEYS_DIR={keys}\n')
        env.write(f'ASC_KEY_PATH={keys / ("AuthKey_" + key_id + ".p8")}\n')


def cleanup(root):
    state = root / 'transcripts-signing-state.json'
    if not state.exists():
        return  # Preparation did not run; do not change the user's keychains.
    keychains = json.loads(state.read_text())
    security('list-keychains', '-d', 'user', '-s', *keychains)
    for name in ('build.keychain-db', 'release.keychain-db'):
        keychain = root / name
        if keychain.exists():
            security('delete-keychain', str(keychain))
    keys = root / 'transcripts-api-keys'
    if keys.exists():
        for key in keys.glob('AuthKey_*.p8'):
            key.unlink()
        keys.rmdir()
    for name in ('dist.p12', 'dev.p12', 'cert.p12', 'devid.p12', 'AuthKey.p8'):
        (root / name).unlink(missing_ok=True)
    state.unlink()


if __name__ == '__main__':
    root = Path(os.environ['RUNNER_TEMP']).resolve()
    if sys.argv[1:] == ['prepare']:
        prepare(root, Path(os.environ['GITHUB_ENV']))
    elif sys.argv[1:] == ['cleanup']:
        cleanup(root)
    else:
        raise SystemExit('Usage: ci-signing.py prepare|cleanup')
