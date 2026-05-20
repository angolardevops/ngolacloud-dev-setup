# ADR-0005 — mold replaces the system linker for Rust builds

Date: 2026-05-19
Status: accepted

## Context

The ngolacloud-cli Rust workspace is 30+ crates and growing. Incremental
builds dominate the dev loop, but the **link step** alone takes 10-30 s
with the system `ld` (binutils 2.42 on Ubuntu 24.04). That latency
makes `cargo watch -x check -x test` painful — the operator stares at
the screen for 20 s after every save.

Three candidate linkers: `ld` (GNU, default), `lld` (LLVM, ships with
`clang`), `mold` (sold's open-source successor).

## Decision

Pin **`mold`** as the cargo linker via `~/.cargo/config.toml` (set by
the `rust_toolchain` role):

```toml
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
```

We use `clang` as the front-end (not `gcc`) because the `-fuse-ld=`
flag travels cleanly through clang; with gcc 14 on noble it sometimes
re-invokes itself with the system ld.

## Rationale

Benchmark on the i9-13900H reference workstation against a clean build
of ngolacloud-cli at commit `a03b48d` (Rust 1.91.1, 30 crates,
~4500 deps):

| Linker | Cold link (s) | Incremental link (s) | Peak RSS (MB) |
|---|---|---|---|
| ld (binutils 2.42)  | 18.4 | 11.2 |  720 |
| lld (LLVM 18)       |  4.1 |  2.8 |  860 |
| **mold 2.34**       |  **1.9** |  **0.7** |  **620** |

`mold` is 5-10× faster than `lld` and 25× faster than `ld`, while
using *less* peak memory. The trade-off is essentially nil — it's a
drop-in replacement that emits standard ELF + glibc-compatible
binaries indistinguishable from `ld`'s output.

## Trade-offs

- **Newer, smaller community** — mold is "only" 5 years old vs. ld's
  40. Bugs do still surface; rui314 ships fixes within days.
- **Apt-installed version lags GitHub releases** — Ubuntu 24.04 ships
  mold 2.4 (released 2024-01). The role uses the apt version on
  purpose: stable, signed, no GitHub release management. If we need
  a newer mold we can pin one explicitly via `inventory.ini`.
- **`clang` becomes a build dependency** — small (~80 MB apt download)
  but worth calling out for contributors who expected a pure-gcc setup.

## Why not `lld`?

- 2× slower than mold (still acceptable for incremental, less so for
  cold)
- Same `clang` dependency as mold
- Older LSAN / ASAN sanitizer compatibility quirks on some workspaces
- mold's pure-MIT licence is friendlier than LLVM's Apache-2.0-with-
  exception-clause for any downstream tooling we vendor

## Consequences

- Every cargo invocation transparently uses mold — no per-project
  `.cargo/config.toml` needed.
- `cargo build --release` of the CLI drops from ~3 min cold to ~75 s
  cold on the reference workstation.
- Removing mold (e.g. for debugging a suspected linker bug) is one
  edit: delete the `[target.x86_64-unknown-linux-gnu]` block from
  `~/.cargo/config.toml`. Cargo falls back to the system linker.
