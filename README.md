# WinBox 3.43 for RouterOS 7.25 (binary patch)

**WinBox 3.43** is the last release of the classic WinBox 3.x client. It works fine with
RouterOS up to 7.24.x, but **RouterOS 7.25 breaks it**: the client either refuses to connect
or crashes while loading the interface. MikroTik's answer is "upgrade to WinBox 4.x" — this
project instead patches the original `winbox64.v3.43.exe` so it keeps working with 7.25.

The build is fully deterministic: a single PowerShell script applies **12 surgical byte
patches** (282 bytes total, all inside `.text`) to the original binary and verifies the
result against a known-good SHA-256. The output is **byte-identical** to the community-tested
patched build.

This repository currently ships **patch set v1**. The patch pipeline is deterministic and
self-verifying, so if a future RouterOS release breaks WinBox 3.43 again, further patch sets
can be added the same way as new versions.

| File | SHA-256 |
|---|---|
| `winbox64.v3.43.exe` (original, input) | `5b41cf51fd81e8d082687f6b522159cf4aba22e6df8edc486721d4e09507b6e9` |
| `winbox64.v3.43p1.exe` (output, patch set v1) | `acfc8034b662cdabd4ead6a590194a2274dc41358f1b0cda71db9a752b2c4ea4` |

## Credits

This project — the reverse-engineering analysis of the WinBox 3.43 binary, the complete
patch set, the deterministic build script, the CI pipeline and this documentation —
was created with the assistance of the AI model **GLM-5.3**.

## What changed in RouterOS 7.25 and why WinBox 3.43 breaks

* The login reply advertises a minimum WinBox version of **4.3** — the *client* rejects the
  session itself, although the server is still perfectly able to speak the old protocol.
* Skins stored on the router were regenerated (by WinBox 4.x / the `user` service) with new
  JSON constructs that crash WinBox 3's skin parser.
* The `.jg` menu-descriptor generator dropped redundant `title` fields (minification), so
  WinBox 3 calls `strlen(NULL)` in three different places.
* New field types (`bigfixedpoint`, `bignumberrange`), a new conv type (`u32_u32vector`)
  and new constructs in the Power Cycle dialog (id-less `multinumber` field,
  `multicmdsrc` reference-by-slot-number) hit WinBox 3's intentional asserts.

The patches below make the frozen WinBox 3 parser tolerant to all of this — the same
approach MikroTik themselves took in WinBox 4.2 ("ignore all RouterOS WinBox file parsing
errors"), plus a fallback for the dropped `title` fields.

## The patches

All offsets are file offsets (`VMA − 0x400C00`); "cave" = hand-written code placed into
dead assert/log blocks.

| # | Location (VMA) | What it does | Trade-off |
|---|---|---|---|
| 1 | `0x4FA51C` | Ignore the server-advertised minimum WinBox version (`jbe` → `jmp`) | none |
| 2 | `0x4FA991` | Always take the built-in "no skin" branch instead of downloading the router skin | user skins/layouts from the router are not loaded |
| 3 | `0x4A7945` + cave `0x4FD931` | Menu parser: `title ?: name` fallback before `strlen` | none |
| 4 | `0x4A28AA`, `0x49DCB8` | Unknown field types are skipped (instead of an assert crash); unknown conv types degrade to the `u32_u32` handler | NTP windows lose 9 `bigfixedpoint` / 1 `bignumberrange` fields; Power Cycle / Format Drive pre-fill may not work |
| 5 | `0x4A3799` + cave `0x49DD4A` | Guard id-less `multinumber` fields: NULL id → full frame unwind → field skipped | none |
| 6 | `0x4837A0` | Defuse the `SlotRef … slot not found` assert → graceful exit | none |
| 7 | `0x4A1426` + cave `0x483724` | Check for the `id` property **before** any allocation; skip id-less fields cleanly. A return-address guard rejects accidental entries into the cave | the Interfaces column in the Power Cycle dialog is not built |
| 8 | `0x4A0DFC` + cave `0x49DD6F` | Field-parser entry guard: if called with a small integer (7.25 resolves `multicmdsrc` by slot number, not node pointer) → return NULL → field skipped | none |
| 9 | `0x492DEE` | Defuse the `no slot found for cond` assert → return NULL via the function epilogue | none |
| 10 | `0x484862` + cave `0x49DD85` | Skip NULL holes in the window children array left by the skip in #7 (the indexer would write to `0+0x18`) | none |
| 11 | `0x4A7420` + cave `0x483781` | Menu index builder (opening tabs): the same `title ?: name` fallback; the leftover original builder call is nop'd out | none |
| 12 | `0x4A7119` | QuickSet: third consumer of `title` → reuse the same fallback cave | none |

## Build

Requirements: the original `winbox64.v3.43.exe` in the repo root and PowerShell
(Windows PowerShell 5.1 or PowerShell 7+).

```powershell
./build-patched-v1.ps1
```

The script:

1. verifies the input hash (fails on anything but the pristine original);
2. asserts the expected original bytes before **every** write (fails safely on a wrong offset);
3. applies the 12 patches;
4. verifies the output hash and writes `winbox64.v3.43p1.exe`.

## CI / Releases

`.github/workflows/build-and-release.yml` runs on **every push to `main`**
(and manually via `workflow_dispatch`): it patches the binary on a Windows runner, verifies
the SHA-256, and publishes/updates a rolling GitHub Release tagged `patched-v1` with the
following assets:

* `winbox64.v3.43p1.exe` — the patched client
* `icons16.png`, `icons24.png`, `icons32.png` — icon sets

## Repository layout

```
winbox64.v3.43.exe         original MikroTik binary (patch input)
build-patched-v1.ps1       deterministic patch script (patch set v1)
winbox64.v3.43p1.exe       build output (generated)
icons16/24/32.png          icon sets shipped alongside the release
.github/workflows/         CI: build + release
```

## Disclaimer

WinBox is proprietary MikroTik software. The original binary is included here only as the
input of the patch, unmodified; the patch itself is a small interoperability fix for
RouterOS 7.25. Use at your own risk.

