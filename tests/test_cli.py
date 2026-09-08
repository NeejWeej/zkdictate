from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
from zkdictate import cli

class CLITests(unittest.TestCase):
    def test_command_opens_only_the_mac_app(self):
        app=Path('/tmp/ZK Dictate.app')
        for entry in (cli.main,):
            with patch.object(cli.sys,'platform','darwin'),patch.object(cli.platform,'machine',return_value='arm64'),patch.object(cli,'app_path',return_value=app),patch.object(cli.subprocess,'run') as run:
                self.assertEqual(entry([]),0)
                run.assert_called_once_with(['/usr/bin/open',str(app)],check=True)

    def test_doctor_verifies_without_launching(self):
        app=Path('/tmp/ZK Dictate.app')
        result=subprocess.CompletedProcess([],0,stdout='',stderr='')
        with patch.object(cli.sys,'platform','darwin'),patch.object(cli.platform,'machine',return_value='arm64'),patch.object(cli,'app_path',return_value=app),patch.object(cli.subprocess,'run',return_value=result) as run,patch('builtins.print'):
            self.assertEqual(cli.main(['--doctor']),0)
            self.assertEqual(run.call_args.args[0],['codesign','--verify','--deep','--strict',str(app)])

    def test_missing_install_has_actionable_error(self):
        with patch.object(cli.Path,'is_file',return_value=False):
            with self.assertRaisesRegex(FileNotFoundError,'install.sh'): cli.app_path()
