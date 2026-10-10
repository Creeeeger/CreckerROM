/* SPDX-License-Identifier: GPL-2.0-only */
/* SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com> */
SECTIONS
{
    samsung_verify_cert = 0xf8dc;
    find_properties = 0x8048;
    parse_cert_plt = 0x44a0;
    free_cert_plt = 0x4850;
    rom_root_cert_length = 0x133f0;
    rom_root_cert = 0x13400;
    .trust_hook 0xdefc : { *(.text.fkeymaster_trust_hook) }
    .trust_adapter 0x13200 : { *(.text.fkeymaster_trust) }
    /DISCARD/ : { *(.comment) *(.note*) }
}
ASSERT(SIZEOF(.trust_adapter) <= 0x1f0, "Trust adapter overlaps certificate length")
