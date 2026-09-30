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
// sound right, or a sweetened guitar tuning. The strobe stands still at the offset note and the readout
// counts from there. One offset per exact note, a guitar's low and high E are tuned apart. A few slots
// hold a tuning each.
//
// On the main screen: an LED left of the settings that's lit while they're on, with the slot, tapping it
// goes through the slots in use and off, the ± that opens the sheet, and the offset of the note being tuned
// under its letter. The sheet covers the window: the slots, and the rows of the selected slot, each a note,
// its octave and the cents. Tapping a row shows its controls, and the button under the rows removes it. With
// a finger the controls are in a popup over the row instead, see gui_note_offsets.
// The rows are kept as they are, in their order and at 0 cents too, see Config.note_offset_notes.

NOTE_OFFSET_SLOTS :: 3
NOTE_OFFSET_STEP_CENTS :: 0.5
// A string this far from its note is still detected as that note once it's nearly in tune
NOTE_OFFSET_MAX_CENTS :: 25
// Rows in a slot, a 12 string guitar has 10 notes. The sheet shows them all without scrolling.
MAX_NOTE_OFFSETS :: 10

NOTE_OFFSET_ROWS :: 1 // the switch and the slots, the offsets under them are laid out by the sheet

// The slot picked in the sheet, the one that's edited and tuned to while the offsets are on
note_offset_slot :: proc(config: ^Config) -> int {
    return clamp(config.note_offset_slot, 0, NOTE_OFFSET_SLOTS - 1)
}

// What each note from A0 is tuned off by, from the rows of the selected slot, all 0 while the offsets are off
active_note_offsets :: proc(config: ^Config) -> (offsets: [core.NOTE_COUNT]f32) {
    if !config.note_offsets_on do return
    slot := note_offset_slot(config)
    // A note in more than one row is tuned by the first
    for row := clamp(config.note_offset_counts[slot], 0, MAX_NOTE_OFFSETS) - 1; row >= 0; row -= 1 {
        index := config.note_offset_notes[slot][row]
        if index >= 0 && index < core.NOTE_COUNT do offsets[index] = config.note_offset_cents[slot][row]
    }
    return
}


// On the main screen left of the ±: an LED, lit while the offsets are on, and the label with the slot
// that's tuned to. Tapping it goes on to the next slot that has rows, and off after the last, so with one
// slot in use it switches them on and off. With none it's the selected slot. pos is the right edge and the
// middle. Returns true when the offsets changed.
gui_note_offsets_indicator :: proc(pos: [2]f32, config: ^Config) -> bool {
    LED_SIZE :: 8
    LABEL_GAP :: 10

    on := config.note_offsets_on
    slot := note_offset_slot(config)
    label: cstring = fmt.ctprintf("OFFSETS %d", slot + 1) if on else "OFFSETS"
    width := LED_SIZE + LABEL_GAP + measure_label(pixel_fonts.label, label, 1).x
    if !gui_led_toggle({pos.x - width, pos.y}, label, on, pill_yellow) do return false

    // From the first slot while off, from the one after while on
    first := slot + 1 if on else 0
    for next in first ..< NOTE_OFFSET_SLOTS {
        if config.note_offset_counts[next] > 0 {
            config.note_offsets_on = true
            config.note_offset_slot = next
            return true
        }
    }
    // Past the last slot in use, or none has rows and it's a switch
    in_use := false
    for count in config.note_offset_counts do in_use ||= count > 0
    config.note_offsets_on = !on && !in_use
    return true
}

// The ± between the indicator and the settings, 24pt in the middle of a 2x larger touch area like the
// settings. Tapping it opens the sheet.
gui_note_offsets_button :: proc(position: [2]f32) -> bool {
    draw_icon(ICON_PLUS_MINUS, position, icon_color, large = true)
    return gui_button({position.x - 12, position.y - 12, 48, 48})
}


// The sheet. target is the note the tuner is on counted from A0, a new row starts there, or -1. Returns
// close when ✕ is tapped, changed when the strobe needs updating or the rows changed.
gui_note_offsets :: proc(l: SettingsLayout, config: ^Config, target: int) -> (close: bool, changed: bool) {
    // The slots, like the segmented control but for what's shown under it rather than a setting: a track
    // split into tabs by slanted cuts, the selected tab is the lighter gray from cut to cut
    gui_tabs :: proc(rect: Rect, labels: []cstring, selected: int) -> (int, bool) {
        SLANT :: 4 // the cuts lean this far either side of where the tabs meet, to the right at the top
        CUT :: 3 // as wide as the sheet shows through

        tab_width := rect.width / f32(len(labels))
        draw_pill(rect, pill_dark)

        {
            // The track again in the lighter gray, as far as the cuts where they're closest, that keeps
            // its round end. Then line by line out to where the cuts lean.
            left := rect.x + f32(selected) * tab_width
            right := left + tab_width
            first, last := selected == 0, selected == len(labels) - 1
            inner_left := left if first else left + SLANT
            inner_right := right if last else right - SLANT
            begin_scissor({inner_left, rect.y, inner_right - inner_left, rect.height})
            draw_pill(rect, pill_gray)
            end_scissor()

            line_height := 1 / pixel_fonts.scale
            for y := rect.y; y < rect.y + rect.height; y += line_height {
                lean := SLANT * (1 - 2 * (y - rect.y) / rect.height)
                if !first do draw_rect({left + lean, y}, {SLANT - lean, line_height}, pill_gray)
                if !last do draw_rect({right - SLANT, y}, {SLANT + lean, line_height}, pill_gray)
            }
        }

        for label, i in labels {
            tab := Rect{rect.x + f32(i) * tab_width, rect.y, tab_width, rect.height}

            if i > 0 {
                // A little past the track at both ends, the square ends of the line are off it
                OVER :: 0.125
                lean: f32 = SLANT * (1 + 2 * OVER)
                top := [2]f32{tab.x + lean, tab.y - OVER * tab.height}
                bottom := [2]f32{tab.x - lean, tab.y + (1 + OVER) * tab.height}
                draw_line(top, bottom, CUT, hex(sheet_bg_color))
            }

            draw_centered_label(label, tab, text_color_white if i == selected else text_color_light)
        }

        // Slimmer than the other pills, the touch area is still as tall as a row
        for _, i in labels {
            touch := Rect{rect.x + f32(i) * tab_width, rect.y + (rect.height - SETTINGS_ROW_HEIGHT) / 2, tab_width, SETTINGS_ROW_HEIGHT}
            if i != selected && gui_button(touch) do return i, true
        }

        return selected, false
    }

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

    draw_rect({l.sheet.x, l.sheet.y}, {l.sheet.width, l.sheet.height}, hex(sheet_bg_color))

    draw_label(pixel_fonts.title, "Note offsets", l.title, text_color_white, 1)

    draw_icon(ICON_X, {l.close.x + (l.close.width - 16) / 2, l.close.y + (l.close.height - 16) / 2}, icon_color)
    if gui_button(l.close) do close = true

    right := l.rows.x + l.width
    top := l.rows.y
    sheet_left, sheet_right := l.sheet.x, l.sheet.x + l.sheet.width

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
    BUTTONS_GAP :: 20 // from the rows to the buttons under them
    BUTTONS_HEIGHT :: 28
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

    // Taller rows where all of them fit, on a phone
    ROW_HEIGHT_MAX :: 60
    rows_top := top + l.row_height + 4
    room := l.bottom - rows_top - BUTTONS_GAP - BUTTONS_HEIGHT
    row_height := clamp(math.floor(room / MAX_NOTE_OFFSETS), l.row_height, ROW_HEIGHT_MAX)
    name_width: f32 = NOTE_WIDTH + GAP + OCTAVE_WIDTH // the note and octave together, over their steppers
    bar_x := l.rows.x + name_width + BAR_GAP
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
        .None  = 0,
        .Note  = 2 * POPUP_PAD + POPUP_NOTE_WIDTH + POPUP_GAP + POPUP_OCTAVE_WIDTH,
        .Cents = 2 * POPUP_PAD + POPUP_CENTS_WIDTH,
    }
    anchors := [NoteOffsetPopup]f32 {
        .None  = 0,
        .Note  = l.rows.x + name_width / 2,
        .Cents = cents_x + CENTS_WIDTH / 2,
    }

    touch := touch_input()
    selected := &note_offset_selected
    popup := &note_offset_popup
    if selected^ >= config.note_offset_counts[note_offset_slot(config)] do selected^ = -1
    if selected^ < 0 || !touch do popup^ = .None

    // A tap on the popup is its own, the controls under it don't see it. A tap anywhere else puts it away and
    // goes on to what's there, on the other value it opens that one's popup.
    was_disabled := gui_disabled
    if popup^ != .None {
        rect := popup_rect(popup_widths[popup^], anchors[popup^], rows_top + f32(selected^) * row_height, row_height, top, l.sheet)
        if point_in_rect(mouse_position(), rect) {
            if mouse_pressed() do gui_press_taken = true
            gui_disabled = true
        } else if gui_background_pressed(l.sheet) {
            popup^ = .None
        }
    }

    // The slots, the selected one is tuned to while the offsets are on and its rows are below. They're
    // switched on and off on the main screen, see gui_note_offsets_indicator.
    {
        TAB_WIDTH :: 96
        TAB_HEIGHT :: 26 // as tall as the small buttons
        rect := Rect{l.rows.x, top + (l.row_height - TAB_HEIGHT) / 2, NOTE_OFFSET_SLOTS * TAB_WIDTH, TAB_HEIGHT}
        if i, ok := gui_tabs(rect, []cstring{"Slot 1", "Slot 2", "Slot 3"}, note_offset_slot(config)); ok {
            config.note_offset_slot = i
            selected^ = -1
            popup^ = .None
            changed = true
        }
    }

    slot := note_offset_slot(config)
    count := &config.note_offset_counts[slot]
    count^ = clamp(count^, 0, MAX_NOTE_OFFSETS)
    notes := &config.note_offset_notes[slot]
    cents := &config.note_offset_cents[slot]

    selected_color := hex(0x4D4E58FF)
    rows_rect := Rect{sheet_left, rows_top, l.sheet.width, f32(count^) * row_height}

    names := NAMES
    for row in 0 ..< count^ {
        index := clamp(notes[row], 0, core.NOTE_COUNT - 1)
        shown := index + FROM_C0 + config.transpose
        y := rows_top + f32(row) * row_height
        bar := Rect{bar_x, y + (row_height - BAR_HEIGHT) / 2, cents_x - BAR_GAP - bar_x, BAR_HEIGHT}
        cents_rect := Rect{cents_x, y, CENTS_WIDTH, row_height}
        // Out to the edges of the sheet, a finger that misses the outer steppers doesn't put the controls away
        row_rect := Rect{sheet_left, y, l.sheet.width, row_height}

        if row != selected^ || touch {
            background := hex(sheet_bg_color)
            if row == selected^ {
                background = selected_color
                draw_rect({sheet_left, y}, {l.sheet.width, row_height}, background)
            }
            draw_centered_label(fmt.ctprintf("%s%d", names[shown %% 12], shown / 12), {l.rows.x, y, name_width, row_height}, text_color_white)
            draw_offset_bar(bar, cents[row], background)
            draw_centered_label(cents_text(cents[row]), cents_rect, text_color_white)

            // Selected for REMOVE, and with a finger the note or the cents open their popup
            if gui_button(row_rect) {
                selected^ = row
                popup^ = .None
                if touch {
                    position := mouse_position()
                    if position.x < bar.x - BAR_GAP / 2 do popup^ = .Note
                    if position.x >= cents_x - BAR_GAP / 2 do popup^ = .Cents
                }
            }
            continue
        }

        draw_rect({sheet_left, y}, {l.sheet.width, row_height}, selected_color)

        // Each stepper reaches halfway into the gaps beside it, the outer ones to the edges of the sheet
        x := l.rows.x
        note_reach := [2]f32{sheet_left, x + NOTE_WIDTH + GAP / 2}
        if step := gui_spin({x, y, NOTE_WIDTH, row_height}, note_reach, names[shown %% 12], ICON_CARET_DOWN, ICON_CARET_UP);
           step != 0 {
            notes[row] = step_note(index, step, config.transpose)
            changed = true
        }
        x += NOTE_WIDTH + GAP

        octave_reach := [2]f32{x - GAP / 2, x + OCTAVE_WIDTH + BAR_GAP / 2}
        octave := fmt.ctprintf("%d", shown / 12)
        if step := gui_spin({x, y, OCTAVE_WIDTH, row_height}, octave_reach, octave, ICON_CARET_DOWN, ICON_CARET_UP); step != 0 {
            notes[row] = step_octave(index, step)
            changed = true
        }

        draw_offset_bar(bar, cents[row], selected_color)
        cents_reach := [2]f32{cents_x - BAR_GAP / 2, sheet_right}
        if step := gui_spin(cents_rect, cents_reach, cents_text(cents[row]), ICON_MINUS, ICON_PLUS); step != 0 {
            cents[row] = step_cents(cents[row], step)
            changed = true
        }
    }

    // Under the rows, far enough from them that a tap on the last row's + doesn't land here: a new one on
    // the left, on the note the tuner is on or the closest one above it that has no row. Opposite it the
    // button that removes the selected row.
    buttons_strip: Rect
    {
        y := rows_top + f32(count^) * row_height + BUTTONS_GAP
        middle := y + BUTTONS_HEIGHT / 2
        buttons_strip = {l.rows.x, middle - SETTINGS_ROW_HEIGHT / 2, l.width, SETTINGS_ROW_HEIGHT}

        if gui_small_button(right, middle, "REMOVE", selected^ >= 0) {
            for row in selected^ ..< count^ - 1 {
                notes[row] = notes[row + 1]
                cents[row] = cents[row + 1]
            }
            count^ -= 1
            selected^ = -1
            popup^ = .None
            changed = true
        }

        if gui_icon_button({l.rows.x, y}, BUTTONS_HEIGHT, ICON_PLUS, "Add", count^ < MAX_NOTE_OFFSETS) {
            // Middle C in an empty slot when the tuner has no note, otherwise after the last row
            start := 39
            if count^ > 0 do start = notes[count^ - 1]
            if target >= 0 do start = target

            added := start
            for try in 0 ..< core.NOTE_COUNT {
                // Up to C8, then down from where it started
                candidate := start + try if start + try < core.NOTE_COUNT else start - (start + try - core.NOTE_COUNT + 1)
                taken := false
                for row in 0 ..< count^ {
                    if notes[row] == candidate do taken = true
                }
                if !taken {
                    added = candidate
                    break
                }
            }
            notes[count^] = added
            cents[count^] = 0
            // Selected, it's set next
            selected^ = count^
            popup^ = .None
            count^ += 1
            changed = true
        }
    }

    // A tap on the sheet away from the rows and the buttons under them unselects the row
    if gui_background_pressed(l.sheet) && !point_in_rect(mouse_position(), rows_rect) && !point_in_rect(mouse_position(), buttons_strip) {
        selected^ = -1
        popup^ = .None
    }

    gui_disabled = was_disabled

    // The popup, over everything
    if popup^ != .None {
        row := selected^
        index := clamp(notes[row], 0, core.NOTE_COUNT - 1)
        shown := index + FROM_C0 + config.transpose
        row_y := rows_top + f32(row) * row_height
        rect := popup_rect(popup_widths[popup^], anchors[popup^], row_y, row_height, top, l.sheet)
        RADIUS :: 14
        draw_rounded_rect(rect, RADIUS, pill_dark)

        // A balloon, it points at what was tapped. Line by line like the cuts between the slots.
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
        case .Note:
            note_reach := [2]f32{rect.x, x + POPUP_NOTE_WIDTH + POPUP_GAP / 2}
            note_rect := Rect{x, rect.y, POPUP_NOTE_WIDTH, rect.height}
            if step := gui_spin(note_rect, note_reach, names[shown %% 12], ICON_CARET_DOWN, ICON_CARET_UP, large = true);
               step != 0 {
                notes[row] = step_note(index, step, config.transpose)
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
        case .Cents:
            cents_rect := Rect{x, rect.y, POPUP_CENTS_WIDTH, rect.height}
            reach := [2]f32{rect.x, rect.x + rect.width}
            if step := gui_spin(cents_rect, reach, cents_text(cents[row]), ICON_MINUS, ICON_PLUS, large = true); step != 0 {
                cents[row] = step_cents(cents[row], step)
                changed = true
            }
        case .None:
        }
    }

    return
}

// What the popup on the sheet steps in the selected row, only with a finger
NoteOffsetPopup :: enum {
    None,
    Note, // and its octave
    Cents,
}

note_offset_selected := -1 // the row selected on the sheet, -1 for none
note_offset_popup: NoteOffsetPopup
