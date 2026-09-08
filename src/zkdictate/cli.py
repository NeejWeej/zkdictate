"""Open the native Mac app or check its installation."""
from pathlib import Path
import argparse
import platform
import subprocess
import sys


def app_path():
    for path in (Path.home() / 'Applications/ZK Dictate.app', Path('/Applications/ZK Dictate.app')):
        if (path / 'Contents/MacOS/ZK Dictate').is_file():
            return path
    raise FileNotFoundError('ZK Dictate is not installed. Run ./install.sh from the checkout.')


def main(argv=None):
    parser = argparse.ArgumentParser(description='Open the ZK Dictate Mac app.')
    parser.add_argument('--doctor', action='store_true', help='Check installation without opening the app')
    args = parser.parse_args(argv)
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.exit(1, 'ZK Dictate requires an Apple Silicon Mac.\n')
    try: path = app_path()
    except FileNotFoundError as exc: parser.exit(1, str(exc) + '\n')
    if args.doctor:
        result = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], capture_output=True, text=True)
        print(f'App: {path}')
        print('Signature: valid' if result.returncode == 0 else result.stderr.strip())
        return result.returncode
    subprocess.run(['/usr/bin/open', str(path)], check=True)
    return 0
