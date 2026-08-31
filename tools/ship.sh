#!/bin/bash
# Ship a release, end to end, the same way every time.
#
#   ./tools/ship.sh                    build, notarize, install, verify
#   ./tools/ship.sh --no-notarize      everything but the round trip to Apple
#   ./tools/ship.sh --no-install       cut the image, do not touch /Applications
#   ./tools/ship.sh --dirty            proceed with uncommitted changes
#   ./tools/ship.sh --keep-dist        do not rebuild the toolchain (fast retry)
#
# There is a make-dist, a make-app, a make-payload, a sign-payload, a
# make-release and a check-release, in two repositories. Getting a release
# right means running them in the right order, from the right directories,
# against artifacts that are actually current -- and every mistake made
# while building this thing was a step done by hand, out of order, or
# against something stale:
#
#   * a binary copied into a notarized .app and re-signed ad-hoc, which
#     hung in dyld before the app finished launching
#   * an installer run from a DMG that was still mounted from an earlier
#     build, so the thing under test was last week's
#   * a binary written to Contents/MacOS/roast when the bundle wanted
#     Contents/MacOS/Roast, so the OLD executable answered and looked fine
#   * a release cut from a dist/CocoaMojo that predated the source change
#     being released
#
# None of those are interesting problems. This script exists so nobody has
# to be interesting about them again.
set -uo pipefail

cd "$(dirname "$0")/.."
INSTALLER_ROOT="$PWD"
MOJOCOCOA="${MOJOCOCOA:-$(cd "$INSTALLER_ROOT/../MojoCocoa" 2>/dev/null && pwd || true)}"

NOTARIZE=1; INSTALL=1; ALLOW_DIRTY=0; KEEP_DIST=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --no-install)  INSTALL=0 ;;
    --dirty)       ALLOW_DIRTY=1 ;;
    --keep-dist)   KEEP_DIST=1 ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ship: unknown argument $arg" >&2; exit 64 ;;
  esac
done

step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
note() { printf "   %s\n" "$1"; }
die()  { printf "\n\033[31mship: %s\033[0m\n" "$1" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
# Everything that makes a release wrong is cheaper to catch now than after
# a twenty-minute notarization round trip.

step "preflight"
[ -n "$MOJOCOCOA" ] && [ -d "$MOJOCOCOA/ide" ] \
  || die "no MojoCocoa checkout -- set MOJOCOCOA=/path/to/MojoCocoa"
note "toolchain source: $MOJOCOCOA"

# A release is a claim about a commit. If the tree is dirty the claim is
# unverifiable: the artifact contains something no one can check out again.
for repo in "$MOJOCOCOA" "$INSTALLER_ROOT"; do
  dirty="$(cd "$repo" && git status --porcelain 2>/dev/null | head -5)"
  if [ -n "$dirty" ]; then
    if [ "$ALLOW_DIRTY" = 1 ]; then
      note "$(basename "$repo"): uncommitted changes, proceeding (--dirty)"
    else
      echo "$dirty" | sed 's/^/     /'
      die "$(basename "$repo") has uncommitted changes -- commit them, or pass --dirty"
    fi
  else
    note "$(basename "$repo"): clean at $(cd "$repo" && git rev-parse --short HEAD)"
  fi
done

[ -f "$INSTALLER_ROOT/tools/signing.local.sh" ] \
  || die "no tools/signing.local.sh -- copy signing.local.sh.example and fill it in"
# shellcheck disable=SC1091
. "$INSTALLER_ROOT/tools/signing.local.sh"
[ -n "${SIGN_ID:-}" ] || die "SIGN_ID is empty in tools/signing.local.sh"
if [ "$NOTARIZE" = 1 ]; then
  [ -n "${NOTARY_PROFILE:-}" ] \
    || die "NOTARY_PROFILE is empty -- set it, or pass --no-notarize"
fi
# Test and report the SAME listing: running security twice can announce an
# identity as missing directly above a listing that contains it.
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
case "$identities" in
  *"$SIGN_ID"*) note "identity present in the keychain" ;;
  *) printf '%s\n' "$identities" | sed 's/^/     /'
     die "SIGN_ID is not in the keychain (if it IS listed, it was locked)" ;;
esac

xcode-select -p >/dev/null 2>&1 \
  || die "no Command Line Tools -- the build needs the macOS SDK"
note "command line tools: $(xcode-select -p)"

# ── Build ───────────────────────────────────────────────────────────────────

step "toolchain"
if [ "$KEEP_DIST" = 1 ]; then
  [ -x "$MOJOCOCOA/dist/CocoaMojo/bin/cocoamojo" ] \
    || die "--keep-dist, but there is no dist/CocoaMojo to keep"
  note "kept: $(du -sh "$MOJOCOCOA/dist/CocoaMojo" | cut -f1) (--keep-dist)"
else
  # Rebuilt, always, unless told otherwise. A release cut from a stale
  # dist ships source that is not the source you just committed, and the
  # artifact looks perfect while being wrong.
  ( cd "$MOJOCOCOA" && ./tools/make-dist.sh ) || die "make-dist failed"
fi

# The IDE binary in the dist must come from the CURRENT source. make-dist
# builds it; this proves it rather than assuming, because a hand-copied
# roast is exactly the mistake this script exists to prevent.
if [ -n "$(find "$MOJOCOCOA/ide" -name '*.mojo' -newer "$MOJOCOCOA/dist/CocoaMojo/bin/roast" 2>/dev/null | head -1)" ]; then
  die "ide/ is newer than dist/CocoaMojo/bin/roast -- rerun without --keep-dist"
fi
note "IDE binary is newer than every ide/*.mojo"

step "release"
rel_args=""
[ "$NOTARIZE" = 0 ] && rel_args="--no-notarize"
# shellcheck disable=SC2086
"$INSTALLER_ROOT/tools/make-release.sh" $rel_args || die "make-release failed"

VER="$(cat "$MOJOCOCOA/dist/CocoaMojo/VERSION" 2>/dev/null \
       || date +%Y.%m.%d)"
DMG="$INSTALLER_ROOT/dist/Roast-$VER.dmg"
[ -f "$DMG" ] || die "no image at $DMG"

# ── Install and verify ──────────────────────────────────────────────────────

if [ "$INSTALL" = 0 ]; then
  step "done"
  note "$DMG"
  note "not installed (--no-install); verify with ./tools/check-release.sh"
  exit 0
fi

step "install from the image"
# Detach EVERY Roast volume first. Two images can mount under names that
# differ by a trailing " 1", and picking one with a glob is how an install
# gets tested against an older build that happened to sort first.
hdiutil info 2>/dev/null | grep '/Volumes/Roast' \
  | sed 's|.*\(/Volumes/Roast.*\)|\1|' | while IFS= read -r stale; do
      hdiutil detach "$stale" -force -quiet 2>/dev/null \
        && note "detached a stale mount: $stale"
    done

plist="$(mktemp)"
hdiutil attach "$DMG" -nobrowse -plist > "$plist" 2>/dev/null \
  || die "could not mount $DMG"
MNT="$(python3 -c "
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
print([e['mount-point'] for e in d['system-entities'] if e.get('mount-point')][0])
" "$plist")"
rm -f "$plist"
[ -n "$MNT" ] || die "mounted, but could not find the mount point"
note "mounted: $MNT"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true' EXIT

# Provenance, before anything is installed from it: this must be the image
# just built, not one that happened to be lying around.
[ -x "$MNT/payload/CocoaMojo/Python/Python.framework/Versions/Current/bin/python3" ] \
  || die "the image does not carry a Python -- the database is always built with it"
[ -x "$MNT/payload/CocoaMojo/bin/python3" ] \
  || die "the image has a Python framework but no bin/python3 wrapper"
note "payload carries the packed interpreter and its wrapper"

verdict="$(spctl -a -vvv -t exec "$MNT/Install Roast.app" 2>&1 | grep -m1 source= || true)"
if [ "$NOTARIZE" = 1 ]; then
  case "$verdict" in
    *"Notarized Developer ID"*) note "gatekeeper: $verdict" ;;
    *) die "the installer is not notarized: ${verdict:-rejected}" ;;
  esac
else
  note "gatekeeper: ${verdict:-unsigned (--no-notarize)}"
fi

# Quit a running Roast so the copy is not replacing a live binary. NEVER
# copy a binary into an installed .app by hand: re-signing a notarized
# bundle in place leaves it hanging in dyld. Install, or do not.
pkill -f "Roast.app/Contents/MacOS/Roast" 2>/dev/null && note "quit a running Roast"
sleep 1

"$MNT/Install Roast.app/Contents/MacOS/Install Roast" \
  --install --payload "$MNT/payload" 2>&1 | sed 's/^/   /' \
  || die "the installer failed"

hdiutil detach "$MNT" -quiet 2>/dev/null; trap - EXIT

step "verify the installation"
"$INSTALLER_ROOT/tools/check-release.sh" || die "check-release found problems"

step "shipped"
note "$DMG"
note "installed at /Applications/Roast"
note "drive the running app too: ROAST_CHECK_AGENT=1 ./tools/check-release.sh"
