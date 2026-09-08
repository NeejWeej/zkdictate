import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ReleaseTests(unittest.TestCase):
    def test_launchers_resolve_checkout_with_spaces_from_another_directory(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            checkout = temp / 'checkout with spaces'
            checkout.mkdir()
            binary_dir = temp / 'bin'
            binary_dir.mkdir()
            fake_uv = binary_dir / 'uv'
            fake_uv.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            fake_uv.chmod(0o755)
            env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ['PATH'])
            for name in ['zkdictate']:
                shutil.copy2(root / name, checkout / name)
                result = subprocess.run([str(checkout / name), '--help'], cwd=temp,
                                        env=env, capture_output=True, text=True, check=True)
                args = json.loads(result.stdout)
                self.assertEqual(args[:2], ['run', '--project'])
                self.assertEqual(Path(args[2]).resolve(), checkout.resolve())
                self.assertEqual(args[3], '--frozen')
                self.assertEqual(args[-2:], [name, '--help'])
                self.assertNotIn('--extra', args)


if __name__ == '__main__':
    unittest.main()
