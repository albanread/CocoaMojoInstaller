# CocoaMojo for Intel Macs

**Mojo, Cocoa, and the Roast IDE on Intel Mac hardware** — a compiler that
builds native Mac apps from Mojo source (windows, Metal GPU kernels,
CoreAudio), the language server and debugger behind it, and an editor written
in the language it edits.

This is a release repository: **download the DMG from
[Releases](../../releases)**, not the source tree. The tree holds the
installer's own source, for the curious.

---

## Requirements

- An Intel Mac. Two flavors exist — install the one for your machine:

  | image | built for | runs on |
  |---|---|---|
  | `Roast-Intel-<ver>.dmg` | 2019 Mac Pro (Xeon, AVX-512) | AVX-512 Macs only |
  | `MojoToolchain-v3-<ver>.dmg` | any Intel Mac (x86-64-v3, AVX2) | every Intel Mac that runs current macOS |

  Pick wrong and nothing breaks silently: the installer checks your CPU
  before copying, and then *runs the compiler* as its final step — a flavor
  your machine can't execute fails with an explanation, not a crash report.

- macOS 15 or later.
- ~1.5 GB free in `/Applications`. No admin password is needed —
  `/Applications` is group-writable by design.

## Installing

1. Open the DMG and double-click **Install Roast**.

   *If the image is unsigned (pre-notarization builds): right-click →
   Open the first time, or clear quarantine with*
   `xattr -d com.apple.quarantine <the .dmg>`.

2. Press **Install**. Three things happen, and the window narrates them:
   - the toolchain lands in `/Applications/Roast/CocoaMojo/<version>/`,
     beside any version already there — `current` is a symlink naming the
     one that answers;
   - the installer **proves the toolchain executes on your Mac** by running
     `cocoamojo-compiler --version` and showing you the result;
   - the Cocoa SDK database is generated **from your Mac's own frameworks**
     (~15 seconds, ~270 MB) — it describes the macOS you actually have,
     which is why it isn't shipped in the download.

3. Done. Open **Roast** from `/Applications/Roast/` (full flavor), or use
   the toolchain directly:

   ```
   /Applications/Roast/CocoaMojo/current/bin/cocoamojo --run \
       /Applications/Roast/CocoaMojo/current/share/examples/mandelbrot/main.mojo
   ```

## What you get

    bin/cocoamojo         compile and run Mojo (--build, --run)
    bin/mojo-lsp-server   completions and diagnostics, for any LSP editor
    bin/lldb, lldb-dap    the debugger, with Mojo support loaded
    bin/python3           the bundled CPython Mojo interops with
    lib/mojo/             the standard library, as editable source
    share/examples/       fifteen projects, from hello to GPU fluid dynamics
    share/ide-source/     Roast's own source — the largest example there is
    Roast.app             the IDE (full flavor only)

Your own work is never inside the install: edited stdlib, examples, and
per-project Python environments live in
`~/Library/Application Support/Roast/`.

## Reset and Uninstall

Keep the DMG. The same **Install Roast** window offers **Reset** — put a
toolchain you've experimented on back to shipped state — and **Uninstall
All**, which removes `/Applications/Roast` and nothing else. Uninstall
leaves your Application Support work alone unless you tick the box asking
it not to.

## Overview, for the curious

The toolchain is the [MojoMacX64](https://github.com/albanread/MojoMacX64)
fork: Mojo with an Objective-C `class` keyword (declare real Cocoa classes
in Mojo; the runtime calls them), typed Cocoa calls checked at compile time
against the SDK database, and GPU kernels compiled through Apple's Metal AIR
— the same source drives an AMD Vega II, a Navi 5300M, or Apple silicon on
the sister fork. The editor, its language server client, and its debugger
adapter are all written in Mojo itself.

Releases are cut on a 2019 Mac Pro, verified by a 34-check gate before
imaging, and signed off-box.
