#!/usr/bin/env python3
"""Exercise the distributed Skill runner without installing or publishing anything."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[1] / '.agents/skills/sing-box-deploy/scripts/run.sh'


class SkillRunnerTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.repo = self.base / 'test checkout'
        self.repo.mkdir()
        self.logs = self.base / 'logs'
        self.logs.mkdir()
        for name in ('.env', '.env.example', 'isp-list.example.tsv'):
            (self.repo / name).touch()
        self.args_file = self.base / 'installer-args'
        (self.repo / 'install.sh').write_text(
            'printf "%s\\n" "$@" > "$ARGS_FILE"\n'
            'echo synthetic-private-stdout\n'
            'echo synthetic-private-stderr >&2\n'
            'exit "$INSTALLER_STATUS"\n'
        )

    def invoke(self, *args, status=0):
        result = subprocess.run(
            ['bash', str(RUNNER), *args], cwd=self.base, capture_output=True, text=True,
            env=dict(os.environ, TMPDIR=str(self.logs), ARGS_FILE=str(self.args_file),
                     INSTALLER_STATUS=str(status)),
        )
        self.assertNotIn('synthetic-private', result.stdout + result.stderr)
        return result

    def test_operation_selects_the_native_installer_flags(self):
        for mode, flags in [('validate', ['--validate-only']), ('install-proxy', ['--skip-pages']),
                            ('publish-pages', ['--pages-only']), ('install-with-pages', [])]:
            with self.subTest(mode=mode):
                result = self.invoke(mode, self.repo.name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.args_file.read_text().splitlines(),
                                 ['--env', str(self.repo / '.env'), *flags])
                self.assertEqual(list(self.logs.iterdir()), [])

    def test_existing_configuration_can_be_addressed_from_another_directory(self):
        private_config = self.base / 'private config.env'
        private_config.touch()
        for arg in [str(private_config), '../private config.env']:
            result = self.invoke('validate', str(self.repo), arg)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(self.args_file.read_text().splitlines()[1]).resolve(), private_config)

    def test_failure_preserves_status_and_private_diagnostics(self):
        result = self.invoke('validate', str(self.repo), status=23)
        self.assertEqual(result.returncode, 23)
        (log,) = self.logs.iterdir()
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
        self.assertIn(str(log), result.stderr)
        self.assertEqual(log.read_text().splitlines(), ['synthetic-private-stdout', 'synthetic-private-stderr'])

    def test_incomplete_or_unknown_requests_never_call_installer(self):
        for args in [[], ['install-with-pages'], ['unknown', str(self.repo)],
                     ['validate', str(self.base)], ['validate', str(self.repo), 'missing.env'],
                     ['install-proxy', str(self.repo), '.env', 'extra']]:
            with self.subTest(args=args):
                self.assertNotEqual(self.invoke(*args).returncode, 0)
                self.assertFalse(self.args_file.exists())
                self.assertEqual(list(self.logs.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
