/* SPDX-License-Identifier: GPL-2.0-only */
/* SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com> */
/*
 * Exynos990 root_task compatibility adapter: ELF64 FKeyMaster properties.
 * Shared RX layout: G780F, G981B, G986B, G988B, N981B and N986B master firmware.
 * Linked VMAs equal ELF file offsets in this binary's RX segment.
 *
 * The hook replaces b.ne at 0x88b4; the 112-byte path stays unchanged.
 * The adapter occupies the unreachable ta_pkg_verify body at 0xdbf0.
 * It REQUIRES the mov w0,#0; ret authentication bypass at 0xdbdc.
 * Disable the hook and adapter rows together with that bypass.
 *
 * S721BXXS7BYH1's TEEGRIS_5 reader already converts 112 -> 116 bytes:
 * at 0xb984/0xb98c it shifts the tail from 0x44 to 0x48 and inserts zero.
 * This is the reverse conversion, restricted to the FKeyMaster UUID and
 * a zero added word. Nonzero/new semantics remain unsupported.
 * The source ELF is unchanged; only the reader's output is translated.
 *
 * Reader state at 0x88b4:
 *   x1 = property source, x2 = sh_size, x7 = exclusive ELF end,
 *   x29 = reader frame; [x29+168] = 112-byte output pointer.
 *   [x29+120] already saves w3. [x29+96] is free on this path.
 * Both memcpy calls may clobber all caller-saved registers.
 */

/* Resolve these absolute VMAs at link time, preserving branch relocations. */
.extern property_size_error
.extern property_bounds_error
.extern property_copy_done
.extern memcpy_plt

.section .text.fkeymaster_hook,"ax",@progbits
.global fkeymaster_property_hook
fkeymaster_property_hook:
    b.ne fkeymaster_property_adapter

.section .text.fkeymaster_adapter,"ax",@progbits
.global fkeymaster_property_adapter
fkeymaster_property_adapter:
    cmp x2, #0x74
    b.ne property_size_error

    /* Check all 116 input bytes, including pointer overflow, before reads. */
    adds x5, x1, #0x74
    b.cs property_size_error
    cmp x7, x5
    b.ls property_bounds_error

    /* UUID: 00000000-0000-0000-0000-4662436b6d52. */
    ldp x8, x9, [x1]
    cbnz x8, property_size_error
    ldr x10, .Lfkeymaster_uuid_tail
    cmp x9, x10
    b.ne property_size_error
    ldr w8, [x1, #0x44]
    cbnz w8, property_size_error

    /* Copy unchanged prefix, then shift the 44-byte tail back by four. */
    ldr x0, [x29, #168]
    str x1, [x29, #96]
    str x7, [x29, #128]
    mov x2, #0x44
    bl memcpy_plt
    ldr x1, [x29, #96]
    add x0, x0, #0x44
    add x1, x1, #0x48
    mov x2, #0x2c
    bl memcpy_plt
    b property_copy_done

.balign 8
.Lfkeymaster_uuid_tail:
    .quad 0x526d6b4362460000
