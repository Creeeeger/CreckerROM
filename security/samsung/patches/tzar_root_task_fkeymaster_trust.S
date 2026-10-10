/* SPDX-License-Identifier: GPL-2.0-only */
/* SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com> */
/*
 * Additional ROM trust anchor for the six verified Exynos990 master root tasks.
 * The hook runs AFTER the original CN, RSA package signature and root-type
 * checks. Samsung certificates retain the original verification path.
 * Only an authenticated image with FKeyMaster's UUID may use the ROM anchor.
 * The original certificate verifier also checks the ROM-issued certificate;
 * no authentication result is replaced with an unconditional success.
 *
 * At 0xdefc: x0 = Samsung root, x1 = leaf, x20 = parsed TA package.
 * The adapter occupies original zero padding in the RX segment, whose extent
 * is enlarged without moving any existing section, relocation or TZAR record.
 * The build installs the public DER certificate and its length separately.
 */
.extern samsung_verify_cert
.extern find_properties
.extern parse_cert_plt
.extern free_cert_plt
.extern rom_root_cert
.extern rom_root_cert_length

.section .text.fkeymaster_trust_hook,"ax",@progbits
.global fkeymaster_trust_hook
fkeymaster_trust_hook:
    bl fkeymaster_verify_cert

.section .text.fkeymaster_trust,"ax",@progbits
.global fkeymaster_verify_cert
fkeymaster_verify_cert:
    stp x29, x30, [sp, #-192]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x21, x20
    mov x19, x1
    bl samsung_verify_cert
    cbz w0, .Ldone
    mov w20, w0

    /* Read properties from the SAME image whose signature was just checked. */
    ldr x0, [x21, #24]
    ldr w1, [x21, #16]
    add x2, sp, #64
    mov x3, xzr
    mov x4, xzr
    mov x5, xzr
    bl find_properties
    cbnz w0, .Lreject
    ldp x8, x9, [sp, #64]
    cbnz x8, .Lreject
    ldr x10, .Luuid_tail
    cmp x9, x10
    b.ne .Lreject

    adr x0, rom_root_cert
    str x0, [sp, #48]
    add x1, sp, #48
    adr x2, rom_root_cert_length
    ldr w2, [x2]
    mov x0, xzr
    bl parse_cert_plt
    cbz x0, .Lreject
    mov x21, x0
    mov x1, x19
    bl samsung_verify_cert
    mov w20, w0
    mov x0, x21
    bl free_cert_plt
.Lreject:
    mov w0, w20
.Ldone:
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x29, x30, [sp], #192
    ret
.balign 8
.Luuid_tail:
    .quad 0x526d6b4362460000
