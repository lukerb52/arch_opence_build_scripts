#!/bin/sh
# build-web.sh [configure.py's options]: the web build (build-env.sh)
set -e
. "$(dirname "$(readlink -f "$0")")/build-env.sh"

# Not packaged: Emscripten 6.0.10 exactly, from emsdk (Arch's emscripten
# package is another version), in EMSDK_DIR:
#   git clone https://github.com/emscripten-core/emsdk.git ~/.local/src/emsdk
#   ~/.local/src/emsdk/emsdk install 6.0.10
#   ~/.local/src/emsdk/emsdk activate 6.0.10

configure "$@"
ninja web
echo "Site: $GULCHCE_DIR/build/web/site/"
echo "Try it: python $GULCHCE_DIR/tools/web_serve.py $GULCHCE_DIR/build/web/site  (http://localhost:8000/)"
