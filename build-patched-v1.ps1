# build-patched-v1.ps1
# Deterministic build: patches the original MikroTik winbox64.v3.43.exe so it works
# with RouterOS 7.25. This is patch set v1; additional patch sets may be added later
# as separate versioned scripts if future RouterOS releases require them.
# Every write is preceded by an assertion on the expected original bytes;
# the result is verified against the known-good SHA-256.
# Mapping: file offset = VMA - 0x400C00 (.text VMA 0x401000 = file 0x400).
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'winbox64.v3.43.exe'
$out = Join-Path $PSScriptRoot 'winbox64.v3.43p1.exe'

$ORIG_SHA   = '5b41cf51fd81e8d082687f6b522159cf4aba22e6df8edc486721d4e09507b6e9'
$TARGET_SHA = 'acfc8034b662cdabd4ead6a590194a2274dc41358f1b0cda71db9a752b2c4ea4'

$B = [IO.File]::ReadAllBytes($src)
$orig = $B.Clone()

function Sha([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function HB([string]$h) { $h -split '\s+' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) } }
# Assert that the bytes currently at $off match $h (guards against a wrong input file).
function Chk([int]$off, [string]$h, [string]$what) {
  $hb = HB $h
  for ($i = 0; $i -lt $hb.Count; $i++) {
    if ($B[$off + $i] -ne $hb[$i]) { throw ("ASSERT [{0}] @0x{1:X}: expected {2:X2}, got {3:X2}" -f $what, ($off + $i), $hb[$i], $B[$off + $i]) }
  }
}
function Wr([int]$off, [string]$h) {
  $hb = HB $h
  for ($i = 0; $i -lt $hb.Count; $i++) { $B[$off + $i] = $hb[$i] }
}

if ((Sha $B) -ne $ORIG_SHA) { throw "Input is not the original winbox64.v3.43.exe (SHA-256 mismatch)." }
"Input OK: winbox64.v3.43.exe ($ORIG_SHA)"


# --- Patch 1: ignore server-advertised minimum WinBox version (VMA 0x4FA51C) ---
# ROS 7.25 reports min WinBox 4.3 in login reply (string var 0x16); the client-side
# gate `jbe` is turned into an unconditional `jmp`. The server still speaks the old protocol.
Chk 0xF991C '76' 'p1'
Wr  0xF991C 'EB'

# --- Patch 2: always take the "no skin" branch (VMA 0x4FA991) ---
# ROS 7.25 skins contain JSON constructs that crash WinBox3's skin parser (0x47BB20).
Chk 0xF9D91 '0F 84 13 01 00 00' 'p2'
Wr  0xF9D91 'E9 14 01 00 00 90'

# --- Patch 3: title?:name fallback in the menu-descriptor parser (VMA 0x4A7945) ---
# ROS 7.25 dropped redundant `title` (== name) from .jg descriptors -> strlen(NULL) crash.
Chk 0xA6D45 'E8 30 75 F9 FF' 'p3a'
Wr  0xA6D45 'E8 E7 5F 05 00'                 # call cave @0x4FD931 instead of strlen wrapper
Chk 0xFCD31 '90 90 90 90 90 90 90 90 90 90 90 90 90 90' 'p3b'
Wr  0xFCD31 '48 85 D2 75 04 48 8B 53 18 E9 3B 15 F4 FF'  # cave: rdx NULL ? [rbx+0x18] : rdx; jmp strlen

# --- Patch 4: tolerate unknown field / conv types (VMA 0x4A28AA, 0x49DCB8) ---
# New in 7.25: field types bigfixedpoint/bignumberrange and conv u32_u32vector hit intentional asserts.
Chk 0xA1CAA '48 8B 0D 4F B3 09 00' 'p4a'
Wr  0xA1CAA 'E9 80 00 00 00 90 90'           # unknown field type -> skip-tail 0x4A292F (ret NULL)
Chk 0x9D0B8 '0F 85 8C 00 00 00' 'p4b'
Wr  0x9D0B8 '0F 85 42 FF FF FF'              # unknown conv type -> u32_u32 handler 0x49DC00

# --- Patch 5: guard id-less multinumber fields (VMA 0x4A3799, cave @0x49DD4A) ---
# 'Interfaces' (new Power Cycle dialog) has no id property; predicate call with NULL -> AV.
Chk 0x9D14A '48 8B 0D AF FE 09 00 48 8D 15 B4 8C 09 00 E8 2C 39' 'p5a'
Wr  0x9D14A '4D 85 F6 75 1B 59 48 83 C4 38 5B 5E 5F 5D 41 5C 41 5D 41 5E 41 5F 48 83 C4 38 59 E9 C5 4B 00 00 E9 C1 A6 03 00'
#   cave: test r14,r14; NULL -> full frame unwind + jmp skip-tail 0x4A292F; else jmp predicate 0x4D8430
Chk 0xA2B99 'E8 92 4C 03 00' 'p5b'
Wr  0xA2B99 'E8 AC A5 FF FF'                 # call cave instead of predicate

# --- Patch 6: defuse the SlotRef "slot not found" assert (VMA 0x4837A0) ---
Chk 0x82BA0 'C7 04 25 00 00 00 00 00 00 00 00 0F 0B' 'p6'
Wr  0x82BA0 'EB 75 90 90 90 90 90 90 90 90 90 90 90'  # jmp graceful exit 0x483817 + nops

# --- Patch 7: check `id` BEFORE constructing multinumber fields (VMA 0x4A1426, cave @0x483724) ---
# Skip id-less fields before any allocation; guard [rsp]==0x4A142B rejects alien fall-through entries.
Chk 0x82B24 '48 8B 0D D5 A4 0B 00' 'p7a'
Wr  0x82B24 '48 81 3C 24 2B 14 4A 00 75 4E 59 48 83 EC 28 4C 89 EA 48 8D 4C 24 20 E8 70 1D 00 00 48 8B 44 24 20 48 85 C0 74 29 49 89 C3 48 8B 08 E8 CB 6D 00 00 3D 00 00 64 69 74 09 4C 89 D8 48 8B 40 08 EB E0 48 83 C4 28 B9 C0 00 00 00 E9 B8 DC 01 00 48 83 C4 28 E9 2E F1 01 00 E9 96 00 00 00'
Chk 0xA0826 'B9 C0 00 00 00' 'p7b'
Wr  0xA0826 'E8 F9 22 FE FF'                 # mov ecx,0xC0 -> call cave2

# --- Patch 8: numeric-node guard at field-parser entry (VMA 0x4A0DFC, cave @0x49DD6F) ---
# 7.25 resolves multicmdsrc references by slot number; parser called with 0x438 instead of a node pointer.
Chk 0x9D16F '6D 8C 09 00 48 89 C1 E8 0E 39 03 00 BA 6F' 'p8a'
Wr  0x9D16F '48 81 F9 00 00 01 00 72 0A E9 04 E9 FD FF'  # cmp rcx,0x10000; jb L; jmp resolver 0x47C681
Chk 0x9D17D '2C 00 00 48 89' 'p8b'
Wr  0x9D17D '90 90 90 90 90'                 # nop padding inside the cave
Wr  0x9D182 '31 C0 C3'                       # L: xor eax,eax; ret
Chk 0xA01FC 'E8 80 B8 FD FF' 'p8c'
Wr  0xA01FC 'E8 6E CF FF FF'                 # call cave3 instead of resolver

# --- Patch 9: defuse the "no slot found for cond" assert (VMA 0x492DEE) ---
Chk 0x921EE 'C7 04 25 00 00 00 00 00 00 00 00 0F 0B' 'p9'
Wr  0x921EE '31 C0 E9 06 01 00 00 90 90 90 90 90 90'    # xor eax,eax; jmp epilogue 0x492EFB + nops

# --- Patch 10: skip NULL slots in the window children array (VMA 0x484862, cave @0x49DD85) ---
# The skip from patch 7 leaves NULL holes; the indexer wrote to [0+0x18].
Chk 0x9D185 '39 03 00 48 89 C1 E8 BF 3C 03 00 C7 04 25 00 00 00 00 00 00 00' 'p10a'
Wr  0x9D185 '48 8B 14 C2 48 85 D2 75 08 59 FF C5 E9 B7 6A FE FF 89 6A 18 C3'  # cave4: NULL -> next iteration
Chk 0x83C62 '48 8B 14 C2 89 6A 18' 'p10b'
Wr  0x83C62 'E8 1E 95 01 00 90 90'           # mov/mov -> call cave4 + nops

# --- Patch 11: title?:name fallback in the menu index builder - tabs (VMA 0x4A7420, cave @0x483781) ---
Chk 0x82B81 '0B 00 48 89 C1 E8 FE DE 04 00 BA 7B 03 00 00 48 89 C1 E8 DA DF' 'p11a'
Wr  0x82B81 '48 8B 56 20 48 85 D2 75 04 48 8B 56 18 48 89 F9 E9 48 BB 04 00'  # cave5: title ?: name; tail-jmp builder
Chk 0xA6820 '48 8B 56 20 48 89 F9 E8 B2 7E 02 00' 'p11b'
Wr  0xA6820 'E8 5C C3 FD FF 90 90 90 90 90 90 90'     # call cave5 + nop the leftover builder call

# --- Patch 12: same title fallback for QuickSet (VMA 0x4A7119) ---
Chk 0xA6519 'E8 C0 81 02 00' 'p12'
Wr  0xA6519 'E8 63 C6 FD FF'                 # call cave5 instead of string builder 0x4CF2DE


# --- Final verification ---
$final = Sha $B
"Output SHA-256: $final"
if ($final -ne $TARGET_SHA) { throw "Result does not match the known-good patched build (expected $TARGET_SHA)." }

[IO.File]::WriteAllBytes($out, $B)
"Wrote: $out ($($B.Length) bytes) - byte-identical to the known-good patched build"

$diffCount = 0; $areas = 0; $inArea = $false
for ($i = 0; $i -lt $orig.Length; $i++) {
  if ($orig[$i] -ne $B[$i]) { $diffCount++; if (-not $inArea) { $areas++; $inArea = $true } }
  else { $inArea = $false }
}
"Diff vs original: $diffCount bytes changed in $areas contiguous runs (all inside .text)"


