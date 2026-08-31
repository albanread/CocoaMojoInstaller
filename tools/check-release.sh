#!/bin/bash
# Test an INSTALLED release -- not a build tree.
#
#   ./tools/check-release.sh                  checks /Applications/Roast
#   ./tools/check-release.sh /path/to/Roast   checks somewhere else
#
# check-ide.sh in the MojoCocoa checkout tests the development tree, where a
# developer's environment is present and paths point at the source. This
# tests the thing a person actually receives: a signed, notarized
# installation that has to know where its own files live with no help from
# anyone's shell.
#
# The distinction is not academic. The dev tree has no user-space standard
# library, so the two disagree about where go-to-definition should land --
# and a gate that only ever ran against the dev tree could not have told
# you which answer the shipped product gives.
set -uo pipefail

ROOT="${1:-/Applications/Roast}"
TC="$ROOT/CocoaMojo/current"
# `current` is a symlink. `test -e` follows one; `find` does not, so a
# find rooted here searches nothing and reports a clean bill for a tree it
# never opened. Resolve it once, and let every check work on real paths.
TCR="$(cd "$TC" 2>/dev/null && pwd -P || echo "$TC")"
US="$HOME/Library/Application Support/Roast"
BUILD_HOST_HINT="${BUILD_HOST_HINT:-/Volumes/xb/mojo2026}"

pass=0; fail=0
ok()   { printf "  \033[32mOK\033[0m   %-22s %s\n" "$1" "${2:-}"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %-22s %s\n" "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf "  \033[33mSKIP\033[0m %-22s %s\n" "$1" "${2:-}"; }

echo "== the installation =="
if [ -d "$TC" ]; then
  ok "installed" "$ROOT"
else
  bad "installed" "nothing at $TC -- install from the disk image first"
  echo; echo "$fail failure(s)"; exit 1
fi

# ── Where files live ────────────────────────────────────────────────────────

# A relative `current` survives the folder being moved or renamed; an
# absolute one bakes in the install location, and `current` is what every
# lookup resolves through.
link="$(readlink "$ROOT/CocoaMojo/current" 2>/dev/null || true)"
case "$link" in
  "") bad "current symlink" "missing" ;;
  /*) bad "current symlink" "absolute ($link) -- breaks if the folder moves" ;;
  *)  ok  "current symlink" "relative -> $link" ;;
esac

# Everything the product resolves by path, at the path it looks for it.
missing=""
for p in bin/cocoamojo bin/cocoamojo-compiler bin/mojo-lsp-server bin/lldb-dap \
         bin/lldb share/cocoa.sqlite share/cocoakb/build.py \
         share/cocoakb/schema.sql share/examples share/ide-source \
         lib/mojo/stdlib/std lib/mojo/max lib/mojo/kernels \
         Python/Python.framework/Versions/Current/bin/python3; do
  [ -e "$TC/$p" ] || missing="$missing $p"
done
[ -z "$missing" ] && ok "toolchain layout" "15 paths present" \
                  || bad "toolchain layout" "missing:$missing"

# The app is thin and finds the toolchain by one absolute rpath. That IS the
# contract, so check it names the installed location and not a build tree.
rp="$(otool -l "$ROOT/Roast.app/Contents/MacOS/Roast" 2>/dev/null \
      | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')"
case "$rp" in
  "$ROOT/CocoaMojo/current/lib") ok "app rpath" "$rp" ;;
  "") bad "app rpath" "none -- the app cannot find the toolchain" ;;
  *)  bad "app rpath" "$rp" ;;
esac

# Nothing installed may refer to the machine that built it.
# Only where a path can actually mislead the installation: text files it
# reads or executes, and the load commands dyld resolves. A compiled
# binary also records the source paths it was built from, in debug info --
# every Mach-O on this Mac does, Apple's included -- and that is not a
# thing the installation can act on.
leaks="$(grep -rlI "$BUILD_HOST_HINT" "$TCR/bin" "$TCR/share/cocoakb" \
         "$ROOT/Roast.app" 2>/dev/null | head -5)"
macho_leaks=0
for f in "$TC/bin/cocoamojo-compiler" "$TC/bin/mojo-lsp-server" \
         "$ROOT/Roast.app/Contents/MacOS/Roast"; do
  n=$(otool -l "$f" 2>/dev/null | grep -c "$BUILD_HOST_HINT")
  macho_leaks=$((macho_leaks + n))
done
if [ -z "$leaks" ] && [ "$macho_leaks" = 0 ]; then
  ok "no build-machine paths" "scripts and load commands are clean"
else
  bad "no build-machine paths" "${leaks:-} (${macho_leaks} in Mach-Os)"
fi

# ── What a stranger's Mac sees ──────────────────────────────────────────────

# Bytecode is EXPECTED here: the installer runs the database generator on
# this machine, and Python writes caches beside the source it compiles.
# Those name local paths and are correct. What must never appear is
# bytecode compiled somewhere else -- it names a foreign path, is
# invalidated the moment the source lands here, and is pure freight. That
# did ship once, because generating the database in the development tree
# left caches behind and the payload copied that tree wholesale.
foreign="$(grep -rla "$BUILD_HOST_HINT" --include='*.pyc' "$TCR" 2>/dev/null \
           | head -3)"
n_pyc="$(find "$TCR" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')"
[ -z "$foreign" ] && ok "bytecode is local" "$n_pyc caches, none from elsewhere" \
                  || bad "bytecode is local" "$(echo "$foreign" | tr '\n' ' ')"

echo "== signing =="
for target in "$ROOT/Roast.app"; do
  verdict="$(spctl -a -vvv -t exec "$target" 2>&1 | grep -m1 source= || true)"
  case "$verdict" in
    *"Notarized Developer ID"*) ok "gatekeeper" "$(basename "$target"): $verdict" ;;
    *) bad "gatekeeper" "$(basename "$target"): ${verdict:-rejected}" ;;
  esac
done

# ── That it works with no help ──────────────────────────────────────────────

echo "== the toolchain, with a scrubbed environment =="
# `env -i` is the point: no PATH from a developer shell, no COCOAMOJO_ROOT,
# no MODULAR_* overrides. Whatever it finds, it finds by knowing.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/t.mojo" <<'EOF'
from std.objc import ObjCClass

def main():
    let c = ObjCClass.lookup["NSWindow"]()
    print("cocoa ok")
EOF
if env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
     "$TC/bin/cocoamojo" --build "$T/t.mojo" -o "$T/t" >"$T/log" 2>&1 \
   && [ -x "$T/t" ]; then
  out="$(env -i "$T/t" 2>&1)"
  [ "$out" = "cocoa ok" ] && ok "builds and runs" "env -i, Cocoa resolved" \
                          || bad "builds and runs" "ran but said: $out"
else
  bad "builds and runs" "$(grep -m1 error "$T/log" || echo 'build failed')"
fi

# The database is generated at install time, so a release that shipped
# without generating it looks fine on disk and is empty inside.
rows="$(sqlite3 "$TC/share/cocoa.sqlite" \
        'select (select count(*) from rt_classes) || "/" ||
                (select count(*) from rt_methods)' 2>/dev/null || true)"
case "$rows" in
  ""|0/0|*/0) bad "cocoa database" "empty or unreadable (${rows:-no answer})" ;;
  *) ok "cocoa database" "$rows classes/methods" ;;
esac

# Python is OPTIONAL at install time, so its absence is not a failure --
# but half of it is. The framework and the wrapper that reaches it must
# arrive and leave together: a bin/python3 pointing at nothing sits where
# a command belongs and fails only when someone finally tries it.
have_fw=0; have_bin=0
[ -x "$TC/Python/Python.framework/Versions/Current/bin/python3" ] && have_fw=1
[ -x "$TC/bin/python3" ] && have_bin=1
if [ "$have_fw" = 1 ] && [ "$have_bin" = 1 ]; then
  # Through bin/python3, not the framework path: an interpreter only the
  # installer knows how to reach is freight, not a feature.
  if env -i "$TC/bin/python3" -c 'import ssl, sqlite3, venv' 2>/dev/null; then
    ok "python (installed)" "bin/python3 runs; ssl, sqlite3, venv import"
  else
    bad "python (installed)" "bin/python3 present but cannot import"
  fi
elif [ "$have_fw" = 0 ] && [ "$have_bin" = 0 ]; then
  ok "python (declined)" "absent as a whole -- the generator used the SDK's"
else
  bad "python is half-installed" \
      "framework=$have_fw wrapper=$have_bin -- one without the other"
fi

# ── Where the language server looks ─────────────────────────────────────────

echo "== user space =="
for p in "Standard Library/stdlib/std" "Examples" "IDE Source"; do
  [ -e "$US/$p" ] && ok "user space" "$p" || bad "user space" "missing: $p"
done

echo "== import roots =="
# The three roots must be the SAME three the compiler wrapper passes as -I.
# When they drift, the editor squiggles imports the build accepts -- which
# is the bug this check exists to catch.
std="$US/Standard Library/stdlib"
[ -d "$std/std" ] || std="$TC/lib/mojo/stdlib"
for r in "$std" "$TC/lib/mojo/max" "$TC/lib/mojo/kernels"; do
  [ -d "$r" ] && ok "root" "${r/#$HOME/~}" || bad "root" "missing: $r"
done

# Go-to-definition across all three needs the running app and its Apple
# Events surface. Opt in: it steals focus, and a machine with the screen
# locked cannot answer.
if [ "${ROAST_CHECK_AGENT:-0}" = 1 ]; then
  A() { osascript -e "tell application id \"org.mojococoa.roast\" to «event Rostcmnd» \"$1\"" 2>&1; }
  mkdir -p "$T/roots"
  cat > "$T/roots/main.mojo" <<'EOF'
from std.objc import ObjCClass
from max.gpu.host import DeviceContext
from linalg.fp6_utils import FP6Format

def main():
    print("three roots")
EOF
  open -a "$ROOT/Roast.app" "$T/roots" >/dev/null 2>&1; sleep 5
  A "open $T/roots/main.mojo" >/dev/null; sleep 2
  for spec in "1:22:stdlib:Standard Library" "2:26:max:/lib/mojo/max/" \
              "3:30:kernels:/lib/mojo/kernels/"; do
    pos="${spec%%:*}"; rest="${spec#*:}"
    col="${rest%%:*}"; rest="${rest#*:}"
    name="${rest%%:*}"; want="${rest#*:}"
    A "goto $pos:$col" >/dev/null
    A "menu Navigate > Go to Definition" >/dev/null; sleep 2
    landed="$(A file)"
    case "$landed" in
      *"$want"*) ok "definition -> $name" "${landed##*/}" ;;
      *) bad "definition -> $name" "landed in ${landed##*/}" ;;
    esac
    A "open $T/roots/main.mojo" >/dev/null; sleep 1
  done
else
  skip "definition roots" "ROAST_CHECK_AGENT=1 to drive the running app"
fi

echo
if [ "$fail" = 0 ]; then
  echo "release OK -- $pass checks"
else
  echo "$fail failure(s), $pass passed"
  exit 1
fi
