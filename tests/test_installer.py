import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('install_app', ROOT / 'scripts/install_app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_running_app_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            target = directory / 'ZK Dictate.app'
            target.mkdir()
            executable = str(target / 'Contents/MacOS/ZK Dictate')
            with patch.object(installer.subprocess, 'run'), patch.object(installer.subprocess, 'check_output', return_value=executable + '\n'):
                with self.assertRaisesRegex(RuntimeError, 'Quit ZK Dictate'):
                    installer.install_app(Path('/source/ZK Dictate.app'), directory)
            self.assertTrue(target.is_dir())

    def test_failed_staged_validation_preserves_existing_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source/ZK Dictate.app'
            target = root / 'apps/ZK Dictate.app'
            source.mkdir(parents=True); target.mkdir(parents=True)
            (target / 'previous').write_text('keep')
            with patch.object(installer.subprocess, 'run', side_effect=[None, subprocess.CalledProcessError(1, 'codesign')]), patch.object(installer.subprocess, 'check_output', return_value=''):
                with self.assertRaises(subprocess.CalledProcessError):
                    installer.install_app(source, target.parent)
            self.assertEqual((target / 'previous').read_text(), 'keep')
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_successful_install_keeps_previous_build_as_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'source/ZK Dictate.app'; target = root / 'apps/ZK Dictate.app'
            source.mkdir(parents=True); target.mkdir(parents=True)
            (source / 'new').write_text('new'); (target / 'previous').write_text('keep')
            with patch.object(installer.subprocess, 'run'), patch.object(installer.subprocess, 'check_output', return_value=''):
                self.assertEqual(installer.install_app(source, target.parent), target)
            self.assertTrue((target / 'new').exists())
            backup = list(target.parent.glob('*.backup'))
            self.assertEqual(len(backup), 1)
            self.assertEqual((backup[0] / 'previous').read_text(), 'keep')

    def test_setup_uses_available_tools_and_clears_foreign_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); binary = root / 'bin'; binary.mkdir()
            home = root / 'home'; home.mkdir()
            shutil.copy2(ROOT / 'install.sh', root / 'install.sh')
            scripts = {
                'uname': '#!/bin/bash\nif [[ "$1" == -s ]]; then echo Darwin; else echo arm64; fi\n',
                'sw_vers': '#!/bin/bash\necho 14.0\n',
                'xcrun': '#!/bin/bash\nexit 0\n',
                'uv': '#!/bin/bash\n[[ -z "${VIRTUAL_ENV:-}" ]] || exit 9\necho "$*" >> "$TEST_LOG"\n',
            }
            for name, text in scripts.items():
                path = binary / name; path.write_text(text); path.chmod(0o755)
            (binary / 'dirname').symlink_to('/usr/bin/dirname')
            log = root / 'calls'
            env = dict(os.environ, PATH=str(binary), HOME=str(home), TEST_LOG=str(log), VIRTUAL_ENV='/wrong/project')
            result = subprocess.run(['/bin/bash', str(root / 'install.sh'), '--no-open'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(log.read_text().splitlines(), ['sync --locked --python 3.12', 'run --frozen python scripts/build_app.py', 'run --frozen python scripts/install_app.py --no-open'])

    def test_setup_installs_missing_uv_without_modifying_shell_profiles(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); binary = root / 'bin'; binary.mkdir()
            home = root / 'home'; home.mkdir()
            shutil.copy2(ROOT / 'install.sh', root / 'install.sh')
            scripts = {
                'uname': '#!/bin/bash\nif [[ "$1" == -s ]]; then echo Darwin; else echo arm64; fi\n',
                'sw_vers': '#!/bin/bash\necho 14.0\n',
                'xcrun': '#!/bin/bash\nexit 0\n',
                'curl': '''#!/bin/bash
cat > "${@: -1}" <<'INSTALL'
#!/bin/sh
[ "$UV_NO_MODIFY_PATH" = 1 ] || exit 8
mkdir -p "$UV_INSTALL_DIR"
cat > "$UV_INSTALL_DIR/uv" <<'UV'
#!/bin/bash
echo "$*" >> "$TEST_LOG"
UV
chmod +x "$UV_INSTALL_DIR/uv"
INSTALL
''',
            }
            for name, text in scripts.items():
                path = binary / name; path.write_text(text); path.chmod(0o755)
            for name, target in {'dirname':'/usr/bin/dirname','mktemp':'/usr/bin/mktemp','rm':'/bin/rm','sh':'/bin/sh','cat':'/bin/cat','mkdir':'/bin/mkdir','chmod':'/bin/chmod'}.items():
                (binary / name).symlink_to(target)
            log = root / 'calls'
            env = dict(os.environ, PATH=str(binary), HOME=str(home), TEST_LOG=str(log))
            result = subprocess.run(['/bin/bash', str(root / 'install.sh'), '--no-open'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((home / '.local/bin/uv').is_file())
            self.assertEqual(len(log.read_text().splitlines()), 3)
            self.assertFalse((home / '.zshrc').exists())

    def test_missing_apple_tools_stops_before_installing_dependencies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); binary = root / 'bin'; binary.mkdir()
            shutil.copy2(ROOT / 'install.sh', root / 'install.sh')
            scripts = {
                'uname': '#!/bin/bash\nif [[ "$1" == -s ]]; then echo Darwin; else echo arm64; fi\n',
                'sw_vers': '#!/bin/bash\necho 14.0\n',
                'xcrun': '#!/bin/bash\nexit 1\n',
                'xcode-select': '#!/bin/bash\necho "$*" > "$TEST_LOG"\n',
            }
            for name, text in scripts.items():
                path = binary / name; path.write_text(text); path.chmod(0o755)
            (binary / 'dirname').symlink_to('/usr/bin/dirname')
            log = root / 'calls'
            env = dict(os.environ, PATH=str(binary), HOME=str(root / 'home'), TEST_LOG=str(log))
            result = subprocess.run(['/bin/bash', str(root / 'install.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(log.read_text().strip(), '--install')
            self.assertIn('Install.command again', result.stdout)
