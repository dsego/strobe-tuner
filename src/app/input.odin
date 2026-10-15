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

// A picked input that's gone is looked for this often, the system says nothing when one is plugged in that
// isn't its default
MISSING_INPUT_POLL_S :: 2

// The audio input open and the list to pick another from, on the input's sheet and in the Input menu
AudioInput :: struct {
    capture:       ^audio.Capture,
    devices:       [dynamic]GuiOption,
    device_index:  int, // in devices, picked on the input's sheet or in the Input menu
    listed:        int, // device_index as build_input_list picked it, another one is a pick
    refresh:       bool, // the list is made again, see follow_input
    default_label: string, // the list's first input, see build_input_list
    menu:          int, // the Input menu, see setup_menu_bar
    restart:       bool, // opens the input again, after the background or an interruption
    missing_s:     f32, // since the picked input was last looked for, see MISSING_INPUT_POLL_S
    stats:         InputStats, // on its sheet, held INPUT_STATS_HOLD_S
    stats_age:     f32,
}

// The input as it's picked and as the system has it. A pick on the input's sheet or in the Input menu is kept
// by its name, for the next start too. The list is made again when the system changed it, or the sheet or the
// menu opens, and every MISSING_INPUT_POLL_S while a picked input is gone, it waits on the system default
// until it's back. Before the frame copies the config, the name the config had is freed here.
follow_input :: proc(app: ^App) {
    input := &app.input
    capture := input.capture

    // Picked since the last frame, the list's own pick is listed
    if input.device_index != input.listed {
        picked := picked_device(input)
        set_input_device(app.config, "" if picked == audio.SYSTEM_DEFAULT else audio.device_name(capture, picked))
        input.listed = input.device_index
        app.unsaved = true
    }

    if audio.devices_changed(capture) {
        input.refresh = true
        input.restart = true
    }

    missing := app.config.input_device != "" && audio.find_device(capture, app.config.input_device) == audio.SYSTEM_DEFAULT
    input.missing_s = input.missing_s + gfx.frame_time() if missing else 0
    if input.missing_s >= MISSING_INPUT_POLL_S {
        input.missing_s = 0
        input.refresh = true
    }
    if input.refresh {
        input.refresh = false
        audio.refresh_devices(capture)
        build_input_list(input, app.config.input_device)

        // One may be there now
        if audio.input_failed(capture) do input.restart = true
    }

    if input.restart || picked_device(input) != capture.active_device do switch_input(app)
}

// The list on the input's sheet and in the Input menu: the system default with the device it is now, then
// the devices, none without any. The wanted input, the config's, is picked, the default while it isn't
// connected. The one opened follows in follow_input.
build_input_list :: proc(input: ^AudioInput, wanted_name: string) {
    capture := input.capture
    clear(&input.devices)
    input.device_index, input.listed = 0, 0

    if audio.device_count(capture) > 0 {
        delete(input.default_label)
        default_name := audio.device_name(capture, audio.SYSTEM_DEFAULT)
        if default_name == "" do input.default_label = fmt.aprint("Default")
        else do input.default_label = fmt.aprintf("Default (%s)", default_name)

        append(&input.devices, GuiOption{audio.SYSTEM_DEFAULT, input.default_label})
        wanted := audio.find_device(capture, wanted_name)
        for index in 0 ..< audio.device_count(capture) {
            append(&input.devices, GuiOption{index, audio.device_name(capture, index)})
            if index == wanted do input.device_index = len(input.devices) - 1
        }
        input.listed = input.device_index
    }

    // The default, a line, the devices. As many as there are commands for, the sheet has them all.
    items: [dynamic]gfx.MenuItem
    items.allocator = context.temp_allocator
    for option, index in input.devices[:min(len(input.devices), MAX_INPUT_COMMANDS)] {
        if index == 1 do append(&items, gfx.MenuItem{})
        append(&items, gfx.MenuItem{title = fmt.ctprintf("%s", option.label), command = int(MenuCommand.INPUTS) + index})
    }
    if len(items) == 0 do append(&items, gfx.MenuItem{title = "No Input Found"})

    gfx.set_menu_items(input.menu, items[:])

    // Checked already, the menu may be opening now and show before the next frame's update_menu_checks
    if len(input.devices) > 0 && input.device_index < MAX_INPUT_COMMANDS {
        gfx.set_menu_checked(int(MenuCommand.INPUTS) + input.device_index, true)
    }
}

// The input picked, or the same one again, the measurements start afresh on it. Without any there's nothing
// to open.
switch_input :: proc(app: ^App) {
    app.input.restart = false
    if len(app.input.devices) == 0 do return

    // Nothing of the previous input's carries over
    audio.switch_device(app.input.capture, picked_device(&app.input))
    reset_measurement(&app.measurement)
    reset_spectrum_display(&app.spectrum_display)
    match_input_rate(app)
}

// The measurements at the rate the input opened at, their windows and filters sized for it. Only a new rate
// changes anything, the strobe's windows are retuned to it. Nothing without an input.
match_input_rate :: proc(app: ^App) {
    sample_rate := app.input.capture.sample_rate
    if sample_rate == 0 || sample_rate == app.measurement.strobe_lock_in.sample_rate do return

    set_measurement_sample_rate(&app.measurement, sample_rate)
    set_spectrum_display_sample_rate(&app.spectrum_display, sample_rate)
    retune(&app.measurement, app.config)
}

// The input's index picked in the settings, the open one without a list
picked_device :: proc(input: ^AudioInput) -> i32 {
    if len(input.devices) == 0 do return input.capture.active_device

    return input.devices[input.device_index].id
}
