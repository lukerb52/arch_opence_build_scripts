# build-env.sh: where this machine's repository and toolchains are, sourced by
# build-linux.sh, build-windows.sh, build-android.sh and build-web.sh, which
# keep it beside them (links to them work too) and run from any directory.
# Each of them installs its packages (pacman and the AUR, --needed: nothing
# when they are there), configures the one build.ninja with every toolchain
# (the arguments given to the script are configure.py's too: --release,
# --lto=off, ...) and builds its target. A path set in the environment is
# used instead of these.

GULCHCE_DIR=${GULCHCE_DIR:-$HOME/.local/src/halo/GulchCE}
EMSDK_DIR=${EMSDK_DIR:-$HOME/.local/src/emsdk}
XWIN_DIR=${XWIN_DIR:-$HOME/.local/share/xwin}
ANDROID_HOME=${ANDROID_HOME:-/opt/android-sdk}
ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/30.0.16248370}
JAVA_17_HOME=${JAVA_17_HOME:-/usr/lib/jvm/java-17-openjdk}
export ANDROID_HOME ANDROID_NDK_HOME

# packages from Arch's repositories (the lib32 ones are in [multilib],
# enabled in /etc/pacman.conf; on Artix, [lib32])
pacman_needed() {
	sudo pacman -S --needed "$@"
}
# packages from the AUR
aur_needed() {
	yay -S --needed "$@"
}

# what every build needs: configure.py and ninja
pacman_needed python ninja git

cd "$GULCHCE_DIR" || { echo "no repository at $GULCHCE_DIR (set GULCHCE_DIR)" >&2; exit 1; }

# the newest MSVC tools xwin splatted
vctools=$(ls -d "$XWIN_DIR"/VC/Tools/MSVC/*/ 2>/dev/null | sort -V | tail -n 1)
vctools=${vctools%/}

configure() {
	python configure.py \
		--web-emcc "$EMSDK_DIR/upstream/emscripten/emcc" \
		--android-ndk "$ANDROID_NDK_HOME" \
		--windows-cross \
		--windows-vctools-dir "$vctools" \
		--windows-sdk-dir "$XWIN_DIR/Windows Kits/10" \
		"$@"
}
