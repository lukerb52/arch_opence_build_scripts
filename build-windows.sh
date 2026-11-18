#!/bin/sh
# build-windows.sh [configure.py's options]: the windows build, cross-compiled
# (build-env.sh)
set -e
. "$(dirname "$(readlink -f "$0")")/build-env.sh"

# clang, lld and llvm-rc; rust for cargo, which installs xwin
pacman_needed clang lld llvm rustup

# Not packaged: xwin, which downloads the x86 MSVC libraries and the Windows
# SDK to XWIN_DIR (Microsoft's licence: it asks you to accept it). The
# CARGO_HOME of your profile puts it in ~/.local/share/cargo/bin.
#   cargo install --locked xwin
#   ~/.local/share/cargo/bin/xwin --accept-license --arch x86 \
#       splat --output ~/.local/share/xwin

configure "$@"
ninja windows
echo "Game: $GULCHCE_DIR/build/windows/halo.exe (with SDL3.dll beside it)"
