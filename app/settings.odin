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
import "core:math"
import "core:time"

import "../core"

// The settings sheet, opened with the sliders icon on the main screen.
// Everything that isn't needed while tuning lives here, the main screen keeps the note lock
// and the strobe speed.

PITCH_STANDARD_MIN :: 400
PITCH_STANDARD_MAX :: 480

SEGMENT_WIDTH :: 60

// The rows in gui_settings, the display's take DISPLAY_ROWS, iOS has no input row
SETTINGS_ROWS :: 8 when IOS else 9

// The display's rows: its label and the displays listed down the left, the picked one's options on the
// right. As many rows as the strobe's options, the most of any display, so the rows under them stay put
// when the display changes. An option's control is a fifth smaller than a row's, its label before it, and
// the whole row is its touch area.
DISPLAY_ROWS :: 4
DISPLAY_LIST_WIDTH :: 76
OPTION_SEGMENT_WIDTH :: 0.8 * SEGMENT_WIDTH
OPTION_WIDE_SEGMENT_WIDTH :: 60 // for longer labels, Persistence and its three fit beside the list on an iPhone SE
OPTION_CONTROL_HEIGHT :: 0.8 * (SHEET_ROW_HEIGHT - 2 * SHEET_CONTROL_MARGIN)
OPTION_LABEL_GAP :: 8

// The scope's and the lamp's persistence, short, medium and long
SCOPE_PERSISTENCE_STEPS_MS :: [3]f32{15, 40, 150}
// The trace's span, short, medium and long, and its range from the middle to the edge, narrow and wide.
// Narrow for an instrument's pluck settling, wide for a voice's vibrato, half a semitone is as far as a
// note can be off before it's the next one.
TRACE_SPAN_STEPS_S :: [3]f32{1, 2, 5}
TRACE_RANGE_STEPS_CENTS :: [2]f32{25, 50}

settings_separator_color := hex(0x35363EFF)


// The dropdown whose menu is open, one at a time, on the settings or the instrument's sheet
SettingsMenu :: enum {
    NONE,
    INPUT,
    PICK, // the instrument's sheet, what's tuned to
    INSTRUMENT,
    TUNING,
}

// Opens or closes menu's dropdown, the one that's open stays as it is when another closes
gui_settings_dropdown :: proc(
    open: ^SettingsMenu,
    menu: SettingsMenu,
    rect: Rect,
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

// Returns close when ✕ is tapped, changed when the strobe or the note detection needs updating
gui_settings :: proc(
    sheet_layout: SheetLayout,
    config: ^Config,
    audio_devices: []GuiOption,
    audio_device_index: ^int,
    menu: ^SettingsMenu,
) -> (
    close: bool,
    changed: bool,
) {
    close = draw_sheet_header(sheet_layout, "Settings")
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

    if gui_display_rows(sheet_layout, row, config) do changed = true
    row += DISPLAY_ROWS

    if gui_settings_segmented(sheet_layout, &row, "Colors", {"Red", "Mint", "Amber", "Mono"}, &config.strobe_colorway) {
        changed = true
    }
    // Lights the stripes like a lamp behind the disc, in the hue of the colors above
    if gui_settings_segmented(sheet_layout, &row, "Retro glow", {"Off", "On"}, &config.strobe_glow) {
        changed = true
    }
    // iOS routes the input itself: built-in mic, headset or an audio interface
    when !IOS {
        // The menu opens upwards over the rows above
        input_rect := settings_row(sheet_layout, row, "Input", 240)
        row += 1

        // TODO: add refresh button to show newly connected devices
        gui_settings_dropdown(menu, .INPUT, input_rect, audio_devices, audio_device_index, left_pad = 36)

        draw_icon(ICON_MICROPHONE, {input_rect.x + 12, input_rect.y + (input_rect.height - 16) / 2}, icon_color)
    }

    {
        // Everything back to the defaults like the R key, including what's only in the config file
        rect := settings_row(sheet_layout, row, "Reset to defaults", 0)
        row += 1
        if gui_small_button(rect.x, rect.y + rect.height / 2, "RESET") {
            reset_config(config)
            changed = true
        }
    }

    return

    // The display's DISPLAY_ROWS from first_row: its label and the displays down the left, the picked one's
    // options on the right, one a row. Returns changed when the strobe needs updating. The trace has nothing
    // to set.
    gui_display_rows :: proc(sheet_layout: SheetLayout, first_row: int, config: ^Config) -> (changed: bool) {
        left, width, row_height := sheet_layout.rows.x, sheet_layout.width, sheet_layout.row_height
        top := sheet_layout.rows.y + f32(first_row) * row_height
        draw_label(pixel_fonts.label, "Display", {left, top + (row_height - LABEL_SIZE) / 2}, text_color_light, 1)
        draw_rect({left, top + DISPLAY_ROWS * row_height - 1}, {width, 1}, settings_separator_color)

        // In the order of StrobeDisplayType, under the label, its pills as tall as a row's
        item_height := row_height - 2 * SHEET_CONTROL_MARGIN
        list_height := f32(len(StrobeDisplayType)) * item_height
        list := Rect{left, top + row_height + ((DISPLAY_ROWS - 1) * row_height - list_height) / 2, DISPLAY_LIST_WIDTH, list_height}
        gui_display_list(list, {"Strobe", "Scope", "Trace", "Lamp"}, &config.strobe_display_type)

        // A row each, the label right before the control at the right edge
        options := Rect{left, top, width, row_height}
        switch config.strobe_display_type {
        case .STROBE:
            gui_option(options, 0, "Shape", {"Flat", "Wheel", "Curved"}, &config.strobe_shape)
            // What turns the tracks: their own DFT, or the lamp's screen, the strobe the other way
            gui_option(options, 1, "Turned by", {"Lock-in", "Lamp"}, &config.strobe_source, OPTION_WIDE_SEGMENT_WIDTH)
            // Harmonic shows a track per partial, fine the same frequency at different sensitivities
            if gui_option(options, 2, "Mode", {"Harmonic", "Fine"}, &config.strobe_mode, OPTION_WIDE_SEGMENT_WIDTH) {
                changed = true
            }
            harmonic := config.strobe_mode == .HARMONIC
            gui_option(options, 3, "Partials", {"Off", "1×", "Hz", "Note"}, &config.partial_labels, enabled = harmonic)
        case .SCOPE:
            // Tapping the scope flips it too
            gui_option(options, 0, "Sweep", {"Time", "X-Y"}, &config.scope_sweep)
            gui_steps(options, 1, "Persistence", {"Short", "Medium", "Long"}, &config.scope_persistence_ms, SCOPE_PERSISTENCE_STEPS_MS)
            // Hold shows the note's decay, auto keeps a fading note filling the screen
            gui_option(options, 2, "Gain", {"Auto", "Hold"}, &config.scope_gain)
        case .TRACE:
            gui_steps(options, 0, "Span", {"Short", "Medium", "Long"}, &config.trace_seconds, TRACE_SPAN_STEPS_S)
            gui_steps(options, 1, "Range", {"Narrow", "Wide"}, &config.trace_range_cents, TRACE_RANGE_STEPS_CENTS)
        case .LAMP:
            // The positive half of the wave like a mechanical strobe's lamp, or the wave as it is
            gui_option(options, 0, "Rectifier", {"Half", "None"}, &config.lamp_shape)
            gui_steps(options, 1, "Persistence", {"Short", "Medium", "Long"}, &config.scope_persistence_ms, SCOPE_PERSISTENCE_STEPS_MS)
            // Held, the stripes dim as the note decays like a mechanical strobe's lamp
            gui_option(options, 2, "Gain", {"Auto", "Hold"}, &config.scope_gain)
        }
        return

        // A vertical segmented control, an item a tap
        gui_display_list :: proc(rect: Rect, labels: []cstring, value: ^StrobeDisplayType) {
            item_height := rect.height / f32(len(labels))
            draw_rounded_rect(rect, item_height / 2, pill_dark)
            for label, index in labels {
                item := Rect{rect.x, rect.y + f32(index) * item_height, rect.width, item_height}
                if index == int(value^) {
                    INSET :: 2
                    draw_pill({item.x + INSET, item.y + INSET, item.width - 2 * INSET, item.height - 2 * INSET}, pill_yellow)
                    draw_centered_label(label, item, text_color_dark)
                } else {
                    draw_centered_label(label, item, text_color_light)
                    if gui_button(item) do value^ = StrobeDisplayType(index)
                }
            }
        }

        // A value that's one of a few steps, a label each. None is picked for a value set in the config file
        // between them.
        gui_steps :: proc(options: Rect, slot: int, label: cstring, labels: []cstring, value: ^f32, steps: [$N]f32) {
            step := -1
            for step_value, index in steps {
                if value^ == step_value do step = index
            }
            if gui_option(options, slot, label, labels, &step, OPTION_WIDE_SEGMENT_WIDTH) {
                value^ = steps[step]
            }
        }

        // An option in its row counted from the first of options, the control in the order of value's enum.
        // Returns whether a tap changed value.
        gui_option :: proc(
            options: Rect,
            slot: int,
            label: cstring,
            labels: []cstring,
            value: ^$T,
            segment_width: f32 = OPTION_SEGMENT_WIDTH,
            enabled := true,
        ) -> bool {
            top := options.y + f32(slot) * options.height
            width := f32(len(labels)) * segment_width
            control := Rect {
                options.x + options.width - width,
                top + (options.height - OPTION_CONTROL_HEIGHT) / 2,
                width,
                OPTION_CONTROL_HEIGHT,
            }
            font := pixel_fonts.label_small
            label_width := measure_label(font, label, 1).x
            color := text_color_light if enabled else text_color_disabled
            draw_label(font, label, {control.x - OPTION_LABEL_GAP - label_width, top + (options.height - font.size) / 2}, color, 1)

            // The whole height of the row is the touch area
            reach := (options.height - OPTION_CONTROL_HEIGHT) / 2
            selected, ok := gui_segmented(control, labels, int(value^), enabled, small = true, reach = {reach, reach})
            if ok do value^ = T(selected)
            return ok
        }
    }
}


// A track's own sheet, opened by tapping it on the strobe in harmonic mode. Shorter than the settings so the
// strobe stays in sight while the track is tuned. Returns close when ✕ is tapped, changed when the strobe
// needs updating.
TRACK_SETTINGS_ROWS :: 5 // the last is room for the buttons that add and remove tracks

// The partials a track can follow, 1½ is the fifth above the fundamental like in the 1 1½ 2 preset
TRACK_PARTIALS :: [?]f32{1, 1.5, 2, 3, 4, 5, 6, 7, 8}
TRACK_OFFSET_MAX_CENTS :: 50
TRACK_OFFSET_STEP_CENTS :: 0.5

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

    {
        // On top of the strobe speed, a high partial spins faster than the rest. In percent, × is for partials.
        speeds := [?]f32{0.25, 0.5, 1, 2}
        labels := []cstring{"25%", "50%", "100%", "200%"}
        rect := settings_row(sheet_layout, row, "Speed", f32(len(labels)) * SEGMENT_WIDTH)
        row += 1
        selected := -1
        for speed, index in speeds {
            if config.strobe_speeds[slot] == speed do selected = index
        }
        if tapped, ok := gui_segmented(rect, labels, selected); ok {
            config.strobe_speeds[slot] = speeds[tapped]
            changed = true
        }
    }

    {
        rect := settings_row(sheet_layout, row, "Reset track", 0)
        row += 1
        if gui_small_button(rect.x, rect.y + rect.height / 2, "RESET") {
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
        for interval, slot in config.strobe_intervals {
            if interval < 1 do continue
            count += 1
            top = slot
        }
        GAP :: 8
        height: f32 = 28
        remove_width := icon_button_width("Remove")
        width := remove_width + GAP + icon_button_width("Add")
        pos := [2]f32{sheet_layout.rows.x + math.round((sheet_layout.width - width) / 2), sheet_layout.bottom - height}
        remove := gui_icon_button(pos, height, ICON_MINUS, "Remove", count > 1)
        pos.x += remove_width + GAP
        add := gui_icon_button(pos, height, ICON_PLUS, "Add", top + 1 < core.MAX_BANDS)
        if add {
            partials := TRACK_PARTIALS
            config.strobe_intervals[top + 1] = min(math.floor(config.strobe_intervals[top]) + 1, partials[len(partials) - 1])
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
    draw_icon(ICON_SLIDERS, position, icon_color, large = true)
    return gui_button({position.x - 12, position.y - 12, 48, 48})
}


// A settings row of one of a few options, the labels in the order of value's enum, or off and on for a
// bool. Returns whether a tap changed value.
gui_settings_segmented :: proc(sheet_layout: SheetLayout, row: ^int, label: cstring, labels: []cstring, value: ^$T) -> bool {
    rect := settings_row(sheet_layout, row^, label, f32(len(labels)) * SEGMENT_WIDTH)
    row^ += 1
    selected, ok := gui_segmented(rect, labels, int(value^))
    if !ok do return false
    when T == bool {
        value^ = selected == 1
    } else {
        value^ = T(selected)
    }
    return true
}

// Label on the left, the control right aligned, returns where the control goes
settings_row :: proc(sheet_layout: SheetLayout, index: int, label: cstring, control_width: f32) -> Rect {
    left, width, row_height := sheet_layout.rows.x, sheet_layout.width, sheet_layout.row_height
    y := sheet_layout.rows.y + f32(index) * row_height

    draw_label(pixel_fonts.label, label, {left, y + (row_height - LABEL_SIZE) / 2}, text_color_light, 1)
    draw_rect({left, y + row_height - 1}, {width, 1}, settings_separator_color)

    return {
        left + width - control_width,
        y + SHEET_CONTROL_MARGIN,
        control_width,
        row_height - 2 * SHEET_CONTROL_MARGIN,
    }
}

// The pills are slimmer than a finger, taps anywhere in the height of their row count
touch_area :: proc(rect: Rect) -> Rect {
    return {rect.x, rect.y - SHEET_CONTROL_MARGIN, rect.width, rect.height + 2 * SHEET_CONTROL_MARGIN}
}


// For what can't be undone, a reset or a clear: smaller than the controls and in capitals, it isn't tapped
// in passing. right is its right edge and middle its vertical middle, the touch area is as tall as a row.
// Dimmed and dead when not enabled.
gui_small_button :: proc(right, middle: f32, label: cstring, enabled := true) -> bool {
    HEIGHT :: 26

    font := pixel_fonts.label_small
    width := small_button_width(label)
    rect := Rect{right - width, middle - HEIGHT / 2, width, HEIGHT}
    touch := Rect{rect.x, middle - SHEET_ROW_HEIGHT / 2, width, SHEET_ROW_HEIGHT}

    draw_pill(rect, pill_gray if enabled && gui_button_held(touch) else pill_dark)
    label_color := text_color_white if enabled else text_color_disabled
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
    rect := Rect{pos.x, pos.y, icon_button_width(label), height}

    held := enabled && gui_button_held(touch_area(rect))
    draw_pill(rect, pill_gray if held else pill_dark)
    draw_icon(
        icon,
        pos + {ICON_BUTTON_PADDING, (height - ICON_SIZE) / 2},
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
// small has the smaller labels of a display's options. Taps count as far as reach above and below the pill.
gui_segmented :: proc(
    rect: Rect,
    labels: []cstring,
    selected: int,
    enabled := true,
    small := false,
    reach := [2]f32{SHEET_CONTROL_MARGIN, SHEET_CONTROL_MARGIN},
) -> (
    int,
    bool,
) {
    draw_pill(rect, pill_dark)

    segment_width := rect.width / f32(len(labels))
    for label, index in labels {
        segment := Rect{rect.x + f32(index) * segment_width, rect.y, segment_width, rect.height}

        if index == selected {
            // Inset so the track shows around it, the radius shrinks by as much and the ends stay concentric
            INSET :: 2
            fill := pill_yellow if enabled else text_color_disabled
            draw_pill({segment.x + INSET, segment.y + INSET, segment.width - 2 * INSET, segment.height - 2 * INSET}, fill)
            draw_centered_label(label, segment, text_color_dark, small)
        } else {
            draw_centered_label(label, segment, text_color_light if enabled else text_color_disabled, small)
            touch := Rect{segment.x, segment.y - reach[0], segment.width, segment.height + reach[0] + reach[1]}
            if enabled && gui_button(touch) do return index, true
        }
    }

    return selected, false
}


// A value with - and + on either side
gui_stepper :: proc(rect: Rect, value, step, low, high, default: f32, format: string) -> (f32, bool) {
    steps, reset := gui_stepper_buttons(rect, fmt.ctprintf(format, value))
    if reset do return default, true
    if steps != 0 do return clamp(value + steps * step, low, high), true
    return value, false
}

// The - and + around label, times puts a × after it. Returns the steps taken or reset when the label is
// double clicked. Dimmed and dead when not enabled.
gui_stepper_buttons :: proc(
    rect: Rect,
    label: cstring,
    times := false,
    enabled := true,
) -> (
    steps: f32,
    reset: bool,
) {
    draw_pill(rect, pill_dark)

    button_width: f32 = 44
    minus := Rect{rect.x, rect.y, button_width, rect.height}
    plus := Rect{rect.x + rect.width - button_width, rect.y, button_width, rect.height}

    icon_offset := [2]f32{(button_width - 16) / 2, (rect.height - 16) / 2}
    if !enabled {
        draw_icon(ICON_MINUS, {minus.x, minus.y} + icon_offset, text_color_disabled)
        draw_centered_label(label, rect, text_color_disabled)
        draw_icon(ICON_PLUS, {plus.x, plus.y} + icon_offset, text_color_disabled)
        return
    }

    draw_icon(ICON_MINUS, {minus.x, minus.y} + icon_offset, icon_color)
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
    draw_icon(ICON_PLUS, {plus.x, plus.y} + icon_offset, icon_color)

    if gui_button_repeat(touch_area(minus)) do return -1, false
    if gui_button_repeat(touch_area(plus)) do return 1, false

    // Double clicking the value between the buttons puts it back to the default
    if gui_button(touch_area({minus.x + minus.width, rect.y, plus.x - minus.x - minus.width, rect.height})) {
        now := time.tick_now()
        double_click := time.tick_diff(stepper_last_click, now) < 400 * time.Millisecond
        stepper_last_click = now
        if double_click do return 0, true
    }

    // Scrolling over the stepper steps too, trackpads scroll in fractions so add them up to whole steps.
    // Only the stepper under the mouse keeps the fraction, with a few on a sheet.
    if point_in_rect(mouse_position(), touch_area(rect)) && !exclusive_control_mode && !gui_disabled {
        if stepper_scroll_rect != rect do stepper_scroll = 0
        stepper_scroll_rect = rect
        stepper_scroll += mouse_wheel()
        steps = math.trunc(stepper_scroll)
        stepper_scroll -= steps
    } else if stepper_scroll_rect == rect {
        stepper_scroll = 0
    }

    return steps, false
}

stepper_scroll: f32
stepper_scroll_rect: Rect
stepper_last_click: time.Tick


draw_centered_label :: proc(label: cstring, rect: Rect, color: Color, small := false) {
    font := pixel_fonts.label_small if small else pixel_fonts.label
    width := measure_label(font, label, 1).x
    draw_label(font, label, {rect.x + (rect.width - width) / 2, rect.y + (rect.height - font.size) / 2}, color, 1)
}
