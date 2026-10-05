"""Exercise installer behavior without modifying the real account or using the network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install-composer.sh"
PYTHON = shutil.which("python3")

PHP_MOCK = r'''
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
if args[0] == '-r':
    code = args[1]
    if 'PHP_VERSION_ID' in code:
        if os.environ.get('BAD_PHP'): sys.exit(1)
        print('80300', end='')
    elif 'PHP_MAJOR_VERSION' in code: print('8.3', end='')
    elif 'echo PHP_VERSION' in code: print('8.3.0', end='')
    elif '$missing' in code:
        if os.environ.get('MISSING_EXT'): sys.exit(1)
    elif 'hash_file' in code:
        expected = pathlib.Path(args[2]).read_text().strip()
        actual = hashlib.sha384(pathlib.Path(args[3]).read_bytes()).hexdigest()
        if expected != actual: sys.exit(1)
    else: sys.exit('Unexpected PHP snippet')
elif pathlib.Path(args[0]).name == 'composer-setup.php':
    if os.environ.get('INSTALL_FAIL'): sys.exit(1)
    directory = next(a.split('=', 1)[1] for a in args if a.startswith('--install-dir='))
    pathlib.Path(directory, 'composer.phar').write_text('mock composer')
else:
    if pathlib.Path(args[0]).read_text() != 'mock composer': sys.exit(1)
    if args[1:] == ['--version']: print('Composer version 2.mock')
    else: print(json.dumps(args[1:]))
'''

CURL_MOCK = r'''
import hashlib, os, pathlib, sys
args = sys.argv[1:]
output = pathlib.Path(args[args.index('--output') + 1])
with open(os.environ['DOWNLOAD_LOG'], 'a') as log: log.write('download\n')
payload = b'mock official installer'
if 'https://composer.github.io/installer.sig' in args:
    output.write_text('0' * 96 if os.environ.get('BAD_HASH') else hashlib.sha384(payload).hexdigest())
else: output.write_bytes(payload)
'''


@unittest.skipIf(os.geteuid() == 0, "Installer intentionally rejects root")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="composer test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.php = self.tools / "php"
        for name, code in [("php", PHP_MOCK), ("curl", CURL_MOCK)]:
            path = self.tools / name
            path.write_text(f"#!{PYTHON}\n" + code)
            path.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.tools}:/usr/bin:/bin",
                        DOWNLOAD_LOG=str(self.root / "downloads"))
        self.phar = self.home / ".local/share/cpanel-composer/composer.phar"
        self.wrapper = self.home / "bin/composer"

    def run_install(self, *args, **env):
        return subprocess.run(["bash", str(SCRIPT), "--php", str(self.php), *args],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_install_repeat_and_literal_argument_forwarding(self):
        self.assert_success(self.run_install())
        original_profile = (self.home / ".profile").read_text()
        self.assert_success(self.run_install())
        self.assertEqual((self.home / ".profile").read_text(), original_profile)
        self.assertEqual((self.root / "downloads").read_text().count("download"), 2)
        arguments = ["require", "name with spaces", "$(touch should-not-exist)", "--flag"]
        result = subprocess.run([str(self.wrapper), *arguments], env=self.env,
                                text=True, capture_output=True)
        import json
        self.assertEqual(json.loads(result.stdout), arguments)
        self.assertFalse((self.home / ".local/share/cpanel-composer/.install-lock").exists())

    def test_bad_checksum_installs_nothing(self):
        self.assertNotEqual(self.run_install(BAD_HASH="1").returncode, 0)
        self.assertFalse(self.phar.exists())
        self.assertFalse(self.wrapper.exists())

    def test_failed_force_preserves_existing_installation(self):
        self.assert_success(self.run_install())
        before = self.wrapper.read_bytes()
        self.assertNotEqual(self.run_install("--force", INSTALL_FAIL="1").returncode, 0)
        self.assertEqual(self.phar.read_text(), "mock composer")
        self.assertEqual(self.wrapper.read_bytes(), before)

    def test_unrelated_command_is_not_overwritten(self):
        self.wrapper.parent.mkdir()
        self.wrapper.write_text("existing command")
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual(self.wrapper.read_text(), "existing command")
        self.assertFalse((self.root / "downloads").exists())

    def test_no_path_and_custom_directories(self):
        destination = self.home / "custom tools"
        result = self.run_install("--no-path", "--install-dir", str(destination / "data"),
                                  "--bin-dir", str(destination / "bin"))
        self.assert_success(result)
        self.assertTrue((destination / "bin/composer").exists())
        self.assertFalse((self.home / ".bashrc").exists())
        self.assertFalse((self.home / ".profile").exists())

    def test_bad_php_and_missing_extension_stop_before_download(self):
        for env in [{"BAD_PHP": "1"}, {"MISSING_EXT": "1"}]:
            self.assertNotEqual(self.run_install(**env).returncode, 0)
            self.assertFalse((self.root / "downloads").exists())

    def test_bash_login_profile_is_used(self):
        (self.home / ".bash_profile").write_text("# Existing profile\n")
        self.assert_success(self.run_install())
        self.assertIn("cpanel-composer-installer", (self.home / ".bash_profile").read_text())
        self.assertFalse((self.home / ".profile").exists())

    def test_invalid_arguments(self):
        for args in [("--unknown",), ("--bin-dir",), ("--php", "9.9"),
                     ("--bin-dir", "relative")]:
            self.assertNotEqual(self.run_install(*args).returncode, 0)


if __name__ == "__main__":
    unittest.main()
