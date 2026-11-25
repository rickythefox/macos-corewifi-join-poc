#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
# Installed next to CoreWiFi Join.app by build.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
umask 077
scratch="$(mktemp -d "${TMPDIR:-/tmp}/corewifi-join.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Direct exec inherits the caller's privacy attribution. LaunchServices does not.
# -W can report a PID lookup error for fast-exiting apps; the app's result file
# distinguishes that race from a launch failure and preserves the actual exit code.
open -n -W --stdout "$scratch/stdout" --stderr "$scratch/stderr" \
    "$root/CoreWiFi Join.app" --args --result-file "$scratch/result" "$@" \
    2>"$scratch/launcher-error" || true
if [ -f "$scratch/stdout" ]; then cat "$scratch/stdout"; fi
if [ -f "$scratch/stderr" ]; then cat "$scratch/stderr" >&2; fi
if [ ! -f "$scratch/result" ]; then
    cat "$scratch/launcher-error" >&2
    echo 'App did not return an exit status (launch failure or process termination).' >&2
    exit 1
fi
read -r result < "$scratch/result"
case "$result" in
    0|1|2) exit "$result" ;;
    *) echo 'Invalid exit status.' >&2; exit 1 ;;
esac
