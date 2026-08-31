#!/usr/bin/env bash
# Arrange dist/CocoaMojo into the versioned layout an installer copies.
#
#   ./tools/make-payload.sh                 -> dist/payload
#   PAYLOAD_DIR=/tmp/p ./tools/make-payload.sh
#   VERSION=2026.08.29 ./tools/make-payload.sh
#
# The layout is the installed shape, one level up: whatever is here lands
# under /Applications/Roast unchanged, so what an installer does is a copy
# and a symlink rather than a rearrangement. A shape that changes in
# transit is a shape nobody can check on either side.
#
#     payload/
#       VERSION                  what the installer names the directory
#       CocoaMojo/               the toolchain, to become <version>/
#       Roast.app                if one has been built
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# This repository builds the installer; the toolchain it packages is built
# in the MojoCocoa checkout beside it. MOJOCOCOA points at that checkout.
MOJOCOCOA="${MOJOCOCOA:-$(cd "$ROOT/../MojoCocoa" 2>/dev/null && pwd || true)}"
[ -n "$MOJOCOCOA" ] && [ -d "$MOJOCOCOA/tools" ] || {
  echo "no MojoCocoa checkout: set MOJOCOCOA=/path/to/MojoCocoa" >&2
  exit 1
}
# The distribution to package. Named rather than assumed, because the Intel
# fork builds dist/MojoMacX64 from the same scripts -- one variable rather
# than a second copy of this file.
D="${DIST_DIR:-$MOJOCOCOA/dist/CocoaMojo}"
OUT="${PAYLOAD_DIR:-$ROOT/dist/payload}"
VER="${VERSION:-$(date +%Y.%m.%d)}"

[ -x "$D/bin/cocoamojo" ] || {
  echo "no distribution at $D -- run ./tools/make-dist.sh in MojoCocoa first"
  exit 1
}

echo "== payload $VER =="
rm -rf "$OUT"
mkdir -p "$OUT"
printf '%s\n' "$VER" > "$OUT/VERSION"

# include/ is 172 MB of LLVM headers for building out-of-tree C++ against
# the compiler. An installation is for writing Mojo, not for that.
# share/cocoa.sqlite is left out on purpose: 343 MB of the payload, and the
# installer generates a better one -- built from the SDK on the machine it
# lands on rather than the machine that cut the release.
# The exclusion is ANCHORED. An rsync pattern with no leading slash matches
# at every depth, so a bare 'include/' also took Python.framework's own
# include/python3.14 -- leaving a dangling Headers symlink and no Python.h,
# which breaks pip install of anything with a C extension on the machine it
# lands on. Only the toolchain's own headers are meant to go.
rsync -a --delete --delete-excluded --exclude '/include/' \
      --exclude '.roast.log' --exclude '/share/cocoa.sqlite' \
      --exclude '__pycache__/' \
      --exclude '/share/cocoakb/cocoa.sqlite' \
      "$D/" "$OUT/CocoaMojo/"
echo "   toolchain $(du -sh "$OUT/CocoaMojo" | cut -f1) (include/ left out)"

# The flavor rides in the payload so the installer can hold it to account.
# toolchain-* EXCLUDES Roast.app even when one exists on disk: the app is
# compiled by Mojo, Mojo targets the build host's own CPU, and a Xeon-built
# Roast.app inside the "portable" image is exactly the AVX-512 stowaway the
# v3 flavor exists to keep out.
FLAVOR="${FLAVOR:-full}"
printf '%s\n' "$FLAVOR" > "$OUT/FLAVOR"
case "$FLAVOR" in
  toolchain*)
    rm -rf "$OUT/Roast.app"
    echo "   Roast.app excluded ($FLAVOR flavor: no host-native Mojo code ships)"
    ;;
  *)
    if [ -d "$MOJOCOCOA/dist/Roast.app" ]; then
      rsync -a --delete "$MOJOCOCOA/dist/Roast.app/" "$OUT/Roast.app/"
      echo "   Roast.app $(du -sh "$OUT/Roast.app" | cut -f1)"
    else
      echo "   (no Roast.app yet -- build one with ./tools/make-app.sh)"
    fi
    ;;
esac

# The count the signer must account for. Written here, checked there: a
# payload that gained or lost a Mach-O between assembly and signing is a
# notarization failure an hour later, reported as something inscrutable.
# `set -e` off for the walk: `file | grep -q` returns non-zero for every
# script and text file it steps over, which is not a failure of the walk.
set +e
find "$OUT" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) \
  -print0 2>/dev/null | while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then printf '%s\n' "${f#$OUT/}"; fi
  done | sort > "$OUT/MACHO-MANIFEST"
set -e
echo "   $(wc -l < "$OUT/MACHO-MANIFEST" | tr -d ' ') Mach-O files to sign"

echo
echo "$OUT ($(du -sh "$OUT" | cut -f1))"
echo "  installs as /Applications/Roast/CocoaMojo/$VER"
