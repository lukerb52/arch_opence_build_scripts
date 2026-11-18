# GulchCE build wrappers

POSIX shell entry points with a shared Python 3 driver. Run from any directory,
including through symlinks; paths containing spaces are supported. Python 3.8+
is the bootstrap dependency (`PYTHON` can select its executable). No package
manager runs unless explicitly requested, except Android's sdkmanager, which installs
missing required SDK components during normal builds. Licenses are reviewed through
normal interactive prompts, never auto-accepted. Normal GulchCE configure/build steps can download their own
SDL/Gradle dependencies; `--check` never runs configure, Ninja or installers.

## Usage

```sh
./build-web.sh --help
./build-web.sh --check
./build-linux.sh --release --lto=off
GULCHCE_DIR='/work/My GulchCE' ./build-web.sh --web-emcc '/opt/My SDK/upstream/emscripten/emcc' --release
./build-windows.sh --check --windows-vctools-dir '/opt/MSVC/14.40' --windows-sdk-dir '/opt/Windows Kits/10'
ANDROID_HOME="$HOME/Android/Sdk" JAVA_HOME=/usr/lib/jvm/java-21-openjdk HALO_BETA=1 ./build-android.sh --release
./build-linux.sh --install-deps --release
```

All four entry points accept:

- `--help`, `-h`: help without needing a checkout or toolchains.
- `--check`: read-only prerequisite discovery/validation. Compiler version probes
  may run, but there is no configuration, build, installation or wrapper file write.
  With `--install-deps`, check still wins; missing tools are reported, not installed.
- `--install-deps`: opt-in `pacman -S --needed` on Arch-family hosts only (sudo
  unless root). No AUR helper is invoked. Unsupported hosts get an actionable error.
- Other arguments pass through to the actual `configure.py`, preserving argument
  boundaries and order, including `--release`, `--lto=off`, `--compiler-launcher`,
  profiling flags, and explicit tool overrides. `--flag=value` is supported.
  Relative tool/SDK paths resolve against the invoking directory before changing
  directory; paths used by other configure flags retain upstream semantics.
  `--` ends wrapper option processing. Unrecognized configure flags are diagnosed
  by upstream configure during a normal build, not by `--check`.

Repository selection: explicit `GULCHCE_DIR` (a bad override is an error), then
current directory/ancestors, then script directory/ancestors, then `GulchCE`
siblings of those locations. The chosen directory must have `configure.py`;
automatic discovery additionally requires `tools/`. Builds execute there.
Wrappers only add their own target's flags. GulchCE itself generates one shared
`build.ninja` containing available targets; do not run these wrappers concurrently
against one checkout. They do not prevent you passing other targets' flags explicitly.

## Web

Requires Ninja and a working Emscripten compiler. Discovery priority:

1. `--web-emcc BINARY`, then `EMCC`.
2. `emcc` on `PATH`.
3. `EMSDK_DIR`, `EMSDK`, then `~/emsdk`, `~/.local/src/emsdk`, `/opt/emsdk`
   (`upstream/emscripten/emcc` under each root).

Runs `emcc --version` to verify the selection. Only if that fails, and an
associated `emsdk_env.sh` and Bash are available, sources that file in Bash and
imports its exports, then verifies again. The wrapper itself remains `/bin/sh`
compatible; an emsdk environment script is not assumed POSIX-compatible. No
Windows packages, Rust, Android SDK or host Clang are needed for this target.
GulchCE CI currently uses Emscripten **6.0.10**; provision/activate a matching
emsdk yourself for reproducibility. The wrapper does not enforce a version.
Output: `build/web/site/`. Serve it using upstream `tools/web_serve.py`.

## Android

Builds `ninja android`, then `ninja android_apk`. Requires Ninja, host Clang
(`--android-guest-cc BINARY` override), `ld.lld`, CMake, an NDK and JDK 17+
(Java 21 recommended for current command-line tools).

SDK priority: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `port/android/local.properties`
`sdk.dir` (Java properties escaped spaces supported), then `~/Android/Sdk`,
`~/Android/sdk`, `~/Library/Android/sdk`, `/opt/android-sdk`, `/usr/lib/android-sdk`.
The selected SDK is exported as **both** `ANDROID_HOME` and `ANDROID_SDK_ROOT`
for Gradle. Invalid explicit overrides are not silently replaced.

NDK priority: `--android-ndk DIR`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`,
`ANDROID_NDK`, highest numerically versioned directory under the SDK's `ndk/`,
then `ndk-bundle`. No fixed NDK version is imposed. Its CMake toolchain file
and prebuilt Clang must exist; `ANDROID_NDK_HOME` and `--android-ndk` are set.
Use the upstream-tested NDK for reproducibility (the WSL provisioning script
currently pins 27.2.12479018); newer NDK compatibility is not guaranteed.

JDK selection: explicit `JAVA_HOME`, otherwise `JAVA_17_HOME`, otherwise common
JDK directories (preferring Java 21, then 17) and the JDK containing `javac` on
`PATH`. Both `java` and `javac` must report the same major version, at least 17.
An invalid explicit override is an error. `JAVA_HOME` and `PATH` are preserved
for sdkmanager and both Ninja steps. Gradle 9.7.1/AGP 9.4 support Java 21;
recent Android command-line tools may require it even though Gradle's minimum
is Java 17. Set `JAVA_HOME` to a compatible JDK (recommended: 21); the launcher
never silently downgrades an explicit override to Java 17.

Preflight reads the project's `compileSdk` and optional `buildToolsVersion`
from `port/android/app/build.gradle`; for current AGP 9.4 the Build Tools
fallback is 36.0.0. Current requirements are `platforms;android-35`,
`build-tools;36.0.0` and `platform-tools`. Normal Android builds install **only
missing components**, then verify their required files before configure/Ninja.
`--check` only reports missing components and never invokes sdkmanager, sudo,
package managers or builds (even with `--install-deps`). Other targets are unchanged.

sdkmanager is discovered on `PATH`, then under the selected SDK in
`cmdline-tools/latest/bin`, versioned `cmdline-tools/*/bin` (newest first), or
`tools/bin`. All invocations use `--sdk_root` matching exported `ANDROID_HOME`.
License prompts use normal interactive input; the launcher never pipes `yes`,
runs `--licenses`, or auto-accepts terms. On failure or incomplete installation,
the build aborts before configure/Ninja. For unattended builds, provision missing
packages and review licenses interactively first. Install failures report Java,
license and permission remedies.

For root-owned, non-writable SDK directories (such as `/opt/android-sdk`), only
sdkmanager is run through sudo, with an explanatory message and the selected
Java/SDK environment. Configure, Ninja and Gradle remain unprivileged.
`--install-deps` remains optional for Arch repository packages; no AUR helper
is invoked. If sdkmanager is missing, install `android-sdk-cmdline-tools-latest`
manually from the AUR, or Google's command-line tools under the selected SDK,
then rerun. The launcher does not download command-line tools itself.

`HALO_BETA=1` sets `ORG_GRADLE_PROJECT_haloAppIdSuffix=.beta` (Halo Beta,
`com.halo.decomp.beta`); `HALO_BETA=0` sets the empty suffix. Other values are
errors. If unset, an existing Gradle environment suffix is preserved (only empty
or `.beta` allowed). Otherwise an interactive build asks whether to build Halo
Beta (default: no), reading `/dev/tty` because the Python dispatcher consumes
stdin as a heredoc. Without a controlling terminal, the launcher explicitly
reports that it defaults to stable. Set `HALO_BETA=0` or `HALO_BETA=1` to bypass
the prompt; `--check` never prompts or packages an APK.
When the suffix changes, delete only the stale APK before packaging; record the
suffix only after packaging succeeds and the APK exists. The marker is
`port/android/app/build/halo_app_id_suffix`. Upstream signing/build-number
variables remain untouched. APK: `port/android/app/build/outputs/apk/debug/app-debug.apk`.

## Windows cross build

Requires Clang (`--windows-cc BINARY`), `lld-link`, `llvm-rc`, Ninja and
**x86** MSVC CRT and Windows SDK headers/libraries. Normal builds provision a
missing default toolchain as described below. No Rust, Cargo or xwin command
is required to use an existing toolchain. Configure receives `--windows-cross`.

Explicit `--windows-vctools-dir DIR` / `--windows-sdk-dir DIR` take precedence over
`VCToolsInstallDir` / `WindowsSdkDir`. VC must point at a versioned tools folder
containing `include/` and `lib/x86/`; SDK at its root containing `Include/` and
`Lib/` with matching version subdirectories. Case-insensitive top-level names
are supported as in upstream's Windows tooling. Invalid explicit paths fail
with guidance; they are never replaced by a downloaded toolchain.

Otherwise `XWIN_DIR` (default `~/.local/share/xwin`) supports:

- Ordinary xwin `crt/include`, `crt/lib/x86`, `sdk/include/{um,ucrt,shared}`,
  `sdk/lib/{um,ucrt}/x86` (lowercase, unversioned layout).
- Legacy `VC/Tools/MSVC/<version>` and `Windows Kits/10/Include/<version>` /
  `Lib/<version>`; the newest numeric version is selected.

GulchCE currently expects a versioned SDK. For flat xwin only, a tiny symlink
view is generated at `build/halo-toolchains/windows-sdk/{Include,Lib}/10.0.0`
inside the **build checkout**, not in the SDK. `--check` validates the original
layout without creating this view. The SDK adapter flag must occur last for
upstream argparse; all other pass-through order is preserved.

When the default toolchain is absent (or its directory is empty), a normal
`sh build-windows.sh` discovers `xwin` on `PATH`, `$CARGO_HOME/bin`,
`~/.cargo/bin`, then `~/.local/share/cargo/bin`. If missing, it discovers Cargo
in the same places and announces and runs `cargo install --locked xwin`.
Then it announces Microsoft downloads and runs
`xwin --arch x86 splat --output STAGING/toolchain`, validates x86 directories,
and renames the result into `XWIN_DIR`. Download caches/staging are temporary
and cleaned on failure. Existing nonempty incomplete roots are **rejected**,
not deleted or merged: repair them manually or choose a new empty, dedicated
`XWIN_DIR`. Do not point it at a general-purpose directory or symlink.

Microsoft license acceptance is **never implicit**. On an interactive terminal,
xwin receives `/dev/tty` as stdin (the dispatcher itself uses a Python heredoc),
so review and affirm its license prompts. Without a controlling terminal,
provisioning fails before downloads unless you have reviewed the Microsoft
licenses and explicitly opted in with `XWIN_ACCEPT_LICENSE=1`, e.g.:

```sh
XWIN_ACCEPT_LICENSE=1 sh build-windows.sh
```

`--check` never prompts, installs Cargo/xwin, downloads, provisions or writes an
SDK adapter, even with `--install-deps` or license consent. Missing Cargo gives
instructions to use `--install-deps` on Arch or install Cargo/provision xwin
manually. No rustup bootstrap or toolchain selection is forced; optional Arch
package installation skips `rust` when Cargo or rustup already exists.
See [xwin usage and installation](https://github.com/Jake-Shadle/xwin#usage).
Output: `build/windows/halo.exe` with upstream's SDL3 DLL beside it.

## Linux and optional Arch packages

This is a **32-bit x86 Linux** build, not a universal native-architecture port.
The wrapper rejects non-x86 or non-Linux hosts; a 64-bit x86 host needs 32-bit
runtime/development libraries. Requires Ninja, Clang (`--linux-cc BINARY`) and
`ld.lld`; command preflight does not prove multilib linking works. Arch needs
`[multilib]` enabled (Artix equivalent: `[lib32]`); runtime OpenGL, sound and
window-system libraries are also needed to play. Output: `build/linux/halo`.

`--install-deps` package sets (plus `python ninja git`):

- Linux: `clang lld llvm lib32-glibc lib32-sdl3`.
- Windows: `clang lld llvm`; also `rust` only if neither Cargo nor rustup is
  already installed (normal-build xwin provisioning is described above).
- Android: `clang lld llvm cmake jdk21-openjdk` (command-line tools and NDK
  provisioning remain manual; required platform/Build Tools/platform-tools are
  installed automatically by an already-installed sdkmanager).
- Web: no additional repository packages; provision emsdk manually.

Other hosts must install equivalents manually; Arch installation is convenience,
not a promise that every host/SDK/architecture can build every target.

## Verification and sources

```sh
python3 -m unittest discover -s tests -v
for script in build-*.sh; do sh -n "$script" || exit; done
shellcheck build-*.sh  # optional
```

Tests use only the Python standard library and mock Python dispatch, Ninja,
compilers, SDK files and Java; no real package installation or compilation.
They use temporary directories inside this repository to support sandboxes
that disallow execution in `/tmp`, and clean them automatically.

Verified against the adjacent GulchCE `configure.py`, `tools/android_build.py`,
`tools/windows_cross_build.py`, `tools/web_build.py`, platform READMEs,
`port/android/app/build.gradle`, `port/android/build.gradle`,
`tools/wsl_setup_android.sh` and `.github/workflows/build.yml`.
AGP compatibility: https://developer.android.com/build/releases/agp-9-4-0-release-notes
