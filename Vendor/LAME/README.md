# LAME 3.100 — bundled MP3 encoder

- Upstream: https://lame.sourceforge.io/
- Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- Source SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
- Independently cross-checked against the source-archive SHA-256 in Debian's
  `lame_3.100-6.dsc`.
- License: GNU Library General Public License, version 2 or later; see `COPYING`.
- Build output: a macOS 14+ dynamic library for the build machine's architecture;
  no CLI, decoder, virtual audio driver, or external runtime dependency other
  than libSystem. No prebuilt dynamic library is tracked in this repository.

The original source archive and complete license are included here and copied to
the built application's `Contents/Resources/LAME/` folder. This is a deliberately
small encoder-only build of the 3.100 source, not a claim that 3.100 is the newest
LAME release. Apple Silicon is the validated development platform.

## Rebuild or replace

From the AudioLoom source directory:

```sh
bash Tools/build-lame.sh
bash build.sh
```

The build script verifies the archive, extracts it into `.build/lame/`, excludes
obsolete/disabled decoder symbols from `include/libmp3lame.sym` for the Darwin
linker, builds a shared encoder library, sets its relative install name, and
locally signs the binary. No encoding algorithms are modified.

You may modify the library and rebuild it yourself, or replace the bundled
dynamic library with a compatible modified version. The app does not prohibit
reverse engineering for debugging such changes. A replaced library/app must be
locally re-signed because macOS verifies bundle integrity. For an installed copy:

```sh
codesign --force --sign - "/Applications/声流.app/Contents/Frameworks/libmp3lame.0.dylib"
codesign --force --sign - "/Applications/声流.app"
```

Quit the app before replacing its files. Keep the matching license, source, and
modification notices if you redistribute your build.
