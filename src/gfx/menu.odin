// Copyright (C) 2026  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.

#+build !darwin
package gfx

// Only macOS has a menu bar, see menu_darwin.odin. Everything here does nothing.

add_app_menu_items :: proc(settings: int, items: []MenuItem) {}

add_menu :: proc(title: cstring, items: []MenuItem, opening: proc(data: rawptr) = nil, data: rawptr = nil) -> int {
    return -1
}

set_menu_items :: proc(which: int, items: []MenuItem) {}

add_window_menu_items :: proc(items: []MenuItem) {}

menu_command :: proc() -> int {
    return 0
}

set_menu_checked :: proc(command: int, checked: bool) {}
