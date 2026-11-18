#!/bin/sh
set -eu
target=linux
script=${0}
while [ -L "$script" ]; do
    base=$(CDPATH='' cd -P -- "$(dirname -- "$script")" && pwd)
    link=$(readlink "$script")
    case $link in /*) script=$link ;; *) script=$base/$link ;; esac
done
script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$script")" && pwd)
. "$script_dir/build-env.sh"
