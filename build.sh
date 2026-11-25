#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Richard Ginzburg
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
out="$root/.build"
app="$out/CoreWiFi Join.app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Info.plist" "$app/Contents/Info.plist"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -O2 \
    -framework Foundation -framework CoreWLAN -framework CoreLocation -framework AppKit \
    "$root/corewifi-join.m" -o "$app/Contents/MacOS/corewifi-join"
# A stable identity keeps Location approval across rebuilds. Ad-hoc ("-") works,
# but macOS forgets the approval every time the binary changes.
identity="${SIGNING_IDENTITY:--}"
if [ "$identity" = "-" ]; then
    echo "Signing ad-hoc; set SIGNING_IDENTITY to keep Location approval across rebuilds." >&2
fi
codesign --force --sign "$identity" "$app"
# LaunchServices gives the app its own Location permission attribution.
rm -f "$out/corewifi-join"
cp "$root/launcher.sh" "$out/corewifi-join"
chmod +x "$out/corewifi-join"
printf '%s\n' "$out/corewifi-join"
