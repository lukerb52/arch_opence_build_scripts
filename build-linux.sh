#!/bin/sh
# build-linux.sh [configure.py's options]: the linux build (build-env.sh)
set -e
. "$(dirname "$(readlink -f "$0")")/build-env.sh"

# to build: clang and lld, 32-bit glibc and SDL3
pacman_needed clang lld llvm lib32-glibc lib32-sdl3
# to play it: 32-bit OpenGL, sound and X11 (and Wayland's, for SDL's own)
pacman_needed lib32-mesa lib32-pipewire lib32-libx11 lib32-libxext lib32-libxi \
	lib32-wayland lib32-libxkbcommon

configure "$@"
ninja linux
echo "Game: $GULCHCE_DIR/build/linux/halo"
