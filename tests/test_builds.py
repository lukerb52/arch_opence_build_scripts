"""Dependency-free integration tests; all builds, compilers and installs are fake."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]


class Builds(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='halo tests ', dir=SOURCE)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.scripts = self.root / 'scripts with spaces'
        self.scripts.mkdir()
        for script in SOURCE.glob('*.sh'):
            shutil.copy2(script, self.scripts)
        self.repo = self.root / 'GulchCE'
        (self.repo / 'tools').mkdir(parents=True)
        self.log = self.root / 'calls.jsonl'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items() if k not in (
            'EMCC', 'EMSDK', 'EMSDK_DIR', 'JAVA_HOME', 'JAVA_17_HOME',
            'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_NDK_HOME',
            'ANDROID_NDK_ROOT', 'ANDROID_NDK', 'HALO_BETA',
            'ORG_GRADLE_PROJECT_haloAppIdSuffix', 'VCToolsInstallDir', 'WindowsSdkDir',
            'XWIN_DIR', 'CARGO_HOME', 'XWIN_ACCEPT_LICENSE')}
        self.env.update(PATH=str(self.bin), HOME=str(self.root), PYTHON=str(self.bin / 'python3'),
                        GULCHCE_DIR=str(self.repo), CALLS=str(self.log))
        self.program('python3', 'import os,sys\nos.execv(' + repr(sys.executable) + ', [' + repr(sys.executable) + ', *sys.argv[1:]])\n')
        for name in ('dirname', 'readlink'):
            shutil.copy2(shutil.which(name), self.bin / name)
        for name in ('ninja', 'clang', 'ld.lld', 'lld-link', 'llvm-rc', 'cmake', 'emcc', 'pacman', 'sudo'):
            self.program(name, """import json,os,sys
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'tool': Path(sys.argv[0]).name, 'args': sys.argv[1:], 'java': os.getenv('JAVA_HOME'), 'sdk': os.getenv('ANDROID_HOME'), 'suffix': os.getenv('ORG_GRADLE_PROJECT_haloAppIdSuffix')}) + '\\n')
if 'android_apk' in sys.argv:
    p = Path('port/android/app/build/outputs/apk/debug/app-debug.apk')
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text('mock APK')
""")
        (self.repo / 'configure.py').write_text("import os,sys,json\nwith open(os.environ['CALLS'], 'a') as f: f.write(json.dumps({'tool':'configure', 'args':sys.argv[1:]})+'\\n')\n")

    def program(self, name, body):
        p = self.bin / name
        p.write_text('#!' + sys.executable + '\n' + body)
        p.chmod(0o755)
        return p

    def invoke(self, target, *args, ok=True, cwd=None, entry=None):
        result = subprocess.run(['/bin/sh', str(entry or self.scripts / ('build-' + target + '.sh')), *args],
                                cwd=cwd or self.root, env=self.env, text=True, capture_output=True,
                                start_new_session=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def calls(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def android(self):
        sdk = self.root / 'SDK with spaces'
        (sdk / 'platforms/android-35').mkdir(parents=True)
        (sdk / 'platforms/android-35/android.jar').touch()
        (sdk / 'platform-tools').mkdir()
        (sdk / 'platform-tools/adb').touch()
        tools = sdk / 'build-tools/36.0.0'
        tools.mkdir(parents=True)
        for n in ('aapt2', 'zipalign', 'apksigner'):
            (tools / n).touch()
        for version in ('27.1', '30.2'):
            ndk = sdk / 'ndk' / version
            (ndk / 'build/cmake').mkdir(parents=True)
            (ndk / 'build/cmake/android.toolchain.cmake').touch()
            (ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin').mkdir(parents=True)
            (ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin/clang').touch()
        self.env['ANDROID_SDK_ROOT'] = str(sdk)
        jdk = self.root / 'JDK 17'
        (jdk / 'bin').mkdir(parents=True)
        for n in ('java', 'javac'):
            p = jdk / 'bin' / n
            p.write_text('#!/bin/sh\nprintf \'openjdk version "17.0.14"\\n\' >&2\n')
            p.chmod(0o755)
        self.env['JAVA_HOME'] = str(jdk)
        app = self.repo / 'port/android/app'
        app.mkdir(parents=True)
        (app / 'build.gradle').write_text('android { compileSdk 35 }')
        return sdk

    def windows(self, flat):
        root = self.root / 'Windows tools'
        vc = root / ('crt' if flat else 'VC/Tools/MSVC/14.40')
        sdk = root / ('sdk' if flat else 'Windows Kits/10')
        for d in ('include', 'lib/x86'):
            (vc / d).mkdir(parents=True)
        for d in ('include/um', 'include/ucrt', 'include/shared', 'lib/um/x86', 'lib/ucrt/x86'):
            if not flat:
                a, b = d.split('/', 1)
                d = a.capitalize() + '/10.0.22621.0/' + b
            (sdk / d).mkdir(parents=True)
        self.env['XWIN_DIR'] = str(root)
        return vc, sdk

    def test_web_isolated_pass_through_symlink(self):
        entry = self.root / 'linked web'
        entry.symlink_to(self.scripts / 'build-web.sh')
        self.invoke('web', '--release', '--lto=off', '--compiler-launcher', 'cache with spaces', entry=entry)
        calls = self.calls()
        config = next(c['args'] for c in calls if c['tool'] == 'configure')
        self.assertEqual(config[:4], ['--release', '--lto=off', '--compiler-launcher', 'cache with spaces'])
        self.assertIn('--web-emcc', config)
        self.assertFalse(any('windows' in s or 'android' in s for s in config))
        self.assertFalse(any(c['tool'] in ('sudo', 'pacman') for c in calls))
        self.assertEqual(calls[-1]['args'], ['web'])

    def test_web_missing(self):
        (self.bin / 'emcc').unlink()
        self.assertIn('emcc not found', self.invoke('web', '--check', ok=False))
        self.assertEqual(self.calls(), [])

    def test_web_override_with_spaces(self):
        compiler = self.bin / 'compiler with spaces'
        shutil.copy2(self.bin / 'emcc', compiler)
        self.invoke('web', '--web-emcc=' + str(compiler), '--check')
        self.assertEqual(len(self.calls()), 1)

    def test_web_broken_compiler(self):
        self.program('emcc', 'import sys\nsys.exit(9)\n')
        self.assertIn('command failed (9)', self.invoke('web', '--check', ok=False))
        self.assertFalse(any(c['tool'] == 'configure' for c in self.calls()))

    def test_relative_compiler_path(self):
        self.invoke('web', '--web-emcc', 'bin/emcc')
        config = next(c['args'] for c in self.calls() if c['tool'] == 'configure')
        self.assertEqual(config[:2], ['--web-emcc', str(self.bin / 'emcc')])

    def test_invalid_repository_override(self):
        self.env['GULCHCE_DIR'] = str(self.root / 'not a checkout')
        self.assertIn('cannot find GulchCE', self.invoke('web', '--check', ok=False))

    def test_check_is_read_only_even_install_requested(self):
        self.invoke('web', '--check', '--install-deps')
        self.assertFalse((self.repo / 'build').exists())
        self.assertEqual([c['tool'] for c in self.calls()], ['emcc'])

    def test_linux_no_cross_flags(self):
        self.invoke('linux', '--release')
        self.assertEqual(next(c['args'] for c in self.calls() if c['tool'] == 'configure'), ['--release'])

    def test_android_exports_and_beta_switch(self):
        self.android()
        self.env['HALO_BETA'] = '1'
        self.invoke('android')
        config = next(c['args'] for c in self.calls() if c['tool'] == 'configure')
        self.assertEqual(config, ['--android-ndk', str(Path(self.env['ANDROID_SDK_ROOT']) / 'ndk/30.2')])
        apk_call = self.calls()[-1]
        self.assertEqual(apk_call['suffix'], '.beta')
        self.assertEqual(apk_call['sdk'], self.env['ANDROID_SDK_ROOT'])
        self.assertEqual(apk_call['java'], self.env['JAVA_HOME'])
        self.env['HALO_BETA'] = '0'
        self.invoke('android')
        self.assertEqual(self.calls()[-1]['suffix'], '')

    def mock_android_terminal(self, answer=None):
        # Execute the real heredoc dispatcher, replacing only its controlling tty.
        self.program('python3', '''import builtins,io,sys
from unittest.mock import patch
original_open = builtins.open
class Terminal(io.StringIO):
    def isatty(self): return True
def open_terminal(path, *args, **kwargs):
    if path == '/dev/tty':
        answer = ANSWER
        if answer is None: raise AssertionError('unexpected terminal prompt')
        return Terminal(answer)
    return original_open(path, *args, **kwargs)
source = sys.stdin.read()
sys.argv = sys.argv[1:]
with patch('builtins.open', open_terminal):
    exec(compile(source, '<dispatcher>', 'exec'))
'''.replace('ANSWER', repr(answer)))

    def test_android_mock_terminal_answers(self):
        self.android()
        for answer, suffix in (('yes\n', '.beta'), ('\n', ''), ('no\n', ''),
                               ('invalid\ny\n', '.beta')):
            with self.subTest(answer=answer):
                self.mock_android_terminal(answer)
                output = self.invoke('android')
                self.assertIn('Build Halo Beta', output)
                self.assertEqual(self.calls()[-1]['suffix'], suffix)
        self.mock_android_terminal('')
        self.assertIn('terminal input closed', self.invoke('android', ok=False))

    def test_android_prompt_bypass_and_suffix_precedence(self):
        self.android()
        self.mock_android_terminal()
        for beta, inherited, suffix in (('0', '.beta', ''), ('1', '', '.beta'),
                                        (None, '.beta', '.beta'), (None, '', '')):
            with self.subTest(beta=beta, inherited=inherited):
                self.env.pop('HALO_BETA', None)
                if beta is not None:
                    self.env['HALO_BETA'] = beta
                self.env['ORG_GRADLE_PROJECT_haloAppIdSuffix'] = inherited
                output = self.invoke('android')
                self.assertNotIn('Build Halo Beta', output)
                self.assertEqual(self.calls()[-1]['suffix'], suffix)
        self.env.pop('HALO_BETA', None)
        self.env['ORG_GRADLE_PROJECT_haloAppIdSuffix'] = '.invalid'
        self.invoke('android', ok=False)
        self.env.pop('ORG_GRADLE_PROJECT_haloAppIdSuffix')
        self.assertNotIn('Build Halo Beta', self.invoke('android', '--check'))

    def test_android_noninteractive_defaults_stable(self):
        self.android()
        output = self.invoke('android')
        self.assertIn('noninteractive; defaulting to stable', output)
        self.assertEqual(self.calls()[-1]['suffix'], '')

    def test_android_suffix_invalidates_only_stale_apk(self):
        self.android()
        apk = self.repo / 'port/android/app/build/outputs/apk/debug/app-debug.apk'
        marker = self.repo / 'port/android/app/build/halo_app_id_suffix'
        # A fake incremental ninja preserves existing outputs, exposing stale APKs.
        self.program('ninja', '''import sys
from pathlib import Path
if 'android_apk' in sys.argv:
    apk = Path('port/android/app/build/outputs/apk/debug/app-debug.apk')
    apk.parent.mkdir(parents=True, exist_ok=True)
    if not apk.exists(): apk.write_text('rebuilt')
''')
        for beta in ('0', '1', '0'):
            self.env['HALO_BETA'] = beta
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_text('stale')
            self.invoke('android')
            self.assertEqual(apk.read_text(), 'rebuilt')
            self.assertEqual(marker.read_text(), '.beta' if beta == '1' else '')
            apk.write_text('unchanged')
            self.invoke('android')
            self.assertEqual(apk.read_text(), 'unchanged')

    def test_android_interactive_terminal(self):
        import fcntl
        import pty
        import termios

        self.android()
        for answer, beta, args, expected in (
                ('yes', None, (), '.beta'), ('no', None, (), ''),
                (None, '0', (), ''), (None, '1', (), '.beta'),
                (None, None, ('--check',), None)):
            with self.subTest(answer=answer, beta=beta, args=args):
                self.env.pop('HALO_BETA', None)
                if beta is not None:
                    self.env['HALO_BETA'] = beta
                try:
                    master, slave = pty.openpty()
                except OSError as error:
                    self.skipTest(f'PTY unavailable (sandbox restriction): {error}')

                def controlling_terminal():
                    os.setsid()
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

                try:
                    try:
                        process = subprocess.Popen(
                            ['/bin/sh', str(self.scripts / 'build-android.sh'), *args],
                            cwd=self.root, env=self.env, stdin=slave,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, preexec_fn=controlling_terminal)
                    except (OSError, subprocess.SubprocessError) as error:
                        self.skipTest(f'controlling terminal unavailable (sandbox restriction): {error}')
                    if answer is not None:
                        os.write(master, (answer + '\n').encode())
                    try:
                        stdout, stderr = process.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                        self.fail('Android prompt did not read /dev/tty or bypass prompt')
                    self.assertEqual(process.returncode, 0, stdout + stderr)
                    self.assertEqual('Build Halo Beta' in stderr, answer is not None)
                    if expected is not None:
                        self.assertEqual(self.calls()[-1]['suffix'], expected)
                finally:
                    os.close(master)
                    os.close(slave)

    def test_android_missing_sdk_packages(self):
        sdk = self.android()
        (sdk / 'platforms/android-35/android.jar').unlink()
        output = self.invoke('android', '--check', ok=False)
        self.assertIn('without --check', output)
        self.assertIn('platforms;android-35', output)
        self.assertNotIn('build-tools;36.0.0', output)
        self.assertEqual(self.calls(), [])

    def sdkmanager(self, sdk, location='PATH', mode='install'):
        manager = self.program('sdkmanager', """import json,os,sys
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'tool':'sdkmanager', 'args':sys.argv[1:], 'java':os.getenv('JAVA_HOME'), 'sdk':os.getenv('ANDROID_HOME')})+'\\n')
sys.exit(7) if MODE == 'fail' else None
root = Path(sys.argv[1].split('=', 1)[1])
for package in sys.argv[2:] if MODE == 'install' else []:
    files = {'platforms;android-35':['platforms/android-35/android.jar'], 'build-tools;36.0.0':['build-tools/36.0.0/'+n for n in ('aapt2','zipalign','apksigner')], 'platform-tools':['platform-tools/adb']}[package]
    for name in files:
        p = root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.touch()
""".replace('MODE', repr(mode)))
        if location != 'PATH':
            destination = sdk / location / 'bin/sdkmanager'
            destination.parent.mkdir(parents=True, exist_ok=True)
            manager.rename(destination)

    def test_android_installs_only_missing(self):
        for location in ('PATH', 'cmdline-tools/latest', 'cmdline-tools/19.0', 'tools'):
            with self.subTest(location=location):
                # Each fixture is independent even when testing SDK discovery fallback.
                if hasattr(self, 'sdk_fixture'):
                    shutil.rmtree(self.sdk_fixture)
                    shutil.rmtree(self.repo / 'port')
                    shutil.rmtree(Path(self.env['JAVA_HOME']))
                    if self.log.exists():
                        self.log.unlink()
                sdk = self.android()
                self.sdk_fixture = sdk
                (sdk / 'platforms/android-35/android.jar').unlink()
                (sdk / 'platform-tools/adb').unlink()
                self.sdkmanager(sdk, location)
                self.invoke('android')
                call = self.calls()[0]
                self.assertEqual(call['tool'], 'sdkmanager')
                self.assertEqual(call['args'], ['--sdk_root='+str(sdk), 'platforms;android-35', 'platform-tools'])
                self.assertEqual(call['java'], self.env['JAVA_HOME'])
                self.assertEqual(call['sdk'], str(sdk))
                self.assertEqual(self.calls()[1]['tool'], 'configure')
                self.log.unlink()
                self.invoke('android')
                self.assertNotIn('sdkmanager', [c['tool'] for c in self.calls()])

    def test_android_check_never_installs(self):
        sdk = self.android()
        (sdk / 'build-tools/36.0.0/aapt2').unlink()
        self.sdkmanager(sdk)
        self.invoke('android', '--check', '--install-deps', ok=False)
        self.assertEqual(self.calls(), [])
        self.assertFalse((sdk / 'build-tools/36.0.0/aapt2').exists())

    def test_android_install_failures_abort(self):
        sdk = self.android()
        (sdk / 'build-tools/36.0.0/aapt2').unlink()
        self.assertIn('AUR', self.invoke('android', ok=False))
        for mode in ('fail', 'decline'):
            self.sdkmanager(sdk, mode=mode)
            self.invoke('android', ok=False)
            self.assertTrue(all(c['tool'] == 'sdkmanager' for c in self.calls()))
            self.assertFalse((sdk / 'build-tools/36.0.0/aapt2').exists())

    def test_android_root_sdk_elevates_only_manager(self):
        sdk = self.android()
        (sdk / 'platform-tools/adb').unlink()
        self.sdkmanager(sdk)
        # Simulate root ownership and denied write access without touching /opt
        # or depending on the test runner's uid/permission privileges.
        bootstrap = """import os,sys
sys.argv = sys.argv[1:]
from pathlib import Path
from unittest.mock import patch
original_stat = Path.stat
class RootStat:
    st_uid = 0
    def __init__(self, value): self.value = value
    def __getattr__(self, key): return getattr(self.value, key)
def stat(path, *args, **kwargs):
    value = original_stat(path, *args, **kwargs)
    return RootStat(value) if 'SDK with spaces' in str(path) else value
access = os.access
with patch('os.geteuid', return_value=1000), patch('pathlib.Path.stat', stat), patch('os.access', side_effect=lambda p,m: False if m == os.W_OK else access(p,m)):
    exec(compile(sys.stdin.read(), '<driver>', 'exec'))
"""
        self.program('python3', bootstrap)
        self.program('env', 'import os,sys\nfor entry in sys.argv[1:]:\n    if "=" not in entry: break\n    key,value=entry.split("=",1); os.environ[key]=value\nelse: sys.exit(1)\nos.execv(entry, sys.argv[sys.argv.index(entry):])\n')
        self.program('sudo', "import os,sys,json\nwith open(os.environ['CALLS'],'a') as f: f.write(json.dumps({'tool':'sudo','args':sys.argv[1:]})+'\\n')\nos.execv(sys.argv[1],sys.argv[1:])\n")
        output = self.invoke('android')
        self.assertIn('elevating only sdkmanager', output)
        self.assertEqual([c['tool'] for c in self.calls()], ['sudo', 'sdkmanager', 'configure', 'ninja', 'ninja'])
        self.assertEqual(self.calls()[1]['java'], self.env['JAVA_HOME'])

    def test_android_java21_supported(self):
        self.android()
        for name in ('java', 'javac'):
            (Path(self.env['JAVA_HOME']) / 'bin' / name).write_text('#!/bin/sh\nprintf \'openjdk version "21.0.1"\\n\' >&2\n')
        self.invoke('android', '--check')

    def test_android_bad_java_override(self):
        self.android()
        self.env['JAVA_HOME'] = str(self.root / 'missing java')
        self.assertIn('JDK 17', self.invoke('android', '--check', ok=False))

    def test_android_bad_beta(self):
        self.android()
        self.env['HALO_BETA'] = 'yes'
        self.assertIn('HALO_BETA must', self.invoke('android', '--check', ok=False))

    def test_android_local_properties(self):
        sdk = self.android()
        self.env.pop('ANDROID_SDK_ROOT')
        (self.repo / 'port/android/local.properties').write_text('sdk.dir=' + str(sdk).replace(' ', '\\ ') + '\n')
        self.invoke('android', '--check')
        self.assertEqual(self.calls(), [])

    def test_windows_flat_adapter(self):
        vc, sdk = self.windows(True)
        self.invoke('windows', '--check')
        self.assertFalse((self.repo / 'build').exists())
        self.invoke('windows')
        config = next(c['args'] for c in self.calls() if c['tool'] == 'configure')
        self.assertIn('--windows-cross', config)
        self.assertIn(str(vc), config)
        self.assertFalse(any('web' in s or 'android' in s for s in config))
        self.assertEqual((self.repo / 'build/halo-toolchains/windows-sdk/Include/10.0.0').resolve(), sdk / 'include')

    def test_windows_legacy_and_overrides(self):
        vc, sdk = self.windows(False)
        self.env['XWIN_DIR'] = '/nonexistent'
        self.env['VCToolsInstallDir'] = str(vc)
        self.env['WindowsSdkDir'] = str(sdk)
        self.invoke('windows')
        config = next(c['args'] for c in self.calls() if c['tool'] == 'configure')
        self.assertIn(str(vc), config)
        self.assertIn(str(sdk), config)

    def test_windows_flat_explicit_sdk_override(self):
        vc, sdk = self.windows(True)
        self.invoke('windows', '--windows-vctools-dir=' + str(vc), '--windows-sdk-dir', str(sdk))
        config = next(c['args'] for c in self.calls() if c['tool'] == 'configure')
        sdk_indices = [i for i, arg in enumerate(config) if arg == '--windows-sdk-dir']
        self.assertEqual(len(sdk_indices), 2)
        self.assertEqual(config[sdk_indices[-1] + 1], str(self.repo / 'build/halo-toolchains/windows-sdk'))

    def xwin(self, location='PATH', mode='success'):
        self.env['MOCK_XWIN_MODE'] = mode
        body = """import json,os,sys
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'tool':'xwin', 'args':sys.argv[1:], 'consent':os.getenv('XWIN_ACCEPT_LICENSE')})+'\\n')
assert sys.argv[1:4] == ['--arch', 'x86', 'splat']
assert sys.argv[4] == '--output'
if os.environ['MOCK_XWIN_MODE'] == 'interactive':
    assert sys.stdin.isatty()
    print('Review Microsoft licenses; accept? [yes/no]', flush=True)
    if input().strip() != 'yes':
        sys.exit(7)
else:
    assert os.environ.get('XWIN_ACCEPT_LICENSE') == 'true'
if os.environ['MOCK_XWIN_MODE'] == 'failure':
    sys.exit(23)
root = Path(sys.argv[5])
(root / 'crt/include').mkdir(parents=True)
if os.environ['MOCK_XWIN_MODE'] == 'incomplete':
    sys.exit(0)
for d in ('crt/lib/x86', 'sdk/include/um', 'sdk/include/ucrt', 'sdk/include/shared', 'sdk/lib/um/x86', 'sdk/lib/ucrt/x86'):
    (root / d).mkdir(parents=True)
"""
        path = self.program('xwin', body)
        if location != 'PATH':
            directory = self.root / location / 'bin'
            directory.mkdir(parents=True, exist_ok=True)
            path = path.rename(directory / 'xwin')
        return path

    def test_windows_license_flag(self):
        self.xwin()
        self.invoke('windows', '--accept-license')
        self.assertEqual(self.calls()[0]['consent'], 'true')

    def test_windows_provision_and_reuse(self):
        self.xwin()
        self.env['XWIN_ACCEPT_LICENSE'] = '1'
        root = self.root / '.local/share/xwin'
        self.assertIn('External download', self.invoke('windows'))
        self.assertTrue((root / 'crt/lib/x86').is_dir())
        self.invoke('windows')
        self.assertEqual(len([c for c in self.calls() if c['tool'] == 'xwin']), 1)
        self.assertFalse(list(root.parent.glob('.xwin-stage-*')))

    def test_windows_xwin_cargo_locations(self):
        for location in ('.cargo', '.local/share/cargo', 'custom cargo'):
            with self.subTest(location=location):
                path = self.xwin(location)
                if location == 'custom cargo':
                    self.env['CARGO_HOME'] = str(path.parent.parent)
                self.env['XWIN_DIR'] = str(self.root / ('new toolchain ' + location))
                self.env['XWIN_ACCEPT_LICENSE'] = '1'
                self.invoke('windows')
                path.unlink()

    def test_windows_missing_cargo(self):
        self.assertIn('--install-deps', self.invoke('windows', ok=False))
        self.assertEqual(self.calls(), [])

    def test_windows_no_noninteractive_consent(self):
        self.xwin()
        for consent in ('', '0', 'yes'):
            self.env['XWIN_ACCEPT_LICENSE'] = consent
            self.assertIn('XWIN_ACCEPT_LICENSE=1', self.invoke('windows', ok=False))
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / '.local').exists())

    def test_windows_interactive_consent_and_decline(self):
        import fcntl
        import pty
        import termios

        self.xwin(mode='interactive')
        for answer in ('no', 'yes'):
            with self.subTest(answer=answer):
                try:
                    master, slave = pty.openpty()
                except OSError as error:
                    self.skipTest(f'PTY unavailable (sandbox restriction): {error}')

                def controlling_terminal():
                    os.setsid()
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

                try:
                    process = subprocess.Popen(
                        ['/bin/sh', str(self.scripts / 'build-windows.sh')],
                        cwd=self.root, env=self.env, stdin=slave,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, preexec_fn=controlling_terminal)
                    os.write(master, (answer + '\n').encode())
                    try:
                        stdout, stderr = process.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                        self.fail('interactive xwin prompt did not read /dev/tty')
                    self.assertIn('accept? [yes/no]', stdout)
                    self.assertEqual(process.returncode == 0, answer == 'yes', stdout + stderr)
                    self.assertEqual((self.root / '.local/share/xwin').exists(), answer == 'yes')
                finally:
                    os.close(master)
                    os.close(slave)

    def test_windows_check_no_provision(self):
        self.xwin()
        self.env['XWIN_ACCEPT_LICENSE'] = '1'
        self.assertIn('No changes made', self.invoke('windows', '--check', '--install-deps', ok=False))
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / '.local').exists())

    def test_windows_failures_do_not_publish(self):
        for mode in ('failure', 'incomplete'):
            with self.subTest(mode=mode):
                self.xwin(mode=mode)
                self.env['XWIN_ACCEPT_LICENSE'] = '1'
                self.invoke('windows', ok=False)
                self.assertFalse((self.root / '.local/share/xwin').exists())
                self.assertFalse(list((self.root / '.local/share').glob('.xwin-stage-*')))
        self.assertFalse(any(c['tool'] == 'configure' for c in self.calls()))

    def test_windows_reject_partial_root_and_overrides(self):
        self.xwin()
        self.env['XWIN_ACCEPT_LICENSE'] = '1'
        root = self.root / '.local/share/xwin'
        root.mkdir(parents=True)
        marker = root / 'keep'
        marker.write_text('keep')
        self.assertIn('nonempty incomplete', self.invoke('windows', ok=False))
        self.assertEqual(marker.read_text(), 'keep')
        for flag, variable in (('--windows-vctools-dir', 'VCToolsInstallDir'), ('--windows-sdk-dir', 'WindowsSdkDir')):
            self.assertIn('invalid explicit', self.invoke('windows', flag, str(self.root / 'missing'), ok=False))
            self.env[variable] = str(self.root / 'missing')
            self.assertIn('invalid explicit', self.invoke('windows', ok=False))
            del self.env[variable]
        self.assertEqual(self.calls(), [])

    def test_windows_empty_root(self):
        self.xwin()
        root = self.root / 'empty xwin'
        root.mkdir()
        self.env.update(XWIN_DIR=str(root), XWIN_ACCEPT_LICENSE='1')
        self.invoke('windows')
        self.assertTrue((root / 'crt/include').is_dir())

    def test_windows_install_xwin(self):
        xwin = self.xwin('.cargo')
        template = xwin.rename(self.root / 'xwin template')
        self.program('cargo', """import json,os,shutil,sys
from pathlib import Path
assert sys.argv[1:] == ['install', '--locked', 'xwin']
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'tool':'cargo', 'args':sys.argv[1:]})+'\\n')
shutil.copy2(Path.home() / 'xwin template', Path.home() / '.cargo/bin/xwin')
""")
        self.env['XWIN_ACCEPT_LICENSE'] = '1'
        self.assertIn('cargo install --locked xwin', self.invoke('windows'))
        self.assertEqual([c['tool'] for c in self.calls()][:2], ['cargo', 'xwin'])
        self.assertTrue(template.exists())

    def test_windows_cargo_failure(self):
        self.program('cargo', 'import sys\nsys.exit(31)\n')
        self.env['XWIN_ACCEPT_LICENSE'] = '1'
        self.assertIn('provisioning failed', self.invoke('windows', ok=False))
        self.assertFalse((self.root / '.local').exists())

    def test_windows_cargo_missing_installed_binary(self):
        self.program('cargo', 'pass\n')
        self.env['XWIN_ACCEPT_LICENSE'] = '1'
        self.assertIn('cargo install succeeded but xwin was not found', self.invoke('windows', ok=False))
        self.assertFalse((self.root / '.local').exists())

    def test_windows_symlink_root_not_provisioned(self):
        self.xwin()
        target = self.root / 'empty target'
        target.mkdir()
        link = self.root / 'linked xwin'
        link.symlink_to(target, target_is_directory=True)
        self.env.update(XWIN_DIR=str(link), XWIN_ACCEPT_LICENSE='1')
        self.assertIn('symlink', self.invoke('windows', ok=False))
        self.assertTrue(link.is_symlink())
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(self.calls(), [])

    def test_windows_numeric_version_selection(self):
        vc, sdk = self.windows(False)
        shutil.copytree(vc, vc.parent / '14.9')
        shutil.copytree(vc, vc.parent / '14.100')
        self.invoke('windows')
        config = next(c['args'] for c in self.calls() if c['tool'] == 'configure')
        self.assertIn(str(vc.parent / '14.100'), config)

    def test_discovery_current_ancestor_and_sibling(self):
        del self.env['GULCHCE_DIR']
        nested = self.repo / 'nested/dir'
        nested.mkdir(parents=True)
        self.invoke('web', '--check', cwd=nested)
        self.invoke('web', '--check', cwd=self.root)

    def test_help_needs_no_repo_or_compiler(self):
        self.env['GULCHCE_DIR'] = '/missing'
        (self.bin / 'emcc').unlink()
        self.assertIn('--check', self.invoke('web', '--help'))
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
