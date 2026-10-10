// SPDX-License-Identifier: GPL-2.0-only
// SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
.section .shared_memory_width,"ax"
mov w2, w2
.section .command_width,"ax"
.global fkey_command_width
fkey_command_width:
mov w1, w1
mov w3, w3
b fkey_dispatch
.section .command_hook,"ax"
bl fkey_command_width
