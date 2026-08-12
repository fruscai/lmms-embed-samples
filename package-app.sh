#!/bin/bash
# Package the patched LMMS as its own app and install it.
# Name and identifier come from LMMS_EMBED_NAME / LMMS_EMBED_ID, so the same
# script builds each branch side by side without them overwriting each other.
#
# cpack does the real work, but it fails at the very end looking for dmgbuild.
# That failure is expected and harmless here: the .app is finished and signed
# before that step runs, and we only want the app.
#
# The rest of this script fixes what macdeployqt leaves broken when LMMS is
# built with Homebrew LLVM instead of Apple Clang. Without it the app does not
# launch at all.
set -e

SRCDIR="${1:-$HOME/Downloads/lmms-src}"
BUILD="$SRCDIR/build"
# Override with LMMS_EMBED_DEST to install somewhere else, an external drive
# included. Anywhere works: the bundle carries its own libraries and does not
# care where it sits.
#
# Keep the destination in its own variable rather than inline. An apostrophe in
# the path is a syntax error inside a ${VAR:-default} expansion, even in double
# quotes, which is easy to hit on a drive named after somebody.
APP_NAME="${LMMS_EMBED_NAME:-LMMS FULL EMBED Branch V2}"
# Its own identifier per build, so Launch Services lists each one separately
# instead of them fighting over the .mmpz association.
BUNDLE_ID="${LMMS_EMBED_ID:-io.lmms.embedbranch.v2}"
DEFAULT_DEST="/Applications/$APP_NAME.app"
DEST="${LMMS_EMBED_DEST:-$DEFAULT_DEST}"
LLVM=/opt/homebrew/opt/llvm/lib

echo "==> cpack (the dmgbuild error at the end is expected)"
cd "$BUILD"
cpack > /tmp/lmms_cpack.log 2>&1 || true

STAGED=$(find "$BUILD/_CPack_Packages" -maxdepth 6 -name "LMMS.app" -print -quit)
if [ -z "$STAGED" ]; then
	echo "cpack produced no LMMS.app, see /tmp/lmms_cpack.log" >&2
	exit 1
fi

echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R "$STAGED" "$DEST"

echo "==> renaming the bundle"
P="$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$P"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$P" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$P"

echo "==> bundling the LLVM runtime macdeployqt misses"
F="$DEST/Contents/Frameworks"
# libc++.1.dylib finds libunwind through @loader_path/../unwind, which is correct in
# Homebrew's layout and wrong once macdeployqt moves libc++ into Frameworks. The app
# will not start without this.
# libc++abi and libunwind are both needed. Miss either one and the app does not
# start, with an error naming only the one it happened to look for first.
for lib in "$LLVM/c++/libc++abi.1.dylib" "$LLVM/unwind/libunwind.1.dylib"; do
	name=$(basename "$lib")
	cp -L "$lib" "$F/"
	chmod u+w "$F/$name"
	install_name_tool -id "@rpath/$name" "$F/$name"
	echo "   bundled $name"
done

SHARP=$(find -L /opt/homebrew/opt/webp/lib -name "libsharpyuv.0.dylib" -print -quit 2>/dev/null || true)
if [ -n "$SHARP" ]; then
	cp -L "$SHARP" "$F/"
	chmod u+w "$F/libsharpyuv.0.dylib"
	install_name_tool -id "@rpath/libsharpyuv.0.dylib" "$F/libsharpyuv.0.dylib"
fi

echo "==> pointing the app at its own libraries"
# Homebrew sits ahead of the bundle in the search order, so without this the app
# silently loads libsamplerate and friends from /opt/homebrew and only runs on a
# machine that has them.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$DEST/Contents/MacOS/lmms" 2>/dev/null || true
install_name_tool -delete_rpath "$LLVM/c++" "$DEST/Contents/MacOS/lmms" 2>/dev/null || true
install_name_tool -delete_rpath /opt/homebrew/lib "$DEST/Contents/MacOS/lmms" 2>/dev/null || true

echo "==> signing"
codesign --force --deep --sign - "$DEST" 2>&1 | tail -1
codesign --verify --deep "$DEST"

echo "==> checking nothing resolves outside the bundle"
LEAKS=$(DYLD_PRINT_LIBRARIES=1 "$DEST/Contents/MacOS/lmms" --version 2>&1 | grep -oE "/opt/homebrew[^ ]*" | sort -u || true)
if [ -n "$LEAKS" ]; then
	echo "STILL LOADING FROM HOMEBREW:"
	echo "$LEAKS"
else
	echo "clean, nothing loads from /opt/homebrew"
fi

# JACK is the deliberate exception. LMMS dlopens it through weakjack, so a machine
# without JACK runs fine and simply does not offer that audio backend.

"$DEST/Contents/MacOS/lmms" --version 2>&1 | head -2
echo "==> done: $DEST"
