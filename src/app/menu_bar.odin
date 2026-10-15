// Copyright (C) 2025  Davorin Šego

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


package app

import "core:fmt"

import "../audio"
import "../gfx"

// The macOS menu bar's commands, see setup_menu_bar. Each key has Command in it, see handle_keys.
MenuCommand :: enum {
    NONE,
    SETTINGS,
    SHOW_STROBE,
    SHOW_SCOPE,
    SHOW_TRACE,
    SHOW_LAMP,
    SHOW_SPECTRUM,
    COLORS_RED,
    COLORS_MINT,
    COLORS_AMBER,
    COLORS_MONO,
    RETRO_GLOW,
    LOCK_NOTE,
    DEFAULT_SIZE,
    INPUTS, // and the ones after it, the Input menu's by their place in audio_devices, see build_input_list
}

MAX_INPUT_COMMANDS :: gfx.MAX_MENU_COMMANDS - int(MenuCommand.INPUTS)

// The display each of the View menu's first items shows, in the settings' order
DISPLAY_COMMANDS :: [StrobeDisplayType]MenuCommand {
    .STROBE   = .SHOW_STROBE,
    .SCOPE    = .SHOW_SCOPE,
    .TRACE    = .SHOW_TRACE,
    .LAMP     = .SHOW_LAMP,
    .SPECTRUM = .SHOW_SPECTRUM,
}

// The colors the View menu's second group picks, named like the settings' Colors
COLORWAY_COMMANDS :: [StrobeColorway]MenuCommand {
    .VIBRANT_RED = .COLORS_RED,
    .MINTY       = .COLORS_MINT,
    .AMBER       = .COLORS_AMBER,
    .MONO        = .COLORS_MONO,
}

// SDL's app menu gets Settings…, the View menu the displays, the colors, the glow and the lock, the Input
// menu the inputs, the Window menu the strobe's size back. Resetting stays on the settings sheet, where
// RESET asks first.
setup_menu_bar :: proc(app: ^App) {
    gfx.add_app_menu_items(int(MenuCommand.SETTINGS), {})

    // The displays by their number keys, named like on the settings, and the colors
    view := make([dynamic]gfx.MenuItem, context.temp_allocator)
    display_names, display_commands := DISPLAY_NAMES, DISPLAY_COMMANDS
    for type in StrobeDisplayType {
        key := fmt.ctprintf("%d", int(type) + 1)
        append(&view, gfx.MenuItem{title = display_names[type], key = key, command = int(display_commands[type])})
    }
    append(&view, gfx.MenuItem{})

    colorway_names, colorway_commands := COLORWAY_NAMES, COLORWAY_COMMANDS
    for colorway in StrobeColorway {
        append(&view, gfx.MenuItem{title = colorway_names[colorway], command = int(colorway_commands[colorway])})
    }
    append(
        &view,
        gfx.MenuItem{},
        gfx.MenuItem{title = "Retro Glow", key = "g", command = int(MenuCommand.RETRO_GLOW)},
        gfx.MenuItem{title = "Lock Note", key = "l", command = int(MenuCommand.LOCK_NOTE)},
    )
    gfx.add_menu("View", view[:])

    // Filled by build_input_list, and the list made again as it opens for what's connected now. The one opened
    // follows in the next frame, see follow_input.
    looking :: proc(data: rawptr) {
        app := (^App)(data)
        if app.audio_capture == nil do return

        audio.refresh_devices(app.audio_capture)
        build_input_list(app)
    }
    app.input_menu = gfx.add_menu("Input", {}, looking, app)

    gfx.add_window_menu_items({{title = "Strobe Size", key = "0", command = int(MenuCommand.DEFAULT_SIZE)}})
}

// The check marks in the View menu follow the app however it was changed
update_menu_checks :: proc(app: ^App) {
    for command, type in DISPLAY_COMMANDS {
        gfx.set_menu_checked(int(command), app.config.strobe_display_type == type)
    }
    for command, colorway in COLORWAY_COMMANDS {
        gfx.set_menu_checked(int(command), app.config.strobe_colorway == colorway)
    }
    gfx.set_menu_checked(int(MenuCommand.RETRO_GLOW), app.config.strobe_glow)
    gfx.set_menu_checked(int(MenuCommand.LOCK_NOTE), app.tuner.locked)

    for index in 0 ..< min(len(app.audio_devices), MAX_INPUT_COMMANDS) {
        gfx.set_menu_checked(int(MenuCommand.INPUTS) + index, index == app.audio_device_index)
    }
}
