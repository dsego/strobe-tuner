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

import "../core"

// Notes tuned a few cents off equal temperament, e.g. a ukulele's E a little flat so its fretted chords
// sound right, or a sweetened guitar tuning. The strobe stands still at the offset note and the readout
// counts from there. One offset per exact note, a guitar's low and high E are tuned apart. A few slots
// hold a tuning each.
//
// On the main screen: an LED left of the settings that's lit while they're on, with the slot, tapping it
// goes through the slots in use and off, the ± that opens the sheet, and the offset of the note being tuned
// under its letter. The sheet covers the window: the slots, and the rows of the selected slot, added and
// removed, each a note, its octave and the cents. The rows are kept as they are, in their order and at 0 cents too, see
// Config.note_offset_notes.

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
    // A note in more than one row is tuned by the first, the sheet dims the others
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

        for _, i in labels {
            tab := Rect{rect.x + f32(i) * tab_width, rect.y, tab_width, rect.height}
            if i != selected && gui_button(touch_area(tab)) do return i, true
        }

        return selected, false
    }

    // A value with a button either side that steps it, down on the left. No pill, the icons and the value
    // on the sheet. rect is the row's height, all of it is the touch area.
    gui_spin :: proc(rect: Rect, label: cstring, color: Color, down_icon, up_icon: cstring) -> (step: int) {
        BUTTON_WIDTH :: 22
        down := Rect{rect.x, rect.y, BUTTON_WIDTH, rect.height}
        up := Rect{rect.x + rect.width - BUTTON_WIDTH, rect.y, BUTTON_WIDTH, rect.height}
        icon_y := rect.y + (rect.height - ICON_SIZE) / 2
        draw_icon(down_icon, {down.x + (BUTTON_WIDTH - ICON_SIZE) / 2, icon_y}, icon_color)
        draw_centered_label(label, rect, color)
        draw_icon(up_icon, {up.x + (BUTTON_WIDTH - ICON_SIZE) / 2, icon_y}, icon_color)

        if gui_button_repeat(down) do step = -1
        if gui_button_repeat(up) do step = 1
        return
    }

    // How far the note is off pitch along a line, flat to the left of the middle and sharp to the right,
    // the whole half is NOTE_OFFSET_MAX_CENTS. Like the input level: the rounded line again in the light
    // colour, cut off flat where the bar ends. The sheet shows through in the middle, on pitch.
    draw_offset_bar :: proc(line: Rect, offset: f32) {
        SPLIT :: 2
        radius := line.height / 2
        middle := line.x + line.width / 2
        draw_rounded_rect(line, radius, pill_dark)

        length := abs(offset) / NOTE_OFFSET_MAX_CENTS * line.width / 2
        start := middle if offset > 0 else middle - length
        begin_scissor({start, line.y, length, line.height})
        draw_rounded_rect(line, radius, hex(0x82E2FFFF))
        end_scissor()

        draw_rect({middle - SPLIT / 2, line.y}, {SPLIT, line.height}, hex(sheet_bg_color))
    }

    draw_rect({l.sheet.x, l.sheet.y}, {l.sheet.width, l.sheet.height}, hex(sheet_bg_color))

    draw_label(pixel_fonts.title, "Note offsets", l.title, text_color_white, 1)

    draw_icon(ICON_X, {l.close.x + (l.close.width - 16) / 2, l.close.y + (l.close.height - 16) / 2}, icon_color)
    if gui_button(l.close) do close = true

    right := l.rows.x + l.width
    top := l.rows.y

    // The slots, the selected one is tuned to while the offsets are on and its rows are below. They're
    // switched on and off on the main screen, see gui_note_offsets_indicator.
    {
        TAB_WIDTH :: 68
        rect := Rect {
            l.rows.x,
            top + SETTINGS_CONTROL_MARGIN,
            NOTE_OFFSET_SLOTS * TAB_WIDTH,
            l.row_height - 2 * SETTINGS_CONTROL_MARGIN,
        }
        if i, ok := gui_tabs(rect, []cstring{"Slot 1", "Slot 2", "Slot 3"}, note_offset_slot(config)); ok {
            config.note_offset_slot = i
            changed = true
        }
    }
    top += l.row_height + 4

    slot := note_offset_slot(config)
    count := &config.note_offset_counts[slot]
    count^ = clamp(count^, 0, MAX_NOTE_OFFSETS)
    notes := &config.note_offset_notes[slot]
    cents := &config.note_offset_cents[slot]

    // A row an offset: the note and its octave, the bar, the cents, and the trash that removes it
    NAMES :: [12]cstring{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
    GAP :: 8
    BAR_GAP :: 12 // either side of the bar
    NOTE_WIDTH :: 74
    OCTAVE_WIDTH :: 58
    CENTS_WIDTH :: 96
    TRASH_WIDTH :: 24
    BAR_HEIGHT :: 4
    // From C0 as it's shown, the octave changes at C. Offsets are kept by the sounding note, a transposing
    // instrument reads the written one.
    FROM_C0 :: 57 + core.LOWEST_NOTE

    names := NAMES
    removed := -1
    for row in 0 ..< count^ {
        index := clamp(notes[row], 0, core.NOTE_COUNT - 1)
        y := top + f32(row) * l.row_height
        height := l.row_height

        // Another row above has the same note, that one is tuned to and this one is dimmed
        shadowed := false
        for earlier in 0 ..< row {
            if notes[earlier] == index do shadowed = true
        }
        color := text_color_muted if shadowed else text_color_white

        shown := index + FROM_C0 + config.transpose
        x := l.rows.x
        if step := gui_spin({x, y, NOTE_WIDTH, height}, names[shown %% 12], color, ICON_CARET_DOWN, ICON_CARET_UP);
           step != 0 {
            // Around the octave, past the notes that are out of A0 to C8
            for try in 1 ..< 12 {
                candidate := shown - shown %% 12 + (shown + try * step) %% 12 - FROM_C0 - config.transpose
                if candidate >= 0 && candidate < core.NOTE_COUNT {
                    notes[row] = candidate
                    changed = true
                    break
                }
            }
        }
        x += NOTE_WIDTH + GAP

        octave := fmt.ctprintf("%d", shown / 12)
        if step := gui_spin({x, y, OCTAVE_WIDTH, height}, octave, color, ICON_CARET_DOWN, ICON_CARET_UP); step != 0 {
            candidate := index + 12 * step
            if candidate >= 0 && candidate < core.NOTE_COUNT {
                notes[row] = candidate
                changed = true
            }
        }
        x += OCTAVE_WIDTH + BAR_GAP

        trash := Rect{right - TRASH_WIDTH, y, TRASH_WIDTH, height}
        cents_rect := Rect{trash.x - GAP - CENTS_WIDTH, y, CENTS_WIDTH, height}
        draw_offset_bar({x, y + (height - BAR_HEIGHT) / 2, cents_rect.x - BAR_GAP - x, BAR_HEIGHT}, cents[row])

        // No sign on a note that's tuned as usual
        label := fmt.ctprintf("%+.1f¢", cents[row]) if cents[row] != 0 else "0¢"
        if step := gui_spin(cents_rect, label, color, ICON_MINUS, ICON_PLUS); step != 0 {
            cents[row] = clamp(cents[row] + f32(step) * NOTE_OFFSET_STEP_CENTS, -NOTE_OFFSET_MAX_CENTS, NOTE_OFFSET_MAX_CENTS)
            changed = true
        }

        draw_icon(ICON_TRASH, {trash.x + TRASH_WIDTH - ICON_SIZE, y + (height - ICON_SIZE) / 2}, icon_color)
        if gui_button(trash) do removed = row
    }

    if removed >= 0 {
        for row in removed ..< count^ - 1 {
            notes[row] = notes[row + 1]
            cents[row] = cents[row + 1]
        }
        count^ -= 1
        changed = true
    }

    // Under the rows: a new one on the left, on the note the tuner is on or the closest one above it that
    // has no row. Opposite it the button that empties the slot.
    {
        HEIGHT :: 28
        y := top + f32(count^) * l.row_height + GAP
        if gui_icon_button({l.rows.x, y}, HEIGHT, ICON_PLUS, "Add", count^ < MAX_NOTE_OFFSETS) {
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
            count^ += 1
            changed = true
        }

        if gui_small_button(right, y + HEIGHT / 2, "CLEAR SLOT", count^ > 0) {
            count^ = 0
            changed = true
        }
    }

    return
}
