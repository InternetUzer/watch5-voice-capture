#!/usr/bin/env python3
"""Build real WebRTC + Node-API bridge on Linux, then test native and ArkTS policy.

Requires cmake, C/C++ compiler, Node >=22.18 and matching Node C headers.
Usage: python scripts/test-watch-vad.py --node-include /path/to/node/headers
Does not build/sign a HarmonyOS HAP or measure Watch5 power consumption.
"""
import argparse
import base64
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--node-include', help='Defaults to include/node beside the active Node installation')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
node_include = Path(args.node_include).resolve() if args.node_include else Path(shutil.which('node')).resolve().parents[1] / 'include/node'
if not (node_include / 'node_api.h').is_file():
    parser.error('Node C headers not found; pass --node-include /path/to/headers')
vendor = root / 'watch/entry/src/main/cpp/third_party'
for name, expected in json.loads((vendor / 'SHA256SUMS.json').read_text()).items():
    assert hashlib.sha256((vendor / name).read_bytes()).hexdigest() == expected, name
with tempfile.TemporaryDirectory(prefix='watch-vad-test-') as tmp:
    build = Path(tmp)
    subprocess.run(['cmake', '-S', str(root / 'watch/entry/src/main/cpp'), '-B', tmp,
                    '-DWATCH_VAD_HOST_TEST=ON', '-DCMAKE_BUILD_TYPE=Release',
                    f'-DNODE_INCLUDE_DIR={node_include}'], check=True)
    subprocess.run(['cmake', '--build', tmp, '--parallel', '2'], check=True)
    fixture = build / 'test-audio.raw'
    fixture.write_bytes(base64.b64decode((root / 'watch/tests/fixtures/webrtc-test-audio.raw.base64').read_bytes()))
    subprocess.run([str(build / 'vad_regression'), str(fixture)], check=True)
    env = dict(os.environ, WATCH_VAD_ADDON=str(build / 'watchvad.node'))
    tests = sorted(str(p) for p in (root / 'watch/tests').glob('*.test.mjs'))
    subprocess.run(['node', '--test', *tests], cwd=root, env=env, check=True)
