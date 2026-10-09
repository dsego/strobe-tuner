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

import "core:fmt"
import "core:math"
import "core:time"

import "../core"
import "../gfx"

// The settings sheet, opened with the sliders icon on the main screen.
// Everything that isn't needed while tuning lives here, the main screen keeps the note lock
// and the strobe speed.

SEGMENT_WIDTH :: 60

// The rows in gui_settings. The display's options page is at least as tall, see DISPLAY_OPTION_ROWS
SETTINGS_ROWS :: 5

// The rows of each display's options page, see gui_display_options
DISPLAY_OPTION_ROWS :: [StrobeDisplayType]int{.STROBE = 8, .SCOPE = 3, .TRACE = 2, .LAMP = 3, .SPECTRUM = 4}

// For the longer labels of the display's options, three of them as wide as the four colors
WIDE_SEGMENT_WIDTH :: 80

// In the order of StrobeDisplayType
DISPLAY_NAMES :: [len(StrobeDisplayType)]cstring{"Strobe", "Scope", "Trace", "Lamp", "Spectrum"}

// The same on the main screen's display button, in caps like the other controls' labels
DISPLAY_LABELS :: [StrobeDisplayType]cstring{.STROBE = "STROBE", .SCOPE = "SCOPE", .TRACE = "TRACE", .LAMP = "LAMP", .SPECTRUM = "SPECTRUM"}

// The display dropdown in the settings, as wide as the Concert A stepper over it
DISPLAY_MENU_WIDTH :: 176

// The labels of the steps below that have three
STEP_LABELS :: []cstring{"Short", "Medium", "Long"}
// The screens' persistence, see PERSISTENCE_STEPS_PERIODS: the scope's word on the scope's and the lamp's
// options, what it does to the stripes on the strobe's
PERSISTENCE_LABEL: cstring : "Persistence"
SMOOTHING_LABEL: cstring : "Motion smoothing"
PERSISTENCE_LABELS :: []cstring{"Off", "Short", "Medium", "Long"}


// The dropdown whose menu is open, one at a time, on the settings', the input's or the instrument's sheet
SettingsMenu :: enum {
    NONE,
    DISPLAY,
    INPUT,
    PICK, // the instrument's sheet, what's tuned to
    INSTRUMENT,
    TUNING,
}

// Opens or closes menu's dropdown, the one that's open stays as it is when another closes
gui_settings_dropdown :: proc(
    open: ^SettingsMenu,
    menu: SettingsMenu,
    rect: gfx.Rect,
    options: []GuiOption,
    selected: ^int,
    left_pad: f32 = 12,
    down := false,
    dividers: []int = nil,
) {
    if gui_dropdown({rect.x, rect.y}, rect.width, options, selected, open^ == menu, left_pad, rect.height, down, dividers) {
        open^ = menu
    } else if open^ == menu {
        open^ = .NONE
    }
}

// Returns close when ✕ is tapped, changed when the strobe or the note detection needs updating. With
// display_options the sheet is the picked display's options, a page of their own behind the › after the
// displays, the ‹ back to the settings. confirm_reset is whether RESET was tapped once and asks.
gui_settings :: proc(
    sheet_layout: SheetLayout,
    config: ^Config,
    display_options: ^bool,
    confirm_reset: ^bool,
    menu: ^SettingsMenu,
) -> (
    close: bool,
    changed: bool,
) {
    // The controls end short of the ✕, the › after the displays sits in the column under it. The display's
    // options line up with them.
    CHEVRON_GAP :: 8
    sheet_layout := sheet_layout
    sheet_layout.end_inset = ICON_SHEET_SIZE + CHEVRON_GAP

    display_names := DISPLAY_NAMES
    if display_options^ {
        back: bool
        close, back = draw_back_header(sheet_layout, display_names[int(config.strobe_display_type)])
        if back do display_options^ = false

        changed = gui_display_options(sheet_layout, config)
        return
    }

    close = draw_sheet_header(sheet_layout, "Settings", VERSION)
    row := 0

    {
        rect := settings_row(sheet_layout, row, "Concert A", 176)
        row += 1
        pitch_standard, ok := gui_stepper(
            rect,
            config.pitch_standard,
            1,
            PITCH_STANDARD_MIN,
            PITCH_STANDARD_MAX,
            config_defaults.pitch_standard,
            "%.0f Hz",
        )
        if ok {
            config.pitch_standard = pitch_standard
            changed = true
        }
    }

    // The displays in a dropdown, its menu opens down over the rows under it and is drawn after them. The ›
    // after it under the ✕ opens the picked display's options.
    display_rect := settings_row(sheet_layout, row, "Display", DISPLAY_MENU_WIDTH)
    row += 1
    {
        right := display_rect.x + display_rect.width
        draw_centered_icon(ICON_CARET_RIGHT, {right + CHEVRON_GAP, display_rect.y, ICON_SHEET_SIZE, display_rect.height}, icon_color, .SHEET)

        // From the control to the sheet's edge, the row's height
        sheet_right := sheet_layout.sheet.x + sheet_layout.sheet.width
        if gui_button(touch_area({right, display_rect.y, sheet_right - right, display_rect.height})) {
            display_options^ = true
        }
    }

    // The displays read the colors and the glow from the config as they draw, nothing to retune
    gui_settings_segmented(sheet_layout, &row, "Colors", {"Red", "Mint", "Amber", "Mono"}, &config.strobe_colorway)

    // Lights the stripes like a lamp behind the disc, in the hue of the colors above
    gui_settings_segmented(sheet_layout, &row, "Retro glow", {"Off", "On"}, &config.strobe_glow)

    {
        // Everything back to the defaults, the presets stay. The first tap asks, the second resets, a tap
        // anywhere else leaves the settings as they are.
        rect := settings_row(sheet_layout, row, "Reset to defaults", 0)
        row += 1
        if gui_small_button(rect.x, rect, "SURE?" if confirm_reset^ else "RESET", warn = confirm_reset^) {
            if confirm_reset^ {
                reset_config(config)
                changed = true
            }
            confirm_reset^ = !confirm_reset^
        } else if gfx.mouse_pressed() {
            confirm_reset^ = false
        }
    }

    {
        options: [len(StrobeDisplayType)]GuiOption
        for name, index in display_names do options[index] = {i32(index), string(name)}

        selected := int(config.strobe_display_type)
        gui_settings_dropdown(menu, .DISPLAY, display_rect, options[:], &selected, down = true)
        config.strobe_display_type = StrobeDisplayType(selected)
    }
    return

    // The header of the display's options, the ‹ before the title back to the settings. Returns close when
    // the ✕ is tapped and back when the ‹ is.
    draw_back_header :: proc(sheet_layout: SheetLayout, title: cstring) -> (close: bool, back: bool) {
        GAP :: 6
        shifted := sheet_layout
        shifted.title.x += ICON_SHEET_SIZE + GAP
        close = draw_sheet_header(shifted, title)
        position := sheet_layout.title
        draw_centered_icon(ICON_CARET_LEFT, {position.x, position.y, ICON_SHEET_SIZE, TITLE_SIZE}, icon_color, .SHEET)

        // From the sheet's edge past the title, as tall as the ✕'s
        right := shifted.title.x + measure_label(pixel_fonts.title, title, 1).x + GAP
        back = gui_button({sheet_layout.sheet.x, sheet_layout.close.y, right - sheet_layout.sheet.x, sheet_layout.close.height})
        return
    }
}

// The picked display's options, a row each. Returns changed when the strobe needs updating.
gui_display_options :: proc(sheet_layout: SheetLayout, config: ^Config) -> (changed: bool) {
    row := 0
    switch config.strobe_display_type {
    case .STROBE:
        gui_settings_segmented(sheet_layout, &row, "Shape", {"Flat", "Wheel", "Curved"}, &config.strobe_shape, WIDE_SEGMENT_WIDTH)

        // What turns the tracks: their own DFT, or the lamp's screen, the strobe the other way
        gui_settings_segmented(sheet_layout, &row, "Turned by", {"Lock-in", "Lamp"}, &config.strobe_source, WIDE_SEGMENT_WIDTH)

        // Harmonic shows a track per partial, vernier the same frequency at different sensitivities
        if gui_settings_segmented(sheet_layout, &row, "Mode", {"Harmonic", "Vernier"}, &config.strobe_mode, WIDE_SEGMENT_WIDTH) {
            changed = true
        }
        // 200% spins twice as fast per cent, for the final adjustment
        if gui_settings_segmented(sheet_layout, &row, "Spin rate", {"100%", "200%"}, &config.strobe_fast, WIDE_SEGMENT_WIDTH) {
            changed = true
        }

        // How long every cents number averages, the readout under the strobe and the labels on the tracks
        // are the same fit. The longer evens out a voice's vibrato into its mean pitch, a turned peg shows
        // later on the numbers while the stripes move at once.
        if gui_steps(sheet_layout, &row, "Readout speed", {"0.15 s", "0.4 s"}, &config.readout_fit_s, READOUT_FIT_STEPS_S) {
            changed = true
        }

        // The stripes smear and calm down on an unsteady note like the lamp's, the same setting as the scope's
        // and the lamp's screen, see strobe_persistence
        gui_persistence_row(sheet_layout, &row, config, SMOOTHING_LABEL)

        // The labels on the tracks: the partial, and how far off it is
        harmonic := config.strobe_mode == .HARMONIC
        gui_settings_segmented(sheet_layout, &row, "Partials", {"Off", "1×", "Hz", "Note"}, &config.partial_labels, enabled = harmonic)
        gui_settings_segmented(sheet_layout, &row, "Track cents", {"Off", "On"}, &config.show_band_cents)
    case .SCOPE:
        // Tapping the scope flips it too
        gui_settings_segmented(sheet_layout, &row, "Sweep", {"Time", "X-Y"}, &config.scope_sweep)
        gui_screen_options(sheet_layout, &row, config)
    case .TRACE:
        gui_steps(sheet_layout, &row, "Span", STEP_LABELS, &config.trace_seconds, TRACE_SPAN_STEPS_S)
        gui_steps(sheet_layout, &row, "Range", {"Narrow", "Wide"}, &config.trace_range_cents, TRACE_RANGE_STEPS_CENTS)
    case .LAMP:
        // The positive half of the wave like a mechanical strobe's lamp, or the wave as it is
        gui_settings_segmented(sheet_layout, &row, "Rectifier", {"Half", "None"}, &config.lamp_shape)
        gui_screen_options(sheet_layout, &row, config)
    case .SPECTRUM:
        gui_steps(sheet_layout, &row, "Average", STEP_LABELS, &config.spectrum_average_s, SPECTRUM_AVERAGE_STEPS_S)
        gui_settings_segmented(sheet_layout, &row, "Scale", {"SNR", "dBFS"}, &config.spectrum_scale)
        gui_settings_segmented(sheet_layout, &row, "Labels", {"Off", "Note", "Hz", "Both"}, &config.spectrum_labels)
        gui_settings_segmented(sheet_layout, &row, "Peak level", {"Off", "On"}, &config.spectrum_peak_level)
    }
    return

    // The scope's and the lamp's screen. Held, a note's decay shows, the wave shrinks and the stripes dim
    // like a mechanical strobe's lamp. Auto keeps a fading note filling the screen.
    gui_screen_options :: proc(sheet_layout: SheetLayout, row: ^int, config: ^Config) {
        gui_persistence_row(sheet_layout, row, config, PERSISTENCE_LABEL)
        gui_settings_segmented(sheet_layout, row, "Gain", {"Auto", "Hold"}, &config.scope_gain)
    }
}

// The screens' persistence, the same row on the strobe's, the scope's and the lamp's options under its label
// for each. A long label leaves less room on a narrow phone, the segments shrink to fit beside it.
gui_persistence_row :: proc(sheet_layout: SheetLayout, row: ^int, config: ^Config, label: cstring) {
    LABEL_GAP :: 12
    labels := PERSISTENCE_LABELS
    room := sheet_layout.width - sheet_layout.end_inset - measure_label(pixel_fonts.label, label, 1).x - LABEL_GAP
    segment_width := min(SEGMENT_WIDTH, room / f32(len(labels)))
    gui_steps(sheet_layout, row, label, labels, &config.persistence_periods, PERSISTENCE_STEPS_PERIODS, segment_width)
}

// A settings row of a value that's one of a few steps, a label each. None is picked for a value set in the
// config file between them. Returns whether a tap changed value.
gui_steps :: proc(
    sheet_layout: SheetLayout,
    row: ^int,
    label: cstring,
    labels: []cstring,
    value: ^f32,
    steps: [$N]f32,
    segment_width: f32 = WIDE_SEGMENT_WIDTH,
) -> bool {
    step := -1
    for step_value, index in steps {
        if value^ == step_value do step = index
    }
    if !gui_settings_segmented(sheet_layout, row, label, labels, &step, segment_width) do return false

    value^ = steps[step]
    return true
}


// A track's own sheet, opened by tapping it on the strobe in harmonic mode. Shorter than the settings so the
// strobe stays in sight while the track is tuned. Returns close when ✕ is tapped, changed when the strobe
// needs updating.
TRACK_SETTINGS_ROWS :: 5 // the last is room for the buttons that add and remove tracks

gui_track_settings :: proc(
    sheet_layout: SheetLayout,
    config: ^Config,
    track: int,
    band: core.PhaseBand,
) -> (
    close: bool,
    changed: bool,
) {
    // The title, then the note the track follows and its target
    title := fmt.ctprintf("Track %d", track + 1)
    in_range := "" if band.in_range else " · too high to show"
    details := fmt.ctprintf("%s · %.1f Hz%s", core.note_name(band.note), band.freq_hz, in_range)
    close = draw_sheet_header(sheet_layout, title, details)

    slot := track_slot(config, track)
    if slot < 0 do return

    // What the track goes back to, the partial of the last preset. A track added on top of it keeps its own.
    options := INTERVAL_OPTIONS
    preset := clamp(config.strobe_intervals_index, 0, len(options) - 1)
    preset_partial := options[preset][slot]
    if preset_partial < 1 do preset_partial = config.strobe_intervals[slot]

    row := 0

    {
        rect := settings_row(sheet_layout, row, "Partial", 176)
        row += 1
        partial := config.strobe_intervals[slot]
        steps, reset := gui_stepper_buttons(rect, partial_text(partial), times = true)
        if reset {
            partial = preset_partial
        } else if steps != 0 {
            partial = step_partial(partial, int(steps))
        }
        if partial != config.strobe_intervals[slot] {
            config.strobe_intervals[slot] = partial
            changed = true
        }
    }

    {
        // The track stands still this far off the exact partial, eg a stretched octave
        rect := settings_row(sheet_layout, row, "Target offset", 176)
        row += 1
        offset := config.strobe_offsets_cents[slot]

        // No sign on the exact partial
        label := fmt.ctprintf("%+.1f¢", offset) if offset != 0 else "0¢"
        steps, reset := gui_stepper_buttons(rect, label)
        if reset do offset = 0

        offset = clamp(offset + steps * TRACK_OFFSET_STEP_CENTS, -TRACK_OFFSET_MAX_CENTS, TRACK_OFFSET_MAX_CENTS)
        if offset != config.strobe_offsets_cents[slot] {
            config.strobe_offsets_cents[slot] = offset
            changed = true
        }
    }

    // On top of the strobe's spin rate, a high partial spins faster than the rest. In percent, × is for partials.
    speed_labels := []cstring{"25%", "50%", "100%", "200%"}
    if gui_steps(sheet_layout, &row, "Spin rate", speed_labels, &config.strobe_speeds[slot], [4]f32{0.25, 0.5, 1, 2}, SEGMENT_WIDTH) {
        changed = true
    }

    {
        rect := settings_row(sheet_layout, row, "Reset track", 0)
        row += 1
        if gui_small_button(rect.x, rect, "RESET") {
            config.strobe_intervals[slot] = preset_partial
            config.strobe_offsets_cents[slot] = 0
            config.strobe_speeds[slot] = 1
            changed = true
        }
    }

    {
        // Not a row: centred at the bottom of the sheet with no label or line and smaller than the
        // controls, these change the strobe and not the track above. Added and removed on top, a new track
        // follows the next whole partial above the one under it, the 1½ fifth is only for picking by hand
        count, top := 0, 0
        for interval, index in config.strobe_intervals {
            if interval < 1 do continue

            count += 1
            top = index
        }
        GAP :: 8
        height: f32 = 28
        remove_width := icon_button_width("Remove")
        width := remove_width + GAP + icon_button_width("Add")
        pos := [2]f32{sheet_layout.rows.x + math.round((sheet_layout.width - width) / 2), sheet_layout.bottom - height}
        // Not above the highest partial, a track added there would be the top one again
        partials := TRACK_PARTIALS
        highest := partials[len(partials) - 1]
        remove := gui_icon_button(pos, height, ICON_MINUS, "Remove", count > 1)
        pos.x += remove_width + GAP
        add := gui_icon_button(pos, height, ICON_PLUS, "Add", top + 1 < core.MAX_BANDS && config.strobe_intervals[top] < highest)
        if add {
            config.strobe_intervals[top + 1] = min(math.floor(config.strobe_intervals[top]) + 1, highest)
            changed = true
        } else if remove {
            config.strobe_intervals[top] = 0

            // Cleared so a track added there later starts fresh
            config.strobe_offsets_cents[top] = 0
            config.strobe_speeds[top] = 1
            changed = true
        }
    }

    return
}


// The input's sheet, opened by tapping its level on the main screen. A phone routes the input itself, built-in
// mic, headset or an audio interface, it has no picker.
INPUT_ROWS :: 4 when gfx.MOBILE else 5

// The input's levels on its sheet, held a moment to be read, see INPUT_STATS_HOLD_S
InputStats :: struct {
    level_dbfs:      f32,
    background_dbfs: f32, // the pitch detection's noise floor, the room with no note
    snr_db:          f32, // the level over it
}

// How long the levels on the input's sheet stay before the next ones, they change every frame
INPUT_STATS_HOLD_S :: 0.25

// The picker, the rate the input runs at and what's measured of it, and how far its level is over the
// background. device_rate is the device's own, sample_rate what's measured after a fast one's decimation.
// Returns close when ✕ is tapped.
gui_input :: proc(
    sheet_layout: SheetLayout,
    device_name: string,
    device_rate: f32,
    sample_rate: f32,
    stats: InputStats,
    audio_devices: []GuiOption,
    audio_device_index: ^int,
    menu: ^SettingsMenu,
) -> (
    close: bool,
) {
    close = draw_sheet_header(sheet_layout, "Input", fmt.ctprintf("%s", device_name))
    row := 0

    // The picker's row, its menu opens down over the rows under it and is drawn after them
    picker: gfx.Rect
    when !gfx.MOBILE {
        picker = settings_row(sheet_layout, row, "Device", 240)
        row += 1
    }

    // Never resampled. A fast one is halved to what's measured, a slow one can't hold the high partials.
    {
        text := khz(sample_rate)
        color := text_color_white
        if device_rate != sample_rate {
            text = fmt.ctprintf("%s, measured at %s", khz(device_rate), khz(sample_rate))
        } else if sample_rate < core.LOW_SAMPLE_RATE {
            text = fmt.ctprintf("%s, nothing over %s", khz(sample_rate), khz(core.MAX_BAND_NORM_FREQ * sample_rate))
            color = warning_color
        }
        if sample_rate == 0 do text = "-"
        value_row(sheet_layout, &row, "Sample rate", text, color)
    }

    value_row(sheet_layout, &row, "Level", decibels(stats.level_dbfs, "dBFS"))
    value_row(sheet_layout, &row, "Noise floor", decibels(stats.background_dbfs, "dBFS"))
    value_row(sheet_layout, &row, "SNR", decibels(stats.snr_db, "dB"))

    when !gfx.MOBILE {
        // TODO: add refresh button to show newly connected devices
        if len(audio_devices) > 0 {
            gui_settings_dropdown(menu, .INPUT, picker, audio_devices, audio_device_index, left_pad = 36, down = true)
            draw_centered_icon(ICON_MICROPHONE, {picker.x + 12, picker.y, ICON_SIZE, picker.height}, icon_color)
        }
    }
    return

    // A row of a value to read, right aligned like the controls
    value_row :: proc(sheet_layout: SheetLayout, row: ^int, label, text: cstring, color := text_color_white) {
        rect := settings_row(sheet_layout, row^, label, 0)
        row^ += 1
        font := pixel_fonts.label
        draw_text_right(font.font, text, {rect.x + rect.width, rect.y + (rect.height - LABEL_SIZE) / 2}, font.size, 1, color)
    }

    // 48 kHz, 44.1 kHz
    khz :: proc(hz: f32) -> cstring {
        if math.mod(hz, 1000) == 0 do return fmt.ctprintf("%.0f kHz", hz / 1000)

        return fmt.ctprintf("%.1f kHz", hz / 1000)
    }

    // A level, none before there is one or for silence
    decibels :: proc(value: f32, unit: string) -> cstring {
        if math.is_nan(value) || math.is_inf(value) do return "-"

        return fmt.ctprintf("%.1f %s", value, unit)
    }
}

// Where the track's partial, offset and speed are in the config, the tracks are the partials above 0
track_slot :: proc(config: ^Config, track: int) -> int {
    count := 0
    for interval, slot in config.strobe_intervals {
        if interval < 1 do continue
        if count == track do return slot

        count += 1
    }
    return -1
}

// The next partial up or down from one of TRACK_PARTIALS or any other set in the config file
step_partial :: proc(partial: f32, steps: int) -> f32 {
    partials := TRACK_PARTIALS
    partial := partial
    for _ in 0 ..< abs(steps) {
        if steps > 0 {
            for candidate in partials {
                if candidate > partial {
                    partial = candidate
                    break
                }
            }
        } else {
            #reverse for candidate in partials {
                if candidate < partial {
                    partial = candidate
                    break
                }
            }
        }
    }
    return partial
}


// 24pt icon in the middle of a 2x larger touch area
gui_settings_button :: proc(position: [2]f32) -> bool {
    draw_icon(ICON_SLIDERS, position, icon_color, .LARGE)
    return gui_button({position.x - 12, position.y - 12, 48, 48})
}


// A settings row of one of a few options, the labels in the order of value's enum, or off and on for a
// bool. Returns whether a tap changed value. Dimmed and dead when not enabled.
gui_settings_segmented :: proc(
    sheet_layout: SheetLayout,
    row: ^int,
    label: cstring,
    labels: []cstring,
    value: ^$T,
    segment_width: f32 = SEGMENT_WIDTH,
    enabled := true,
) -> bool {
    rect := settings_row(sheet_layout, row^, label, f32(len(labels)) * segment_width, enabled)
    row^ += 1
    selected, ok := gui_segmented(rect, labels, int(value^), enabled)
    if !ok do return false

    when T == bool {
        value^ = selected == 1
    } else {
        value^ = T(selected)
    }
    return true
}

// Label on the left, the control right aligned short of the sheet's end_inset, returns where the control
// goes. The label is dimmed when the control isn't enabled.
settings_row :: proc(sheet_layout: SheetLayout, index: int, label: cstring, control_width: f32, enabled := true) -> gfx.Rect {
    left, width, row_height := sheet_layout.rows.x, sheet_layout.width, sheet_layout.row_height
    y := sheet_layout.rows.y + f32(index) * row_height

    color := text_color_light if enabled else text_color_disabled
    draw_label(pixel_fonts.label, label, {left, y + (row_height - LABEL_SIZE) / 2}, color, 1)
    gfx.draw_rect({left, y + row_height - 1}, {width, 1}, settings_separator_color)

    return {
        left + width - sheet_layout.end_inset - control_width,
        y + SHEET_CONTROL_MARGIN,
        control_width,
        row_height - 2 * SHEET_CONTROL_MARGIN,
    }
}

// The pills are slimmer than a finger, taps anywhere in the height of their row count
touch_area :: proc(rect: gfx.Rect) -> gfx.Rect {
    return {rect.x, rect.y - SHEET_CONTROL_MARGIN, rect.width, rect.height + 2 * SHEET_CONTROL_MARGIN}
}


// For what can't be undone, a reset or a clear: smaller than the controls and in capitals, it isn't tapped
// in passing. right is its right edge, control is where settings_row puts the row's control, the button is
// in its middle and the touch area as tall as the row. Dimmed and dead when not enabled. warn is the
// question it asks first, SURE? in amber.
gui_small_button :: proc(right: f32, control: gfx.Rect, label: cstring, enabled := true, warn := false) -> bool {
    HEIGHT :: 26

    font := pixel_fonts.label_small
    width := small_button_width(label)
    middle := control.y + control.height / 2
    rect := gfx.Rect{right - width, middle - HEIGHT / 2, width, HEIGHT}
    touch := touch_area({rect.x, control.y, width, control.height})

    fill := pill_gray if enabled && gui_button_held(touch) else pill_dark
    label_color := text_color_white if enabled else text_color_disabled
    if warn do fill, label_color = pill_yellow, text_color_dark

    gfx.draw_pill(rect, fill)
    draw_label(font, label, {rect.x + SMALL_BUTTON_PADDING, middle - LABEL_SMALL_SIZE / 2}, label_color, 1)

    return enabled && gui_button(touch)
}

SMALL_BUTTON_PADDING :: 12 // left and right of the label

// Buttons side by side are lined up by it
small_button_width :: proc(label: cstring) -> f32 {
    return math.round(measure_label(pixel_fonts.label_small, label, 1).x) + 2 * SMALL_BUTTON_PADDING
}


// A narrow pill as wide as its icon and label, pos is its top left. Dimmed and dead when not enabled.
gui_icon_button :: proc(
    pos: [2]f32,
    height: f32,
    icon: cstring,
    label: cstring,
    enabled := true,
) -> bool {
    rect := gfx.Rect{pos.x, pos.y, icon_button_width(label), height}

    held := enabled && gui_button_held(touch_area(rect))
    gfx.draw_pill(rect, pill_gray if held else pill_dark)
    draw_centered_icon(
        icon,
        {pos.x + ICON_BUTTON_PADDING, pos.y, ICON_SIZE, height},
        icon_color if enabled else text_color_disabled,
    )
    draw_label(
        pixel_fonts.label,
        label,
        pos + {ICON_BUTTON_PADDING + ICON_SIZE + ICON_BUTTON_GAP, (height - LABEL_SIZE) / 2},
        text_color_white if enabled else text_color_disabled,
        1,
    )

    return enabled && gui_button(touch_area(rect))
}

ICON_BUTTON_PADDING :: 10 // left of the icon and right of the label
ICON_BUTTON_GAP :: 5 // between the icon and the label

// How wide gui_icon_button draws the label, to lay a few of them out before drawing
icon_button_width :: proc(label: cstring) -> f32 {
    return 2 * ICON_BUTTON_PADDING + ICON_SIZE + ICON_BUTTON_GAP + measure_label(pixel_fonts.label, label, 1).x
}


// One of a few options, the selected one is a yellow pill on a dark track. Dimmed and dead when not enabled.
gui_segmented :: proc(rect: gfx.Rect, labels: []cstring, selected: int, enabled := true) -> (int, bool) {
    gfx.draw_pill(rect, pill_dark)

    segment_width := rect.width / f32(len(labels))
    for label, index in labels {
        segment := gfx.Rect{rect.x + f32(index) * segment_width, rect.y, segment_width, rect.height}

        if index == selected {
            // Inset so the track shows around it, the radius shrinks by as much and the ends stay concentric
            INSET :: 2
            fill := pill_yellow if enabled else text_color_disabled
            gfx.draw_pill({segment.x + INSET, segment.y + INSET, segment.width - 2 * INSET, segment.height - 2 * INSET}, fill)
            draw_centered_label(label, segment, text_color_dark)
        } else {
            draw_centered_label(label, segment, text_color_light if enabled else text_color_disabled)
            if enabled && gui_button(touch_area(segment)) do return index, true
        }
    }

    return selected, false
}


// A value with - and + on either side
gui_stepper :: proc(rect: gfx.Rect, value, step, low, high, default: f32, format: string) -> (f32, bool) {
    steps, reset := gui_stepper_buttons(rect, fmt.ctprintf(format, value))
    if reset do return default, true
    if steps != 0 do return clamp(value + steps * step, low, high), true

    return value, false
}

// The - and + around label, times puts a × after it. Returns the steps taken or reset when the label is
// double clicked. Dimmed and dead when not enabled.
gui_stepper_buttons :: proc(
    rect: gfx.Rect,
    label: cstring,
    times := false,
    enabled := true,
) -> (
    steps: f32,
    reset: bool,
) {
    gfx.draw_pill(rect, pill_dark)

    button_width: f32 = 44
    minus := gfx.Rect{rect.x, rect.y, button_width, rect.height}
    plus := gfx.Rect{rect.x + rect.width - button_width, rect.y, button_width, rect.height}

    if !enabled {
        draw_centered_icon(ICON_MINUS, minus, text_color_disabled)
        draw_centered_label(label, rect, text_color_disabled)
        draw_centered_icon(ICON_PLUS, plus, text_color_disabled)
        return
    }

    draw_centered_icon(ICON_MINUS, minus, icon_color)
    if times {
        // The larger × centred on the same line as the digits, the pair centred together
        TIMES :: "×"
        label_width := measure_label(pixel_fonts.label, label, 1).x
        times_width := measure_label(pixel_fonts.label_times, TIMES).x
        x := rect.x + (rect.width - label_width - times_width) / 2
        y := rect.y + (rect.height - LABEL_SIZE) / 2
        draw_label(pixel_fonts.label, label, {x, y}, text_color_white, 1)
        draw_label(pixel_fonts.label_times, TIMES, {x + label_width, y - (LABEL_TIMES_SIZE - LABEL_SIZE) / 2}, text_color_white)
    } else {
        draw_centered_label(label, rect, text_color_white)
    }
    draw_centered_icon(ICON_PLUS, plus, icon_color)

    if gui_button_repeat(touch_area(minus)) do return -1, false
    if gui_button_repeat(touch_area(plus)) do return 1, false

    // Double clicking the value between the buttons puts it back to the default, both clicks on this stepper
    if gui_button(touch_area({minus.x + minus.width, rect.y, plus.x - minus.x - minus.width, rect.height})) {
        now := time.tick_now()
        double_click := stepper_click_rect == rect && time.tick_diff(stepper_last_click, now) < 400 * time.Millisecond
        stepper_last_click = now
        stepper_click_rect = rect
        if double_click do return 0, true
    }

    // Scrolling over the stepper steps too, trackpads scroll in fractions so add them up to whole steps.
    // Only the stepper under the mouse keeps the fraction, with a few on a sheet.
    if gfx.point_in_rect(gfx.mouse_position(), touch_area(rect)) && !exclusive_control_mode && !gui_disabled {
        if stepper_scroll_rect != rect do stepper_scroll = 0

        stepper_scroll_rect = rect
        stepper_scroll += gfx.mouse_wheel()
        steps = math.trunc(stepper_scroll)
        stepper_scroll -= steps
    } else if stepper_scroll_rect == rect {
        stepper_scroll = 0
    }

    return steps, false
}

stepper_scroll: f32
stepper_scroll_rect: gfx.Rect
stepper_last_click: time.Tick
stepper_click_rect: gfx.Rect


draw_centered_label :: proc(label: cstring, rect: gfx.Rect, color: gfx.Color) {
    width := measure_label(pixel_fonts.label, label, 1).x
    draw_label(pixel_fonts.label, label, {rect.x + (rect.width - width) / 2, rect.y + (rect.height - LABEL_SIZE) / 2}, color, 1)
}
