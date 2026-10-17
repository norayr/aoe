# Upstream provenance

## aoe contributions

Original aoe code, examples, build scripts and tests, and aoe's modifications
to imported code, are licensed under `GPL-3.0-only`; see `LICENSE`. Upstream
code retains its existing notices and license terms. Distributing the combined
work under GPLv3 does not remove those notices or claim ownership of upstream
contributions.

## A2 sources

The initial import contains 66 unmodified Active Oberon/A2 modules and
`license.txt` from:

- Repository: https://gitlab.inf.ethz.ch/felixf/oberon
- Commit: `f11d6f54e936705fe74e54009541c856fa486045`
- Commit date: 2026-02-01

These are the runtime, shell, compiler and linker sources selected for a
desktop-free Linux x86-64 distribution. The original platform-specific source
filenames and copyright notices are preserved. See `license.txt` and the
individual source headers for licensing terms.

## Console search tools from polpo

`source/regex.Mod` and `source/grep.Mod` are adapted from
`src/common/regex.Mod` and `src/cli/grep.Mod` in
<https://github.com/polpo-system/polpo>, revision
`30126a8ea71ca7100bd3d2d30be61ef0f9e5c8e8`. They are distributed under polpo's
GNU GPL version 3, reproduced in `license-polpo.txt`; this does not replace
the existing A2 source notices or `license.txt`.

The adaptation uses A2 command streams and files instead of the Oberon desktop
text system, keeps search state local to each invocation for concurrent pipes,
handles Unix text line endings and growing line buffers, and fixes validation
of repetitions following character classes and escaped characters.
