/* SPDX-License-Identifier: GPL-2.0-only */
/* SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com> */

property_size_error = 0x818c;
property_bounds_error = 0x88e4;
property_copy_done = 0x88d0;
memcpy_plt = 0x4730;

SECTIONS
{
    .fkeymaster_hook 0x88b4 : { *(.text.fkeymaster_hook) }
    .fkeymaster_adapter 0xdbf0 : { *(.text.fkeymaster_adapter) }
}
