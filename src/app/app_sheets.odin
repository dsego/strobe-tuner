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


package app

import "core:math"

import "../audio"
import "../core"
import "../gfx"

// The sheets over the main screen, one is up at a time, see draw_sheets
AppSheets :: struct {
    settings:        Sheet,
    display_options: bool, // the settings sheet shows the display's options, see gui_settings
    reset_confirm:   bool, // RESET on the settings sheet was tapped once and asks
    track:           Sheet, // a track's own, opened by tapping the track
    selected_track:  int,
    instrument:      Sheet, // the instruments and the presets, opened from the bottom left corner
    input:           Sheet, // the picker, the rate and the levels, opened by tapping the input's level
    open_dropdown:   Dropdown, // the dropdown whose menu is open, on the settings, the instrument or the input sheet
}

all_sheets :: proc(sheets: ^AppSheets) -> [4]^Sheet {
    return {&sheets.settings, &sheets.track, &sheets.instrument, &sheets.input}
}

// Settings… from the menu bar or Ctrl+, closes the settings when they're up, the sheet covers the strobe
toggle_settings_sheet :: proc(sheets: ^AppSheets) {
    if sheets.settings.open do close_settings_sheet(sheets)
    else do open_settings_sheet(sheets)
}

// Over whichever sheet is up
open_settings_sheet :: proc(sheets: ^AppSheets) {
    for sheet in all_sheets(sheets) do if sheet != &sheets.settings do dismiss_sheet(sheets, sheet)
    reset_note_offsets_editing()

    sheets.settings.open = true
    sheets.display_options = false
    sheets.reset_confirm = false
}

close_settings_sheet :: proc(sheets: ^AppSheets) {
    dismiss_sheet(sheets, &sheets.settings)
    sheets.reset_confirm = false
}

// Closed with the dropdown menu that may be open on it
dismiss_sheet :: proc(sheets: ^AppSheets, sheet: ^Sheet) {
    close_sheet(sheet)
    sheets.open_dropdown = .NONE
    gui.menu_open = false
}

// The sheets that are up, over the main screen
draw_sheets :: proc(app: ^App, layout: Layout, reading: Reading) {
    // Android's back button is Escape. It closes a sheet, with none up it leaves the app as anywhere else.
    when gfx.ANDROID {
        sheets_down := true
        for sheet in all_sheets(&app.sheets) do sheets_down &&= sheet.slide == 0
        if gfx.key_pressed(.ESCAPE) && sheets_down do gfx.system_back()
    }

    draw_settings_sheet(app, layout)
    draw_track_sheet(app, layout)
    draw_instrument_sheet(app, layout)
    draw_input_sheet(app, layout, reading)
}

draw_settings_sheet :: proc(app: ^App, layout: Layout) {
    sheets := &app.sheets
    sheet := &sheets.settings
    if sheet.slide == 0 do return

    // The display's options page has rows of its own, the strobe's more than the settings
    rows := settings_rows()
    if sheets.display_options {
        option_rows := DISPLAY_OPTION_ROWS
        rows = max(rows, option_rows[app.config.strobe_display_type])
    }

    sheet_layout, swiped := begin_sheet(sheet, rows, layout)
    close, changed := gui_settings(sheet_layout, app.config, &sheets.display_options, &sheets.reset_confirm, &sheets.open_dropdown)
    if changed do app.config_changed = true

    grab_sheet(sheet, sheet_layout)

    // Escape goes back from the display's options like the ‹
    if sheets.display_options && gfx.key_pressed(.ESCAPE) {
        sheets.display_options = false
    } else if close || sheet_dismissed(sheet_layout, swiped) {
        close_settings_sheet(sheets)
    }
}

draw_track_sheet :: proc(app: ^App, layout: Layout) {
    sheets := &app.sheets
    sheet := &sheets.track
    if sheet.slide == 0 do return

    config := app.config
    bands := app.measurement.strobe_lock_in.bands[:]
    sheet_layout, swiped := begin_sheet(sheet, TRACK_SETTINGS_ROWS, layout)
    sheets.selected_track = min(sheets.selected_track, len(bands) - 1)
    close, changed := gui_track_settings(sheet_layout, config, sheets.selected_track, bands[sheets.selected_track])
    if changed do app.config_changed = true

    grab_sheet(sheet, sheet_layout)

    // Tapping another track outside the sheet switches to it, anywhere else closes the sheet
    if gui_button(sheet_layout.outside) {
        track := strobe_track_at(config.strobe_shape, layout.strobe, layout.strobe_scale, layout.strobe_turned, len(bands), gfx.mouse_position())
        if track >= 0 do sheets.selected_track = track
        else do close = true
    }

    if close || gfx.key_pressed(.ESCAPE) || swiped do close_sheet(sheet)
}

draw_instrument_sheet :: proc(app: ^App, layout: Layout) {
    sheets := &app.sheets
    sheet := &sheets.instrument
    if sheet.slide == 0 do return

    // Over the whole window, room for every note offset of a preset
    sheet_layout, swiped := begin_sheet(sheet, 0, layout, gfx.window_size().y)

    // A new offset starts on the note the strobe is on
    target := -1
    if index, in_range := core.note_index(app.measurement.note_target.target_note); in_range {
        target = index
    }
    close, changed := gui_instrument(sheet_layout, app.config, &sheets.open_dropdown, target)
    if changed {
        app.config_changed = true

        // Other notes on the ruler, it starts again on the target
        note_ruler.initialized = false
    }
    grab_sheet(sheet, sheet_layout)

    if close || sheet_dismissed(sheet_layout, swiped) {
        dismiss_sheet(sheets, sheet)
        reset_note_offsets_editing()
    }
}

draw_input_sheet :: proc(app: ^App, layout: Layout, reading: Reading) {
    sheets := &app.sheets
    sheet := &sheets.input
    if sheet.slide == 0 do return

    // A few times a second, the latest detection's
    input := &app.input
    input.stats_age += gfx.frame_time()
    if input.stats_age >= INPUT_STATS_HOLD_S {
        pitch := reading.pitch

        // The floor is the level's average, quiet wobbles under it, the SNR of the background is 0. None
        // until something was measured, e.g. without an input, a reading that isn't one would be 0 dBFS.
        none := math.nan_f32()
        input.stats = {none, none, none}
        if pitch.measured do input.stats = {pitch.rms_dbfs, core.dbfs(pitch.noise_floor), max(pitch.snr_db, 0)}
        input.stats_age = 0
    }

    capture := input.capture
    device_name := "No input"
    if audio.device_count(capture) > 0 do device_name = audio.device_name(capture, capture.active_device)

    sheet_layout, swiped := begin_sheet(sheet, INPUT_ROWS, layout)
    close := gui_audio_input(
        sheet_layout,
        device_name,
        capture.device_rate,
        capture.sample_rate,
        input.stats,
        input.devices[:],
        &input.device_index,
        &sheets.open_dropdown,
    )
    grab_sheet(sheet, sheet_layout)

    if close || sheet_dismissed(sheet_layout, swiped) {
        dismiss_sheet(sheets, sheet)
    }
}
