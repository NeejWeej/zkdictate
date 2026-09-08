#!/usr/bin/env python3
"""Install a verified app, preserving the previous installation on failure."""
from pathlib import Path
import argparse
from datetime import datetime
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def install_app(source: Path, app_dir: Path) -> Path:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    target = app_dir / source.name
    executable = str(target / 'Contents/MacOS/ZK Dictate')
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if executable in (line.strip() for line in processes):
        raise RuntimeError('Quit ZK Dictate, then run the installer again.')
    app_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup = target.with_name(f'ZK Dictate.{stamp}.backup')
    with tempfile.TemporaryDirectory(prefix='.zkdictate-install-', dir=app_dir) as temporary:
        staged = Path(temporary) / source.name
        shutil.copytree(source, staged, symlinks=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        had_previous = target.exists()
        if had_previous:
            target.rename(backup)
        try:
            staged.rename(target)
        except OSError:
            if had_previous:
                backup.rename(target)
            raise
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-open', action='store_true')
    parser.add_argument('--app-dir', type=Path, default=Path.home() / 'Applications')
    parser.add_argument('--bin-dir', type=Path, default=Path.home() / '.local/bin')
    args = parser.parse_args()
    try:
        target = install_app(ROOT / 'build/ZK Dictate.app', args.app_dir)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        parser.exit(1, f'Installation stopped: {exc}\n')
    args.bin_dir.mkdir(parents=True, exist_ok=True)
    shortcut = args.bin_dir / 'zkdictate'
    if not (shortcut.is_symlink() and shortcut.resolve() == ROOT / 'zkdictate'):
        if shortcut.exists() or shortcut.is_symlink():
            stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            shortcut.rename(shortcut.with_name(f'zkdictate.{stamp}.backup'))
        shortcut.symlink_to(ROOT / 'zkdictate')
    print(f'Installed {target}')
    print('Allow Microphone and Input Monitoring, then click Start Dictation.')
    print('Keep this source folder in place; the app uses its Python environment.')
    if not args.no_open:
        subprocess.run(['/usr/bin/open', str(target)], check=True)


if __name__ == '__main__':
    main()
