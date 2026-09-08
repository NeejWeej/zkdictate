#!/usr/bin/env python3
"""Build a native recorder app. No permission requests or microphone access."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--identity', default='-', help='Code-signing identity; default is local ad-hoc signing')
parser.add_argument('--output', type=Path, default=root / 'build/ZK Dictate.app')
args = parser.parse_args()
app = args.output.resolve()
if app.exists():
    shutil.rmtree(app)
for folder in ['MacOS', 'Resources']:
    (app / 'Contents' / folder).mkdir(parents=True, exist_ok=True)
plist = {
    'CFBundleIdentifier': 'com.zkdictate.recorder',
    'CFBundleName': 'ZK Dictate',
    'CFBundleDisplayName': 'ZK Dictate',
    'CFBundleExecutable': 'ZK Dictate',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0',
    'NSMicrophoneUsageDescription': 'ZK Dictate records your voice while you hold the dictation hotkey. Audio is transcribed locally on your Mac.',
    'NSHighResolutionCapable': True,
    'ZKPythonExecutable': str(root / '.venv/bin/python3'),
}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
entitlements = root / 'native/entitlements.plist'
common = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(root / 'build/swift-cache')]
native = root / 'native'
subprocess.run(common + [str(native / n) for n in ['Core.swift', 'Runtime.swift', 'Recorder.swift', 'AppSettings.swift', 'Clipboard.swift', 'ClipboardPanel.swift', 'WorkerProcess.swift', 'App.swift']] + ['-framework', 'AppKit', '-framework', 'AVFoundation', '-o', str(app / 'Contents/MacOS/ZK Dictate')], check=True)
shutil.copy2(root / 'src/zkdictate/app_worker.py', app / 'Contents/Resources/app_worker.py')
shutil.copy2(root / 'LICENSE', app / 'Contents/Resources/LICENSE')
subprocess.run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--entitlements', str(entitlements), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
