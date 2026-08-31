# CocoaMojo Installer — Intel

Builds the macOS installer for the Intel-Mac CocoaMojo toolchain
([MojoMacX64](https://github.com/albanread/MojoMacX64)): compiler, language
server, debugger, standard library, examples, and the Roast editor.

Two flavors, one policy — every machine gets its own ISA:

    Roast-Intel-<ver>.dmg          full: toolchain + Roast.app, Xeon-native
                                   (AVX-512; the 2019 Mac Pro's build)
    MojoToolchain-v3-<ver>.dmg     portable: toolchain only, x86-64-v3
                                   (AVX2; runs on any Intel Mac)

The installer proves the ISA contract at install time: it checks the CPU
before copying and then *runs* `cocoamojo-compiler --version`, so a flavor
built for a wider ISA fails with an explanation instead of a crash report.

Signing is configured in `tools/signing.local.sh` (gitignored; see the
`.example`). Unsigned images are cut with `make-release.sh --no-sign` and
signed off-box.

Current release: **Roast-Intel-2026.08.31.dmg** — attached to this repo's
release for the `intel-2026.08.31` tag.
