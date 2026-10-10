/* SPDX-License-Identifier: GPL-2.0-only */
/* SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com> */
fkey_dispatch = 0xefd8;
SECTIONS {
 .shared_memory_width 0x31eb8 : { *(.shared_memory_width) }
 .command_width 0x31a04 : { *(.command_width) }
 .command_hook 0xb6a4 : { *(.command_hook) }
}
