#!/bin/sh
# shellcheck disable=SC2154
# Shared POSIX entry point. Python is the only bootstrap dependency.
# Wrappers resolve their own symlinks before sourcing this file.
exec "${PYTHON:-python3}" - "$target" "$script_dir" "$@" <<'PY'
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TARGET, SCRIPTS, *args = sys.argv[1:]
SCRIPTS = Path(SCRIPTS)

def report_exception(kind, error, traceback):
    if isinstance(error, subprocess.CalledProcessError):
        sys.stderr.write(f'error: command failed ({error.returncode}): {error.cmd}\n')
    elif isinstance(error, OSError):
        sys.stderr.write(f'error: {error}\n')
    else:
        sys.__excepthook__(kind, error, traceback)
sys.excepthook = report_exception

env = os.environ.copy()
check = False
install = False
forward = []
options = {}
value_flags = {'--web-emcc', '--android-ndk', '--android-guest-cc', '--linux-cc',
               '--windows-cc', '--windows-vctools-dir', '--windows-sdk-dir'}

def fail(message):
    sys.exit('error: ' + message)

def run(argv, **kwargs):
    subprocess.run([str(a) for a in argv], check=True, env=env, **kwargs)

def version_key(path):
    return tuple(int(n) for n in re.findall(r'\d+', path.name))

def newest(paths):
    return next(iter(sorted((p for p in paths if p.is_dir()), key=version_key, reverse=True)), None)

def absolute(value):
    return Path(value).expanduser().resolve()

def tool(value):
    found = shutil.which(str(value), path=env.get('PATH'))
    if not found:
        fail(f'missing executable {value}; install it or set the corresponding configure option')
    return str(absolute(found))

def child(path, name):
    return next((p for p in path.iterdir() if p.name.lower() == name.lower()), path / name) if path.is_dir() else path / name

it = iter(args)
for arg in it:
    if arg == '--':
        forward.extend(it)
        break
    if arg in ('--help', '-h'):
        print(f'''Usage: build-{TARGET}.sh [--check] [--install-deps] [configure.py options]
--check          Validate prerequisites only; no configure, build, install or writes.
--install-deps   Explicitly install Arch repository packages (sudo pacman).
--accept-license Windows only: explicitly accept Microsoft's SDK licenses for xwin.
--help          Show this help. Other arguments are passed unchanged to configure.py.
Tool paths: --web-emcc, --android-ndk, --android-guest-cc, --linux-cc,
--windows-cc, --windows-vctools-dir, --windows-sdk-dir (also --flag=value).
See README.md for discovery, environment overrides and manual SDK provisioning.''')
        sys.exit(0)
    if arg == '--check':
        check = True
    elif arg == '--install-deps':
        install = True
    elif arg == '--accept-license':
        if TARGET != 'windows':
            fail('--accept-license is only supported by build-windows.sh')
        env['XWIN_ACCEPT_LICENSE'] = '1'
    else:
        name, sep, val = arg.partition('=')
        forward.append(arg)
        if name in value_flags:
            if not sep:
                val = next(it, '')
                if not val or val.startswith('--'):
                    fail(f'{name} requires a value')
                forward.append(val)
            # Relative paths are relative to the invoking directory, not GulchCE.
            if '/' in val or name in ('--android-ndk', '--windows-vctools-dir', '--windows-sdk-dir'):
                val = str(absolute(val))
                forward[-1] = name + '=' + val if sep else val
            options[name] = val

# Resolve relative overrides before changing cwd. Keep every pass-through argument intact.
if env.get('GULCHCE_DIR'):
    repo = absolute(env['GULCHCE_DIR'])
else:
    starts = [Path.cwd(), SCRIPTS]
    candidates = []
    for start in starts:
        candidates.extend([start, *start.parents])
    candidates.extend(p / 'GulchCE' for start in starts for p in [start, *start.parents])
    repo = next((p for p in candidates if (p / 'configure.py').is_file() and (p / 'tools').is_dir()), None)
if repo is None or not (repo / 'configure.py').is_file():
    fail('cannot find GulchCE/configure.py; set GULCHCE_DIR to the checkout')
repo = repo.resolve()

if install and not check:
    release = Path('/etc/os-release').read_text() if Path('/etc/os-release').exists() else ''
    if not re.search(r'^ID=(?:"?)(arch|artix|manjaro)(?:"?)$', release, re.M) and not re.search(r'^ID_LIKE=.*\barch\b', release, re.M):
        fail('--install-deps supports Arch-family hosts only; install Python 3, ninja and the target prerequisites manually (README.md)')
    pacman = tool('pacman')
    packages = ['python', 'ninja', 'git']
    packages += {'web': [], 'linux': ['clang', 'lld', 'llvm', 'lib32-glibc', 'lib32-sdl3'],
                 'windows': ['clang', 'lld', 'llvm'],
                 'android': ['clang', 'lld', 'llvm', 'cmake', 'jdk21-openjdk']}[TARGET]
    # Do not install pacman's Rust alongside an existing rustup toolchain.
    if TARGET == 'windows':
        cargo_bins = [absolute(env.get('CARGO_HOME', str(Path.home() / '.cargo'))) / 'bin',
                      Path.home() / '.cargo/bin', Path.home() / '.local/share/cargo/bin']
        rust_available = any(shutil.which(name, path=env.get('PATH')) or
                             any((p / name).is_file() for p in cargo_bins)
                             for name in ('cargo', 'rustup'))
        if not rust_available:
            packages.append('rust')
    run(([] if os.geteuid() == 0 else [tool('sudo')]) + [pacman, '-S', '--needed', *packages])

tool('ninja')
extra = []

def add(flag, value):
    if flag not in options:
        extra.extend([flag, str(value)])

if TARGET == 'web':
    explicit = options.get('--web-emcc') or env.get('EMCC')
    roots = [absolute(env[k]) for k in ('EMSDK_DIR', 'EMSDK') if env.get(k)]
    roots += [Path.home() / 'emsdk', Path.home() / '.local/src/emsdk', Path('/opt/emsdk')]
    emcc = explicit or shutil.which('emcc')
    if not emcc:
        emcc = next((str(p / 'upstream/emscripten/emcc') for p in roots if (p / 'upstream/emscripten/emcc').is_file()), None)
    if not emcc:
        fail('emcc not found; set --web-emcc PATH, EMCC, EMSDK_DIR or EMSDK, or activate emsdk on PATH. No SDK is downloaded automatically.')
    emcc = tool(emcc)
    probe = subprocess.run([emcc, '--version'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if probe.returncode:
        # emsdk-env.sh can rely on shell extensions: source through bash, only
        # after the direct compiler failed. Import NUL-separated exports safely.
        root = next((p for p in roots + list(Path(emcc).parents) if (p / 'emsdk_env.sh').is_file()), None)
        if root and shutil.which('bash'):
            activated = subprocess.run(['bash', '-c', '. "$1" >/dev/null && env -0', 'emsdk-env', str(root / 'emsdk_env.sh')], env=env, stdout=subprocess.PIPE)
            if activated.returncode == 0:
                env.update(item.decode().split('=', 1) for item in activated.stdout.split(b'\0') if b'=' in item)
        run([emcc, '--version'], stdout=subprocess.DEVNULL)
    add('--web-emcc', emcc)

elif TARGET == 'linux':
    import platform
    if platform.system() != 'Linux' or platform.machine().lower() not in ('x86_64', 'amd64', 'i386', 'i686'):
        fail('Linux target is x86 32-bit and requires an x86 Linux host with 32-bit glibc/SDL3; other architectures are not supported by this wrapper')
    tool(options.get('--linux-cc', 'clang'))
    tool('ld.lld')
    print('Linux prerequisite: 32-bit glibc and SDL3 development/runtime libraries (not validated by command discovery).')

elif TARGET == 'windows':
    tool(options.get('--windows-cc', 'clang'))
    tool('lld-link')
    tool('llvm-rc')
    root = absolute(env.get('XWIN_DIR', str(Path.home() / '.local/share/xwin')))
    vc_value = options.get('--windows-vctools-dir') or env.get('VCToolsInstallDir')
    sdk_value = options.get('--windows-sdk-dir') or env.get('WindowsSdkDir')
    def windows_paths(base):
        return (base / 'crt' if (base / 'crt').is_dir() else newest((base / 'VC/Tools/MSVC').glob('*')),
                base / 'sdk' if (base / 'sdk').is_dir() else base / 'Windows Kits/10')

    def valid_vc(path):
        return path is not None and child(path, 'include').is_dir() and child(child(path, 'lib'), 'x86').is_dir()

    def sdk_layout(path):
        inc, lib = child(path, 'include'), child(path, 'lib')
        flat = child(inc, 'um').is_dir() and child(inc, 'ucrt').is_dir()
        versions = [None] if flat else sorted((p.name for p in inc.glob('*') if p.is_dir()), key=lambda v: version_key(Path(v)), reverse=True)
        for version in versions:
            include_base = inc if flat else inc / version
            lib_base = lib if flat else lib / version
            if all(child(include_base, n).is_dir() for n in ('um', 'ucrt', 'shared')) and all(child(child(lib_base, n), 'x86').is_dir() for n in ('um', 'ucrt')):
                return inc, lib, flat
        return None

    vc, sdk = windows_paths(root)
    vc = absolute(vc_value) if vc_value else vc
    sdk = absolute(sdk_value) if sdk_value else sdk
    if vc_value and not valid_vc(vc):
        fail('invalid explicit --windows-vctools-dir / VCToolsInstallDir: missing x86 MSVC include/lib directories; point to versioned VC/Tools/MSVC or xwin crt. No provisioning attempted.')
    if sdk_value and not sdk_layout(sdk):
        fail('invalid explicit --windows-sdk-dir / WindowsSdkDir: missing matching x86 SDK headers/libraries; correct the override. No provisioning attempted.')
    if not valid_vc(vc) or not sdk_layout(sdk):
        if check:
            fail('missing x86 MSVC include/lib or Windows SDK in ' + str(root) + '; rerun without --check to provision xwin, or set --windows-vctools-dir and --windows-sdk-dir. No changes made.')
        if root.exists() and (not root.is_dir() or any(root.iterdir())):
            fail(f'refusing to overwrite nonempty incomplete XWIN_DIR {root}; repair it manually or select a new empty dedicated XWIN_DIR')
        raw_root = Path(env.get('XWIN_DIR', str(Path.home() / '.local/share/xwin'))).expanduser()
        if raw_root.is_symlink():
            fail('refusing to provision through an XWIN_DIR symlink; select a new empty dedicated directory')
        cargo_bins = [absolute(env.get('CARGO_HOME', str(Path.home() / '.cargo'))) / 'bin', Path.home() / '.cargo/bin', Path.home() / '.local/share/cargo/bin']

        def cargo_tool(name):
            return shutil.which(name, path=env.get('PATH')) or next((str(p / name) for p in cargo_bins if (p / name).is_file() and os.access(p / name, os.X_OK)), None)

        xwin = cargo_tool('xwin')
        cargo = cargo_tool('cargo') if not xwin else None
        if not xwin and not cargo:
            fail('missing xwin and cargo; use --install-deps on Arch or install Cargo manually, then rerun; alternatively provision x86 xwin manually and set XWIN_DIR. No rustup is installed automatically.')
        license_input = None
        if env.get('XWIN_ACCEPT_LICENSE') != '1':
            try:
                # stdin is the Python heredoc, not the caller's terminal.
                license_input = open('/dev/tty', 'r+')
            except OSError:
                fail('Microsoft SDK license consent required: rerun from an interactive terminal to review xwin prompts, or review the Microsoft licenses and explicitly set XWIN_ACCEPT_LICENSE=1. No downloads started.')
        try:
            if not xwin:
                print('External download: installing xwin with cargo install --locked xwin (crates.io); no rustup installation or toolchain changes.', flush=True)
                run([cargo, 'install', '--locked', 'xwin'])
                xwin = cargo_tool('xwin')
                if not xwin:
                    fail('cargo install succeeded but xwin was not found; add its install bin directory to PATH and rerun')
            print(f'External download: xwin will fetch Microsoft x86 CRT/SDK into {root}. Review and affirm its license prompts; XWIN_ACCEPT_LICENSE=1 is explicit prior consent.', flush=True)
            root.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='.xwin-stage-', dir=root.parent) as staging:
                stage = Path(staging)
                output = stage / 'toolchain'
                # Our wrapper documents 1 for consent; xwin's clap parser
                # reads the same variable but accepts only true/false.
                if env.get('XWIN_ACCEPT_LICENSE') == '1':
                    env['XWIN_ACCEPT_LICENSE'] = 'true'
                run([xwin, '--arch', 'x86', 'splat', '--output', output], cwd=stage, stdin=license_input if license_input else subprocess.DEVNULL)
                staged_vc, staged_sdk = windows_paths(output)
                if not valid_vc(staged_vc) or not sdk_layout(staged_sdk):
                    fail('xwin did not produce complete x86 CRT/SDK directories; no toolchain published. Check xwin version/output and retry.')
                # Only an absent or still-empty dedicated root can be replaced.
                if root.exists():
                    root.rmdir()
                output.rename(root)
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f'xwin provisioning failed: {error}; review licenses, Cargo/xwin version, network and directory permissions, then rerun. No build started.')
        finally:
            if license_input:
                license_input.close()
        default_vc, default_sdk = windows_paths(root)
        vc = vc if vc_value else default_vc
        sdk = sdk if sdk_value else default_sdk
    inc, lib, flat = sdk_layout(sdk)
    if flat:
        # GulchCE requires versioned Include/Lib; adapt ordinary xwin without
        # copying or modifying the provisioned SDK. No writes during --check.
        view = repo / 'build/halo-toolchains/windows-sdk'
        if not check:
            for name, source in (('Include', inc), ('Lib', lib)):
                dest = view / name / '10.0.0'
                dest.parent.mkdir(parents=True, exist_ok=True)
                if dest.is_symlink():
                    dest.unlink()
                if dest.exists():
                    fail(f'refusing to overwrite {dest}')
                dest.symlink_to(source, target_is_directory=True)
        sdk = view
        if '--windows-sdk-dir' in options:
            # The original flag remains, but the adapter must win argparse's
            # last-value rule so upstream receives a supported layout.
            extra.extend(['--windows-sdk-dir', str(sdk)])
    add('--windows-vctools-dir', vc)
    add('--windows-sdk-dir', sdk)
    if '--windows-cross' not in forward:
        extra.append('--windows-cross')

elif TARGET == 'android':
    tool(options.get('--android-guest-cc', 'clang'))
    tool('ld.lld')
    tool('cmake')
    sdk_value = env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT')
    props = repo / 'port/android/local.properties'
    if not sdk_value and props.is_file():
        match = re.search(r'^\s*sdk\.dir\s*[=:]\s*(.*?)\s*$', props.read_text(), re.M)
        if match:
            sdk_value = re.sub(r'\\([ :\\=])', r'\1', match[1])
            if not Path(sdk_value).is_absolute():
                sdk_value = str(props.parent / sdk_value)
    sdk = absolute(sdk_value) if sdk_value else next((p for p in [Path.home() / 'Android/Sdk', Path.home() / 'Android/sdk', Path.home() / 'Library/Android/sdk', Path('/opt/android-sdk'), Path('/usr/lib/android-sdk')] if p.is_dir()), None)
    if sdk is None or not sdk.is_dir():
        fail('Android SDK not found; set ANDROID_HOME or ANDROID_SDK_ROOT, or port/android/local.properties sdk.dir')
    env['ANDROID_HOME'] = env['ANDROID_SDK_ROOT'] = str(sdk)
    ndk_value = options.get('--android-ndk') or next((env[k] for k in ('ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT', 'ANDROID_NDK') if env.get(k)), None)
    ndk = absolute(ndk_value) if ndk_value else newest((sdk / 'ndk').glob('*'))
    if not ndk and (sdk / 'ndk-bundle').is_dir():
        ndk = sdk / 'ndk-bundle'
    if not ndk or not (ndk / 'build/cmake/android.toolchain.cmake').is_file() or not any((ndk / 'toolchains/llvm/prebuilt').glob('*/bin/clang*')):
        fail('Android NDK incomplete or missing; install an NDK with sdkmanager, then set --android-ndk or ANDROID_NDK_HOME')
    env['ANDROID_NDK_HOME'] = str(ndk)
    add('--android-ndk', ndk)
    gradle = (repo / 'port/android/app/build.gradle').read_text()
    compile_sdk = re.search(r'\bcompileSdk\s*(?:=\s*)?(\d+)', gradle)
    tools_version = re.search(r'\bbuildToolsVersion\s*(?:=\s*)?["\x27]([^"\x27]+)', gradle)
    # Current AGP 9.4.1 defaults to build tools 36.0.0; explicit project
    # buildToolsVersion takes precedence. See README for this tracked default.
    tools_version = tools_version[1] if tools_version else '36.0.0'
    if not compile_sdk:
        fail('cannot determine compileSdk from port/android/app/build.gradle')
    required = {
        f'platforms;android-{compile_sdk[1]}': [sdk / f'platforms/android-{compile_sdk[1]}/android.jar'],
        f'build-tools;{tools_version}': [sdk / 'build-tools' / tools_version / name for name in ('aapt2', 'zipalign', 'apksigner')],
        'platform-tools': [sdk / 'platform-tools/adb'],
    }
    missing = lambda: [package for package, files in required.items() if not all(p.is_file() for p in files)]
    packages = missing()
    if packages and check:
        fail('Android SDK packages missing: ' + ', '.join(packages) + '; run build-android.sh without --check to install them (interactive license review).')
    override = env.get('JAVA_HOME') or env.get('JAVA_17_HOME')
    java_roots = [absolute(override)] if override else [Path('/usr/lib/jvm/java-21-openjdk'), Path('/usr/lib/jvm/java-17-openjdk'), *Path('/usr/lib/jvm').glob('*'), *Path('/Library/Java/JavaVirtualMachines').glob('*/Contents/Home')]
    if not override and shutil.which('javac'):
        java_roots.append(Path(shutil.which('javac')).resolve().parent.parent)
    java = None
    for candidate in java_roots:
        if not (candidate / 'bin/java').is_file() or not (candidate / 'bin/javac').is_file():
            continue
        probe = subprocess.run([str(candidate / 'bin/java'), '-version'], capture_output=True, text=True, env=env)
        compiler_probe = subprocess.run([str(candidate / 'bin/javac'), '-version'], capture_output=True, text=True, env=env)
        java_version = re.search(r'version\s+"(\d+)', probe.stdout + probe.stderr)
        javac_version = re.search(r'(?:javac\s+|version\s+")(\d+)', compiler_probe.stdout + compiler_probe.stderr)
        if probe.returncode == 0 and compiler_probe.returncode == 0 and java_version and javac_version and int(java_version[1]) >= 17 and java_version[1] == javac_version[1]:
            java = candidate
            break
    if java is None:
        fail('working JDK 17 or newer required (matching java and javac); set JAVA_HOME or JAVA_17_HOME. An explicit JAVA_HOME is never silently replaced.')
    env['JAVA_HOME'] = str(java)
    env['PATH'] = str(java / 'bin') + os.pathsep + env['PATH']
    if packages:
        manager = shutil.which('sdkmanager', path=env.get('PATH'))
        candidates = [sdk / 'cmdline-tools/latest/bin/sdkmanager']
        candidates += [p / 'bin/sdkmanager' for p in sorted((sdk / 'cmdline-tools').glob('*'), key=version_key, reverse=True)]
        candidates += [sdk / 'tools/bin/sdkmanager']
        manager = manager or next((str(p) for p in candidates if p.is_file() and os.access(p, os.X_OK)), None)
        if not manager:
            fail('missing sdkmanager; --install-deps installs Arch repository prerequisites only. Install android-sdk-cmdline-tools-latest manually from the AUR (no yay is run), or Google command-line tools into ANDROID_HOME/cmdline-tools/latest; then rerun.')
        command = [manager, '--sdk_root=' + str(sdk), *packages]
        # Inspect component parents too: /opt SDKs may contain root-owned subtrees.
        destinations = [sdk]
        for package in packages:
            for path in required[package]:
                parent = path.parent
                while not parent.exists() and parent != sdk:
                    parent = parent.parent
                destinations.append(parent)
        needs_sudo = os.geteuid() != 0 and any(p.stat().st_uid == 0 and not os.access(p, os.W_OK) for p in destinations)
        if needs_sudo:
            print(f'Android SDK {sdk} is root-owned and not writable; elevating only sdkmanager with sudo (configure/Ninja/Gradle remain unprivileged).', flush=True)
            command = [tool('sudo'), tool('env'), 'JAVA_HOME=' + env['JAVA_HOME'], 'PATH=' + env['PATH'], 'ANDROID_HOME=' + str(sdk), 'ANDROID_SDK_ROOT=' + str(sdk), *command]
        print('Installing missing Android SDK packages: ' + ', '.join(packages) + '. Review sdkmanager license prompts interactively; no licenses are auto-accepted.', flush=True)
        try:
            # The shell feeds this driver via a heredoc, so inherited stdin is
            # exhausted. Give sdkmanager the controlling terminal for licenses.
            try:
                license_input = open('/dev/tty', 'r')
            except OSError:
                license_input = open(os.devnull, 'r')
            with license_input:
                run(command, stdin=license_input)
        except (OSError, subprocess.CalledProcessError) as error:
            print(f'error: sdkmanager failed ({error}); review licenses interactively and SDK permissions, then rerun. New command-line tools may require JDK 21: set JAVA_HOME to a compatible JDK. For unattended builds, provision packages/licenses interactively first.', file=sys.stderr)
            sys.exit(getattr(error, 'returncode', 1))
        if missing():
            fail('sdkmanager did not install required files for: ' + ', '.join(missing()) + '; review licenses/permissions interactively, then rerun. No build started.')
    beta = env.get('HALO_BETA')
    suffix_key = 'ORG_GRADLE_PROJECT_haloAppIdSuffix'
    if beta is not None and beta not in ('0', '1'):
        fail('HALO_BETA must be 0 or 1')
    if beta is not None:
        env[suffix_key] = '.beta' if beta == '1' else ''
    elif suffix_key not in env and not check:
        # stdin is the Python heredoc, even when launched from a terminal.
        try:
            terminal = open('/dev/tty', 'r')
        except OSError:
            terminal = None
        if terminal is not None:
            with terminal:
                if terminal.isatty():
                    while True:
                        print('Build Halo Beta (separate app)? [y/N] ', end='', file=sys.stderr, flush=True)
                        answer = terminal.readline()
                        if not answer:
                            fail('terminal input closed; set HALO_BETA=0 or HALO_BETA=1')
                        answer = answer.strip().lower()
                        if answer in ('', 'n', 'no', 'y', 'yes'):
                            beta = '1' if answer in ('y', 'yes') else '0'
                            break
                        print('Please answer yes or no.', file=sys.stderr)
        if beta is None:
            print('Android: noninteractive; defaulting to stable (HALO_BETA=0).')
        env[suffix_key] = '.beta' if beta == '1' else ''
    suffix = env.get(suffix_key, '')
    if suffix not in ('', '.beta'):
        fail('ORG_GRADLE_PROJECT_haloAppIdSuffix must be empty or .beta')
    print('Android app: ' + ('Halo Beta (.beta)' if suffix else 'stable (no suffix)'))

print(f'{TARGET}: prerequisites OK; GulchCE: {repo}')
if check:
    print('Check only: no configure, build, installation or file changes performed.')
    sys.exit(0)
os.chdir(repo)
# Put adapter flags last only for the flat Windows SDK case.
run([sys.executable, 'configure.py', *forward, *extra])
run(['ninja', TARGET])
if TARGET == 'android':
    apk = repo / 'port/android/app/build/outputs/apk/debug/app-debug.apk'
    marker = repo / 'port/android/app/build/halo_app_id_suffix'
    previous = marker.read_text() if marker.is_file() else None
    if previous != suffix:
        apk.unlink(missing_ok=True)
    run(['ninja', 'android_apk'])
    if not apk.is_file():
        fail(f'ninja android_apk succeeded but APK is missing: {apk}')
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(suffix)
    print(f'APK: {apk}')
else:
    print('Output: ' + str(repo / {'web': 'build/web/site', 'windows': 'build/windows/halo.exe', 'linux': 'build/linux/halo'}[TARGET]))
PY
