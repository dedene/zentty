# Vendored Zstandard decoder

Decompress-only build of [Zstandard](https://github.com/facebook/zstd) (the repository now
lives at `meta/zstd`), used by Agent History to read compressed Codex rollouts
(`*.jsonl.zst`).

- Version: **v1.5.7** (latest release when vendored, 2026-10-31)
- License: BSD-3-Clause (`LICENSE`, copied from the release root). Upstream is dual-licensed
  BSD/GPLv2; Zentty uses it under the BSD license.
- Source: release tarball `zstd-1.5.7.tar.gz` from
  `https://github.com/meta/zstd/releases/download/v1.5.7/`, verified against the published
  `zstd-1.5.7.tar.gz.sha256`:
  `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`

## Files

| File | Origin |
| --- | --- |
| `Sources/CZstd/zstddeclib.c` | single-file decoder amalgamation, generated (below) |
| `Sources/CZstd/include/zstd.h` | `lib/zstd.h`, unchanged |
| `Sources/CZstd/include/zstd_errors.h` | `lib/zstd_errors.h`, unchanged (included by `zstd.h`) |
| `Sources/CZstd/include/module.modulemap` | local: names the module `CZstd` so the test targets can find it through `SWIFT_INCLUDE_PATHS` (see `project.yml`) |
| `LICENSE` | `LICENSE`, unchanged |

## Regenerating

From the extracted release, outside this repository:

```sh
cd zstd-1.5.7/build/single_file_libs
./create_single_file_decoder.sh
# which runs:
# ./combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

Copy the resulting `zstddeclib.c` to `Sources/CZstd/`, and `lib/zstd.h` plus
`lib/zstd_errors.h` to `Sources/CZstd/include/`. Do not edit either file by hand.

The amalgamation input (`zstddeclib-in.c`) already bakes in `ZSTD_LEGACY_SUPPORT 0`,
`ZSTD_DISABLE_ASM 1` (the x86-64 Huffman assembly cannot be amalgamated),
`ZSTD_STRIP_ERROR_STRINGS` and `DEBUGLEVEL 0`. `Package.swift` repeats the first two as
`cSettings` so the header and source agree if the file is ever regenerated differently.

SHA-256 of the vendored files:

```
5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0  Sources/CZstd/zstddeclib.c
9b4bc8245565c98ccfc61c07749928b57e7c0f6fddb0530c4f6aa1971893d88b  Sources/CZstd/include/zstd.h
66a8c3f71d12ea6e797e4f622f31f3f8f81c41b36f48cad4f5de7d8bfb6aac0a  Sources/CZstd/include/zstd_errors.h
7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8  LICENSE
```
