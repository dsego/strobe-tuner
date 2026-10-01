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

import "../core"

// Notes tuned a few cents off equal temperament, e.g. a ukulele's E a little flat so its fretted chords
// sound right, or a guitar's B string a touch low. The strobe stands still at the offset note and the readout
// counts from there. One offset per exact note, a guitar's low and high E are tuned apart. Only presets have
// them, each its own, see gui_instrument.
//
// On the main screen the offset of the note being tuned is under its letter. On the instrument's sheet the
// rows of the selected preset are under its instrument, each a note, its octave and the cents, on a
// stringed instrument a string and its cents. Tapping a row shows its controls. With a finger the controls
// are in a popup over the row instead, see gui_note_offsets. The rows are kept as they are, in their order
// and at 0 cents too, see Config.note_offset_notes.

NOTE_OFFSET_STEP_CENTS :: 0.5
// A string this far from its note is still detected as that note once it's nearly in tune
NOTE_OFFSET_MAX_CENTS :: 25
// Rows in a preset, a 12 string guitar has 10 notes. The sheet shows them all without scrolling.
MAX_NOTE_OFFSETS :: 10

// What each note from A0 is tuned off by, from the rows of the selected preset, a stringed instrument's
// strings as they sound with the capo. None on a built-in instrument.
active_note_offsets :: proc(config: ^Config) -> (offsets: [core.NOTE_COUNT]f32) {
    preset := selected_preset(config)
    if preset < 0 do return
    cents := config.note_offset_cents[preset]
    if strings := tuning_strings(config); len(strings) > 0 {
        for semitone, row in strings {
            index := semitone - core.LOWEST_NOTE
            if row < MAX_NOTE_OFFSETS && index >= 0 && index < core.NOTE_COUNT do offsets[index] = cents[row]
        }
        return
    }
    // A note in more than one row is tuned by the first
    for row := clamp(config.note_offset_counts[preset], 0, MAX_NOTE_OFFSETS) - 1; row >= 0; row -= 1 {
        index := config.note_offset_notes[preset][row]
        if index >= 0 && index < core.NOTE_COUNT do offsets[index] = cents[row]
    }
    return
}


// The selected preset's offsets on the instrument's sheet, under its first rows rows: a row with the title
// and the buttons, then a row an offset. target is the note the tuner is on counted from A0, a new row starts
// there, or -1. Returns true when the rows changed.
gui_note_offsets :: proc(sheet_layout: SheetLayout, rows: int, config: ^Config, target: int) -> (changed: bool) {
    // A value with a button either side that steps it, down on the left. No pill, the icons and the value on
    // the sheet. The touch areas are halves of reach from its left to its right, split at the middle of rect,
    // wider than the icons for a finger. Large in the popup.
    gui_spin :: proc(rect: Rect, reach: [2]f32, label: cstring, down_icon, up_icon: cstring, large := false) -> (step: int) {
        font := pixel_fonts.offset_value if large else pixel_fonts.label
        spacing: f32 = 0 if large else 1
        width := measure_label(font, label, spacing).x
        draw_label(font, label, {rect.x + (rect.width - width) / 2, rect.y + (rect.height - font.size) / 2}, text_color_white, spacing)

        button_width: f32 = 44 if large else 22
        icon_size: f32 = ICON_LARGE_SIZE if large else ICON_SIZE
        icon_font := pixel_fonts.icon_large_bold if large else pixel_fonts.icon
        icon_y := rect.y + (rect.height - icon_size) / 2
        draw_label(icon_font, down_icon, {rect.x + (button_width - icon_size) / 2, icon_y}, icon_color)
        draw_label(icon_font, up_icon, {rect.x + rect.width - (button_width + icon_size) / 2, icon_y}, icon_color)

        middle := rect.x + rect.width / 2
        if gui_button_repeat({reach[0], rect.y, middle - reach[0], rect.height}) do step = -1
        if gui_button_repeat({middle, rect.y, reach[1] - middle, rect.height}) do step = 1
        return
    }

    // How far the note is off pitch along a line, flat to the left of the middle and sharp to the right,
    // the whole half is NOTE_OFFSET_MAX_CENTS. Like the input level: the rounded line again in the light
    // colour, cut off flat where the bar ends. The background shows through in the middle, on pitch.
    draw_offset_bar :: proc(line: Rect, offset: f32, background: Color) {
        SPLIT :: 2
        radius := line.height / 2
        middle := line.x + line.width / 2
        draw_rounded_rect(line, radius, pill_dark)

        length := abs(offset) / NOTE_OFFSET_MAX_CENTS * line.width / 2
        start := middle if offset > 0 else middle - length
        begin_scissor({start, line.y, length, line.height})
        draw_rounded_rect(line, radius, hex(0x82E2FFFF))
        end_scissor()

        draw_rect({middle - SPLIT / 2, line.y}, {SPLIT, line.height}, background)
    }

    sheet := sheet_layout.sheet
    left := sheet_layout.rows.x
    right := left + sheet_layout.width
    sheet_left, sheet_right := sheet.x, sheet.x + sheet.width

    preset := selected_preset(config)
    setup := preset_setup(config, preset)
    transpose := transpose_key(setup)
    // A stringed instrument's rows are its strings, only their cents change
    tuning, _ := setup_tuning(setup)
    stringed := len(tuning.strings) > 0
    count := len(tuning.strings) if stringed else clamp(config.note_offset_counts[preset], 0, MAX_NOTE_OFFSETS)
    notes := &config.note_offset_notes[preset]
    cents := &config.note_offset_cents[preset]

    header := settings_row(sheet_layout, rows, "Note offsets", 0)
    top := header.y - SHEET_CONTROL_MARGIN

    // A row an offset: the note and its octave, the bar, the cents. With a mouse the selected row is lighter
    // and they're steppers, one row at a time, the rows stay where they are. A finger would cover what it
    // steps, tapped the note or the cents open a popup over the row with the steppers large.
    NAMES :: [12]cstring{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
    GAP :: 8
    NOTE_WIDTH :: 74
    OCTAVE_WIDTH :: 58
    BAR_GAP :: 12 // either side of the bar
    CENTS_WIDTH :: 96
    BAR_HEIGHT :: 8
    BUTTONS_HEIGHT :: 26 // as tall as the small buttons
    // From C0 as it's shown, the octave changes at C. Offsets are kept by the sounding note, a transposing
    // instrument reads the written one.
    FROM_C0 :: 57 + core.LOWEST_NOTE

    // No sign on a note that's tuned as usual
    cents_text :: proc(cents: f32) -> cstring {
        return fmt.ctprintf("%+.1f¢", cents) if cents != 0 else "0¢"
    }

    // Around the octave, past the notes that are out of A0 to C8
    step_note :: proc(index, step, transpose: int) -> int {
        shown := index + FROM_C0 + transpose
        for try in 1 ..< 12 {
            candidate := shown - shown %% 12 + (shown + try * step) %% 12 - FROM_C0 - transpose
            if candidate >= 0 && candidate < core.NOTE_COUNT do return candidate
        }
        return index
    }

    step_octave :: proc(index, step: int) -> int {
        candidate := index + 12 * step
        return candidate if candidate >= 0 && candidate < core.NOTE_COUNT else index
    }

    step_cents :: proc(cents: f32, step: int) -> f32 {
        return clamp(cents + f32(step) * NOTE_OFFSET_STEP_CENTS, -NOTE_OFFSET_MAX_CENTS, NOTE_OFFSET_MAX_CENTS)
    }

    // Taller rows where all of them fit, on a phone, shorter ones for the mouse on the desktop. As tall as
    // the most rows there can be, a row added doesn't move the others.
    ROW_HEIGHT_MIN :: 32
    ROW_HEIGHT_MAX :: 60
    rows_top := top + sheet_layout.row_height
    room := sheet_layout.bottom - rows_top
    most := count if stringed else MAX_NOTE_OFFSETS
    row_height := clamp(math.floor(room / f32(max(most, 1))), ROW_HEIGHT_MIN, ROW_HEIGHT_MAX)
    name_width: f32 = NOTE_WIDTH + GAP + OCTAVE_WIDTH // the note and octave together, over their steppers
    bar_x := left + name_width + BAR_GAP
    cents_x := right - CENTS_WIDTH

    // The popup over the row, on what was tapped, or under the row near the top of the sheet. One line like
    // the row, the steppers large: the note and the octave, or the cents.
    POPUP_HEIGHT :: 64
    POPUP_PAD :: 8
    POPUP_GAP :: 4 // between the note and the octave
    POPUP_NOTE_WIDTH :: 140
    POPUP_OCTAVE_WIDTH :: 116
    POPUP_CENTS_WIDTH :: 200
    popup_rect :: proc(width, anchor_x, row_y, row_height, min_y: f32, sheet: Rect) -> Rect {
        GAP :: 10 // from the row, the balloon's point reaches most of the way
        x := clamp(anchor_x - width / 2, sheet.x + POPUP_PAD, sheet.x + sheet.width - POPUP_PAD - width)
        y := row_y - GAP - POPUP_HEIGHT
        if y < min_y do y = row_y + row_height + GAP
        return {x, y, width, POPUP_HEIGHT}
    }
    popup_widths := [NoteOffsetPopup]f32 {
        .NONE  = 0,
        .NOTE  = 2 * POPUP_PAD + POPUP_NOTE_WIDTH + POPUP_GAP + POPUP_OCTAVE_WIDTH,
        .CENTS = 2 * POPUP_PAD + POPUP_CENTS_WIDTH,
    }
    anchors := [NoteOffsetPopup]f32 {
        .NONE  = 0,
        .NOTE  = left + name_width / 2,
        .CENTS = cents_x + CENTS_WIDTH / 2,
    }

    touch := touch_input()
    selected := &note_offset_selected
    popup := &note_offset_popup
    if selected^ >= count do selected^ = -1
    if selected^ < 0 || !touch do popup^ = .NONE

    // A tap on the popup is its own, the controls under it don't see it. A tap anywhere else puts it away and
    // goes on to what's there, on the other value it opens that one's popup.
    was_disabled := gui_disabled
    if popup^ != .NONE {
        rect := popup_rect(popup_widths[popup^], anchors[popup^], rows_top + f32(selected^) * row_height, row_height, top, sheet)
        if point_in_rect(mouse_position(), rect) {
            if mouse_pressed() do gui_press_taken = true
            gui_disabled = true
        } else if gui_background_pressed(sheet) {
            popup^ = .NONE
        }
    }

    selected_color := hex(0x4D4E58FF)
    rows_rect := Rect{sheet_left, rows_top, sheet.width, f32(count) * row_height}

    names := NAMES
    for row in 0 ..< count {
        index := clamp(notes[row], 0, core.NOTE_COUNT - 1)
        shown := index + FROM_C0 + transpose
        // A string by its name in the tuning, like the ruler with a capo on
        name := fmt.ctprintf("%s", tuning.strings[row]) if stringed else fmt.ctprintf("%s%d", names[shown %% 12], shown / 12)
        y := rows_top + f32(row) * row_height
        bar := Rect{bar_x, y + (row_height - BAR_HEIGHT) / 2, cents_x - BAR_GAP - bar_x, BAR_HEIGHT}
        cents_rect := Rect{cents_x, y, CENTS_WIDTH, row_height}
        // Out to the edges of the sheet, a finger that misses the outer steppers doesn't put the controls away
        row_rect := Rect{sheet_left, y, sheet.width, row_height}

        if row != selected^ || touch {
            background := hex(sheet_bg_color)
            if row == selected^ {
                background = selected_color
                draw_rect({sheet_left, y}, {sheet.width, row_height}, background)
            }
            draw_centered_label(name, {left, y, name_width, row_height}, text_color_white)
            draw_offset_bar(bar, cents[row], background)
            draw_centered_label(cents_text(cents[row]), cents_rect, text_color_white)

            // Selected for REMOVE, and with a finger the note or the cents open their popup, a string's
            // note stays
            if gui_button(row_rect) {
                selected^ = row
                popup^ = .NONE
                if touch {
                    position := mouse_position()
                    if !stringed && position.x < bar.x - BAR_GAP / 2 do popup^ = .NOTE
                    if position.x >= cents_x - BAR_GAP / 2 do popup^ = .CENTS
                }
            }
            continue
        }

        draw_rect({sheet_left, y}, {sheet.width, row_height}, selected_color)

        // Each stepper reaches halfway into the gaps beside it, the outer ones to the edges of the sheet
        if stringed {
            draw_centered_label(name, {left, y, name_width, row_height}, text_color_white)
        } else {
            x := left
            note_reach := [2]f32{sheet_left, x + NOTE_WIDTH + GAP / 2}
            if step := gui_spin({x, y, NOTE_WIDTH, row_height}, note_reach, names[shown %% 12], ICON_CARET_DOWN, ICON_CARET_UP);
               step != 0 {
                notes[row] = step_note(index, step, transpose)
                changed = true
            }
            x += NOTE_WIDTH + GAP

            octave_reach := [2]f32{x - GAP / 2, x + OCTAVE_WIDTH + BAR_GAP / 2}
            octave := fmt.ctprintf("%d", shown / 12)
            if step := gui_spin({x, y, OCTAVE_WIDTH, row_height}, octave_reach, octave, ICON_CARET_DOWN, ICON_CARET_UP);
               step != 0 {
                notes[row] = step_octave(index, step)
                changed = true
            }
        }

        draw_offset_bar(bar, cents[row], selected_color)
        cents_reach := [2]f32{cents_x - BAR_GAP / 2, sheet_right}
        if step := gui_spin(cents_rect, cents_reach, cents_text(cents[row]), ICON_MINUS, ICON_PLUS); step != 0 {
            cents[row] = step_cents(cents[row], step)
            changed = true
        }
    }

    // Right in the title's row, chromatic only, a stringed instrument has a row a string: a new one on the
    // right, on the note the tuner is on or the closest one above it that has no row. Left of it the button
    // that removes the selected row.
    header_strip := Rect{sheet_left, top, sheet.width, sheet_layout.row_height}
    if !stringed {
        middle := header.y + header.height / 2
        add_x := right - icon_button_width("Add")

        if gui_small_button(add_x - 12, middle, "REMOVE", selected^ >= 0) {
            for row in selected^ ..< count - 1 {
                notes[row] = notes[row + 1]
                cents[row] = cents[row + 1]
            }
            count -= 1
            config.note_offset_counts[preset] = count
            selected^ = -1
            popup^ = .NONE
            changed = true
        }

        if gui_icon_button({add_x, middle - BUTTONS_HEIGHT / 2}, BUTTONS_HEIGHT, ICON_PLUS, "Add", count < MAX_NOTE_OFFSETS) {
            // Middle C in an empty preset when the tuner has no note, otherwise after the last row
            start := 39
            if count > 0 do start = notes[count - 1]
            if target >= 0 do start = target

            added := start
            for try in 0 ..< core.NOTE_COUNT {
                // Up to C8, then down from where it started
                candidate := start + try if start + try < core.NOTE_COUNT else start - (start + try - core.NOTE_COUNT + 1)
                taken := false
                for row in 0 ..< count {
                    if notes[row] == candidate do taken = true
                }
                if !taken {
                    added = candidate
                    break
                }
            }
            notes[count] = added
            cents[count] = 0
            // Selected, it's set next
            selected^ = count
            popup^ = .NONE
            count += 1
            config.note_offset_counts[preset] = count
            changed = true
        }
    }

    // A tap on the sheet away from the rows and the buttons above them unselects the row
    if gui_background_pressed(sheet) && !point_in_rect(mouse_position(), rows_rect) && !point_in_rect(mouse_position(), header_strip) {
        selected^ = -1
        popup^ = .NONE
    }

    gui_disabled = was_disabled

    // The popup, over everything
    if popup^ != .NONE {
        row := selected^
        index := clamp(notes[row], 0, core.NOTE_COUNT - 1)
        shown := index + FROM_C0 + transpose
        row_y := rows_top + f32(row) * row_height
        rect := popup_rect(popup_widths[popup^], anchors[popup^], row_y, row_height, top, sheet)
        RADIUS :: 14
        draw_rounded_rect(rect, RADIUS, pill_dark)

        // A balloon, it points at what was tapped. Line by line, it's slanted.
        {
            POINT_WIDTH :: 16
            POINT_HEIGHT :: 8
            inset: f32 = RADIUS + POINT_WIDTH / 2 // off the round corners
            tip_x := clamp(anchors[popup^], rect.x + inset, rect.x + rect.width - inset)
            under := rect.y > row_y
            line_height := 1 / pixel_fonts.scale
            for offset: f32 = 0; offset < POINT_HEIGHT; offset += line_height {
                half := POINT_WIDTH / 2 * (1 - offset / POINT_HEIGHT)
                y := rect.y - offset - line_height if under else rect.y + rect.height + offset
                draw_rect({tip_x - half, y}, {2 * half, line_height}, pill_dark)
            }
        }

        // Each stepper reaches halfway into the gap beside it, the outer ones to the edges of the popup
        x := rect.x + POPUP_PAD
        switch popup^ {
        case .NOTE:
            note_reach := [2]f32{rect.x, x + POPUP_NOTE_WIDTH + POPUP_GAP / 2}
            note_rect := Rect{x, rect.y, POPUP_NOTE_WIDTH, rect.height}
            if step := gui_spin(note_rect, note_reach, names[shown %% 12], ICON_CARET_DOWN, ICON_CARET_UP, large = true);
               step != 0 {
                notes[row] = step_note(index, step, transpose)
                changed = true
            }
            x += POPUP_NOTE_WIDTH + POPUP_GAP

            octave_reach := [2]f32{x - POPUP_GAP / 2, rect.x + rect.width}
            octave_rect := Rect{x, rect.y, POPUP_OCTAVE_WIDTH, rect.height}
            octave := fmt.ctprintf("%d", shown / 12)
            if step := gui_spin(octave_rect, octave_reach, octave, ICON_CARET_DOWN, ICON_CARET_UP, large = true); step != 0 {
                notes[row] = step_octave(index, step)
                changed = true
            }
        case .CENTS:
            cents_rect := Rect{x, rect.y, POPUP_CENTS_WIDTH, rect.height}
            reach := [2]f32{rect.x, rect.x + rect.width}
            if step := gui_spin(cents_rect, reach, cents_text(cents[row]), ICON_MINUS, ICON_PLUS, large = true); step != 0 {
                cents[row] = step_cents(cents[row], step)
                changed = true
            }
        case .NONE:
        }
    }

    return
}

// What the popup on the sheet steps in the selected row, only with a finger
NoteOffsetPopup :: enum {
    NONE,
    NOTE, // and its octave
    CENTS,
}

note_offset_selected := -1 // the row selected on the sheet, -1 for none
note_offset_popup: NoteOffsetPopup
