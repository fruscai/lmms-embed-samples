#!/bin/bash
# Package the patched LMMS as "LMMS 1.3 Embed Branch.app" and install it.
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
DEST="/Applications/LMMS 1.3 Embed Branch.app"
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
/usr/libexec/PlistBuddy -c "Set :CFBundleName LMMS 1.3 Embed Branch" "$P"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string LMMS 1.3 Embed Branch" "$P" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName LMMS 1.3 Embed Branch" "$P"
# Its own identifier, so Launch Services lists it separately from other LMMS installs
# instead of the two fighting over the .mmpz association.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.lmms.embedbranch" "$P"

echo "==> bundling the LLVM runtime macdeployqt misses"
F="$DEST/Contents/Frameworks"
# libc++.1.dylib finds libunwind through @loader_path/../unwind, which is correct in
# Homebrew's layout and wrong once macdeployqt moves libc++ into Frameworks. The app
# will not start without this.
cp -L "$LLVM/unwind/libunwind.1.dylib" "$F/"
chmod u+w "$F/libunwind.1.dylib"
install_name_tool -id "@rpath/libunwind.1.dylib" "$F/libunwind.1.dylib"

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
