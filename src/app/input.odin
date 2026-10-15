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
import "../core"
import "../gfx"

// A picked input that's gone is looked for this often, the system says nothing when one is plugged in that
// isn't its default
MISSING_INPUT_POLL_S :: 2

// The input as it's picked and as the system has it. A pick on the input's sheet or in the Input menu is kept
// by its name, for the next start too. The list is made again when the system changed it, or the sheet or the
// menu opens, and every MISSING_INPUT_POLL_S while a picked input is gone, it waits on the system default
// until it's back. Before the frame copies the config, the name the config had is freed here.
follow_input :: proc(app: ^App) {
    capture := app.audio_capture

    // Picked since the last frame, the list's own pick is input_listed
    if app.audio_device_index != app.input_listed {
        picked := picked_device(app)
        set_input_device(app.config, "" if picked == audio.SYSTEM_DEFAULT else audio.device_name(capture, picked))
        app.input_listed = app.audio_device_index
        app.unsaved = true
    }

    if audio.devices_changed(capture) {
        app.refresh_inputs = true
        app.restart_audio = true
    }

    missing := app.config.input_device != "" && audio.find_device(capture, app.config.input_device) == audio.SYSTEM_DEFAULT
    app.missing_input_s = app.missing_input_s + gfx.frame_time() if missing else 0
    if app.missing_input_s >= MISSING_INPUT_POLL_S {
        app.missing_input_s = 0
        app.refresh_inputs = true
    }
    if app.refresh_inputs {
        app.refresh_inputs = false
        audio.refresh_devices(capture)
        list_inputs(app)

        // One may be there now
        if audio.input_failed(capture) do app.restart_audio = true
    }

    if app.restart_audio || picked_device(app) != capture.active_device do switch_input(app)
}

// The list on the input's sheet and in the Input menu: the system default with the device it is now, then
// the devices, none without any. The config's input is picked, the default while it isn't connected. The
// one opened follows in follow_input.
list_inputs :: proc(app: ^App) {
    capture := app.audio_capture
    clear(&app.audio_devices)
    app.audio_device_index, app.input_listed = 0, 0

    if audio.device_count(capture) > 0 {
        delete(app.default_label)
        default_name := audio.device_name(capture, audio.SYSTEM_DEFAULT)
        if default_name == "" do app.default_label = fmt.aprint("Default")
        else do app.default_label = fmt.aprintf("Default (%s)", default_name)

        append(&app.audio_devices, GuiOption{audio.SYSTEM_DEFAULT, app.default_label})
        wanted := audio.find_device(capture, app.config.input_device)
        for index in 0 ..< audio.device_count(capture) {
            append(&app.audio_devices, GuiOption{index, audio.device_name(capture, index)})
            if index == wanted do app.audio_device_index = len(app.audio_devices) - 1
        }
        app.input_listed = app.audio_device_index
    }

    // The default, a line, the devices. As many as there are commands for, the sheet has them all.
    items: [dynamic]gfx.MenuItem
    items.allocator = context.temp_allocator
    for option, index in app.audio_devices[:min(len(app.audio_devices), MAX_INPUT_COMMANDS)] {
        if index == 1 do append(&items, gfx.MenuItem{})
        append(&items, gfx.MenuItem{title = fmt.ctprintf("%s", option.label), command = int(MenuCommand.INPUTS) + index})
    }
    if len(items) == 0 do append(&items, gfx.MenuItem{title = "No Input Found"})

    gfx.set_menu_items(app.input_menu, items[:])

    // Checked already, the menu may be opening now and show before the next frame's update_menu_checks
    if len(app.audio_devices) > 0 && app.audio_device_index < MAX_INPUT_COMMANDS {
        gfx.set_menu_checked(int(MenuCommand.INPUTS) + app.audio_device_index, true)
    }
}

// The input picked, or the same one again, the measurements start afresh on it. Without any there's nothing
// to open.
switch_input :: proc(app: ^App) {
    app.restart_audio = false
    if len(app.audio_devices) == 0 do return

    // Nothing of the previous input's carries over, the readout it held included
    audio.switch_device(app.audio_capture, picked_device(app))
    core.reset_pitch_detector(&app.pitch_detector)
    core.reset_phase_comparator(app.phase_comparator)
    core.reset_scope(&app.scope)
    reset_spectrum_view(&app.spectrum_view)
    app.readout_track, app.traced_track = -1, -1
    app.held_readout = {}
    match_input_rate(app)
}

// The measurements at the rate the input opened at, their windows and filters sized for it. Only a new rate
// changes anything, the strobe's windows are retuned to it. Nothing without an input.
match_input_rate :: proc(app: ^App) {
    sample_rate := app.audio_capture.sample_rate
    if sample_rate == 0 || sample_rate == app.phase_comparator.sample_rate do return

    core.set_pitch_detector_sample_rate(&app.pitch_detector, sample_rate)
    core.set_phase_comparator_sample_rate(app.phase_comparator, sample_rate)
    core.set_scope_sample_rate(&app.scope, sample_rate)
    set_spectrum_view_sample_rate(&app.spectrum_view, sample_rate)
    retune(app)
}

// The input's index picked in the settings, the open one without a list
picked_device :: proc(app: ^App) -> i32 {
    if len(app.audio_devices) == 0 do return app.audio_capture.active_device

    return app.audio_devices[app.audio_device_index].id
}
