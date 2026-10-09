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
import "core:slice"

import "../core"
import "../gfx"

// Notes tuned a few cents off equal temperament, e.g. a ukulele's E a little flat so its fretted chords
// sound right, or a guitar's B string a touch low. The strobe stands still at the offset note and the readout
// counts from there. One offset per exact note, a guitar's low and high E are tuned apart. Only presets have
// them, each its own, see gui_instrument.
//
// On the main screen the offset of the note being tuned is under its letter. On the instrument's sheet the
// rows of the selected preset are under its instrument, each a note, its octave and the cents, on a
// stringed instrument a string and its cents. The rows are kept as they are, in their order and at 0 cents
// too, see Config.note_offset_notes.

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


// What the popup steps in the selected row, only with a finger
NoteOffsetPopup :: enum {
    NONE,
    NOTE, // and its octave
    CENTS,
}

// The editing on the instrument's sheet, kept from one frame to the next
NoteOffsetsEditing :: struct {
    selected: int, // the row, -1 for none
    popup:    NoteOffsetPopup,
    clearing: bool, // CLEAR was tapped once, it asks
}

note_offsets_editing := NoteOffsetsEditing {
    selected = -1,
}

// Nothing selected, e.g. when the sheet closes or another preset is picked
reset_note_offsets_editing :: proc() {
    note_offsets_editing = {
        selected = -1,
    }
}


// The rows on the instrument's sheet, see gui_note_offsets at the end

OFFSET_NAMES :: [12]cstring{"C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"}

// From C0 as it's shown, the octave changes at C
OFFSET_FROM_C0 :: 57 + core.LOWEST_NOTE
OFFSET_MIDDLE_C :: 39 // from A0

// The columns of a row: the note and its octave, the bar, the cents
OFFSET_GAP :: 8
OFFSET_NOTE_COLUMN :: 74
OFFSET_OCTAVE_COLUMN :: 58
OFFSET_NAME_COLUMN :: OFFSET_NOTE_COLUMN + OFFSET_GAP + OFFSET_OCTAVE_COLUMN // the note and octave together, over their steppers
OFFSET_BAR_GAP :: 12 // either side of the bar
OFFSET_BAR_HEIGHT :: 8
OFFSET_CENTS_COLUMN :: 96
OFFSET_BUTTONS_HEIGHT :: 26 // as tall as the small buttons
OFFSET_ROW_HEIGHT_MIN :: 32
OFFSET_ROW_HEIGHT_MAX :: 60

// The popup, one line like the row
OFFSET_POPUP_HEIGHT :: 64
OFFSET_POPUP_PAD :: 8
OFFSET_POPUP_GAP :: 4 // between the note and the octave
OFFSET_POPUP_NOTE_WIDTH :: 140
OFFSET_POPUP_OCTAVE_WIDTH :: 116
OFFSET_POPUP_CENTS_WIDTH :: 200
OFFSET_POPUP_RADIUS :: 14

// The selected preset's rows in the config. A stringed instrument has a row a string, only the cents change.
OffsetRows :: struct {
    notes:     ^[MAX_NOTE_OFFSETS]int, // counted from A0
    cents:     ^[MAX_NOTE_OFFSETS]f32,
    count:     ^int, // chromatic only
    strings:   []string, // a stringed instrument's names, in the order they're tuned
    transpose: int, // offsets are kept by the sounding note, a transposing instrument shows the written one
}

// Where the title's row, the rows and their columns are
OffsetGrid :: struct {
    sheet:      gfx.Rect,
    left:       f32, // of the contents, the rows' backgrounds reach to the edges of the sheet
    right:      f32,
    top:        f32, // of the title's row
    rows_top:   f32,
    row_height: f32,
    bar_x:      f32,
    cents_x:    f32,
}

offset_row_count :: proc(rows: OffsetRows) -> int {
    return len(rows.strings) if len(rows.strings) > 0 else clamp(rows.count^, 0, MAX_NOTE_OFFSETS)
}

offset_row_y :: proc(grid: OffsetGrid, row: int) -> f32 {
    return grid.rows_top + f32(row) * grid.row_height
}

// Counted from A0, one the config file put out of range at the end of it
offset_row_note :: proc(rows: OffsetRows, row: int) -> int {
    return clamp(rows.notes[row], 0, core.NOTE_COUNT - 1)
}

// The row's note from C0 as it's shown
offset_shown_semitone :: proc(rows: OffsetRows, row: int) -> int {
    return offset_row_note(rows, row) + OFFSET_FROM_C0 + rows.transpose
}

// A string by its name in the tuning, like the ruler with a capo on
offset_row_name :: proc(rows: OffsetRows, row: int) -> cstring {
    if len(rows.strings) > 0 do return fmt.ctprintf("%s", rows.strings[row])

    names, shown := OFFSET_NAMES, offset_shown_semitone(rows, row)
    return fmt.ctprintf("%s%d", names[shown %% 12], shown / 12)
}

// No sign on a note that's tuned as usual
offset_cents_text :: proc(cents: f32) -> cstring {
    return fmt.ctprintf("%+.1f¢", cents) if cents != 0 else "0¢"
}

// Around the octave, past the notes that are out of A0 to C8
offset_step_note :: proc(rows: OffsetRows, row: int, step: int) -> int {
    shown := offset_shown_semitone(rows, row)
    for try in 1 ..< 12 {
        candidate := shown - shown %% 12 + (shown + try * step) %% 12 - OFFSET_FROM_C0 - rows.transpose
        if candidate >= 0 && candidate < core.NOTE_COUNT do return candidate
    }
    return offset_row_note(rows, row)
}

offset_step_octave :: proc(rows: OffsetRows, row: int, step: int) -> int {
    candidate := offset_row_note(rows, row) + 12 * step
    return candidate if candidate >= 0 && candidate < core.NOTE_COUNT else offset_row_note(rows, row)
}

offset_step_cents :: proc(cents: f32, step: int) -> f32 {
    return clamp(cents + f32(step) * NOTE_OFFSET_STEP_CENTS, -NOTE_OFFSET_MAX_CENTS, NOTE_OFFSET_MAX_CENTS)
}

// A value with a button either side that steps it, down on the left. No pill, the icons and the value on
// the sheet. The touch areas are halves of reach from its left to its right, split at the middle of rect,
// wider than the icons for a finger. Large in the popup.
gui_offset_spin :: proc(rect: gfx.Rect, reach: [2]f32, label: cstring, down_icon, up_icon: cstring, large := false) -> (step: int) {
    font := pixel_fonts.offset_value if large else pixel_fonts.label
    spacing: f32 = 0 if large else 1
    width := measure_label(font, label, spacing).x
    draw_label(font, label, {rect.x + (rect.width - width) / 2, rect.y + (rect.height - font.size) / 2}, text_color_white, spacing)

    button_width: f32 = 44 if large else 22
    style: IconStyle = .LARGE_BOLD if large else .REGULAR
    draw_centered_icon(down_icon, {rect.x, rect.y, button_width, rect.height}, icon_color, style)
    draw_centered_icon(up_icon, {rect.x + rect.width - button_width, rect.y, button_width, rect.height}, icon_color, style)

    middle := rect.x + rect.width / 2
    if gui_button_repeat({reach[0], rect.y, middle - reach[0], rect.height}) do step = -1
    if gui_button_repeat({middle, rect.y, reach[1] - middle, rect.height}) do step = 1

    return
}

// How far the note is off pitch along a line, flat to the left of the middle and sharp to the right,
// the whole half is NOTE_OFFSET_MAX_CENTS. Like the input level: the rounded line again in the accent
// colour, cut off flat where the bar ends. The background shows through in the middle, on pitch.
draw_offset_bar :: proc(line: gfx.Rect, offset: f32, background: gfx.Color) {
    SPLIT :: 2
    radius := line.height / 2
    middle := line.x + line.width / 2
    gfx.draw_rounded_rect(line, radius, pill_dark)

    length := abs(offset) / NOTE_OFFSET_MAX_CENTS * line.width / 2
    start := middle if offset > 0 else middle - length
    gfx.begin_scissor({start, line.y, length, line.height})
    gfx.draw_rounded_rect(line, radius, accent_color)
    gfx.end_scissor()

    gfx.draw_rect({middle - SPLIT / 2, line.y}, {SPLIT, line.height}, background)
}

// What the popup points at, the middle of the note and octave or of the cents
offset_popup_anchor :: proc(grid: OffsetGrid, popup: NoteOffsetPopup) -> f32 {
    switch popup {
    case .NOTE: return grid.left + OFFSET_NAME_COLUMN / 2
    case .CENTS: return grid.cents_x + OFFSET_CENTS_COLUMN / 2
    case .NONE:
    }
    return 0
}

// Over the row, or under it near the top of the sheet, centred on what was tapped and inside the sheet
offset_popup_rect :: proc(grid: OffsetGrid, popup: NoteOffsetPopup, row: int) -> gfx.Rect {
    GAP :: 10 // from the row, the balloon's point reaches most of the way
    widths := [NoteOffsetPopup]f32 {
        .NONE  = 0,
        .NOTE  = 2 * OFFSET_POPUP_PAD + OFFSET_POPUP_NOTE_WIDTH + OFFSET_POPUP_GAP + OFFSET_POPUP_OCTAVE_WIDTH,
        .CENTS = 2 * OFFSET_POPUP_PAD + OFFSET_POPUP_CENTS_WIDTH,
    }
    width := widths[popup]
    sheet := grid.sheet
    x := clamp(offset_popup_anchor(grid, popup) - width / 2, sheet.x + OFFSET_POPUP_PAD, sheet.x + sheet.width - OFFSET_POPUP_PAD - width)
    y := offset_row_y(grid, row) - GAP - OFFSET_POPUP_HEIGHT
    if y < grid.top do y = offset_row_y(grid, row) + grid.row_height + GAP

    return {x, y, width, OFFSET_POPUP_HEIGHT}
}

// A row's note, octave, bar and cents. Tapped it's selected for REMOVE, and with a finger the note or the
// cents open their popup, a string's note stays.
gui_offset_row :: proc(rows: OffsetRows, grid: OffsetGrid, row: int, editing: ^NoteOffsetsEditing, touch: bool) -> (changed: bool) {
    stringed := len(rows.strings) > 0
    selected := row == editing.selected
    sheet := grid.sheet
    y := offset_row_y(grid, row)
    name_rect := gfx.Rect{grid.left, y, OFFSET_NAME_COLUMN, grid.row_height}
    bar := gfx.Rect{grid.bar_x, y + (grid.row_height - OFFSET_BAR_HEIGHT) / 2, grid.cents_x - OFFSET_BAR_GAP - grid.bar_x, OFFSET_BAR_HEIGHT}
    cents_rect := gfx.Rect{grid.cents_x, y, OFFSET_CENTS_COLUMN, grid.row_height}
    cents := &rows.cents[row]

    background := note_offset_selected_color if selected else gfx.hex(sheet_bg_color)
    if selected do gfx.draw_rect({sheet.x, y}, {sheet.width, grid.row_height}, background)

    if !selected || touch {
        draw_centered_label(offset_row_name(rows, row), name_rect, text_color_white)
        draw_offset_bar(bar, cents^, background)
        draw_centered_label(offset_cents_text(cents^), cents_rect, text_color_white)

        // Out to the edges of the sheet, a finger that misses the outer steppers doesn't put the controls away
        if gui_button({sheet.x, y, sheet.width, grid.row_height}) {
            editing.selected = row
            editing.popup = .NONE
            if touch {
                x := gfx.mouse_position().x
                if !stringed && x < bar.x - OFFSET_BAR_GAP / 2 do editing.popup = .NOTE
                if x >= grid.cents_x - OFFSET_BAR_GAP / 2 do editing.popup = .CENTS
            }
        }
        return
    }

    // The selected row with a mouse, steppers. Each reaches halfway into the gaps beside it, the outer ones
    // to the edges of the sheet.
    if stringed {
        draw_centered_label(offset_row_name(rows, row), name_rect, text_color_white)
    } else {
        names, shown := OFFSET_NAMES, offset_shown_semitone(rows, row)
        note_rect := gfx.Rect{grid.left, y, OFFSET_NOTE_COLUMN, grid.row_height}
        note_reach := [2]f32{sheet.x, note_rect.x + OFFSET_NOTE_COLUMN + OFFSET_GAP / 2}
        if step := gui_offset_spin(note_rect, note_reach, names[shown %% 12], ICON_CARET_DOWN, ICON_CARET_UP); step != 0 {
            rows.notes[row] = offset_step_note(rows, row, step)
            changed = true
        }

        octave_rect := gfx.Rect{note_rect.x + OFFSET_NOTE_COLUMN + OFFSET_GAP, y, OFFSET_OCTAVE_COLUMN, grid.row_height}
        octave_reach := [2]f32{octave_rect.x - OFFSET_GAP / 2, octave_rect.x + OFFSET_OCTAVE_COLUMN + OFFSET_BAR_GAP / 2}
        octave := fmt.ctprintf("%d", shown / 12)
        if step := gui_offset_spin(octave_rect, octave_reach, octave, ICON_CARET_DOWN, ICON_CARET_UP); step != 0 {
            rows.notes[row] = offset_step_octave(rows, row, step)
            changed = true
        }
    }

    draw_offset_bar(bar, cents^, background)
    cents_reach := [2]f32{grid.cents_x - OFFSET_BAR_GAP / 2, sheet.x + sheet.width}
    if step := gui_offset_spin(cents_rect, cents_reach, offset_cents_text(cents^), ICON_MINUS, ICON_PLUS); step != 0 {
        cents^ = offset_step_cents(cents^, step)
        changed = true
    }
    return
}

// The note for a new row: the one the tuner is on, or after the last row, or middle C in an empty preset
// when the tuner has no note. From there up to C8 the first one without a row, then down from where it
// started.
offset_new_row_note :: proc(rows: OffsetRows, target: int) -> int {
    count := offset_row_count(rows)
    start := OFFSET_MIDDLE_C
    if count > 0 do start = rows.notes[count - 1]
    if target >= 0 do start = target

    for try in 0 ..< core.NOTE_COUNT {
        candidate := start + try if start + try < core.NOTE_COUNT else start - (start + try - core.NOTE_COUNT + 1)
        if !slice.contains(rows.notes[:count], candidate) do return candidate
    }
    return start
}

// Right in the title's row. CLEAR sets every offset of the preset at once, the first tap asks in amber, the
// second clears, a tap anywhere else leaves them. Cleared, the chromatic rows are gone, a string's are at 0.
// Chromatic only, as a stringed instrument has a row a string: Add a row on the right, REMOVE the selected
// one left of it.
gui_offset_buttons :: proc(rows: OffsetRows, grid: OffsetGrid, header: gfx.Rect, editing: ^NoteOffsetsEditing, target: int) -> (changed: bool) {
    stringed := len(rows.strings) > 0
    count := offset_row_count(rows)
    add_x := grid.right - icon_button_width("Add")

    clear_right := grid.right if stringed else add_x - 12 - small_button_width("REMOVE") - 8
    clearable := !stringed && count > 0
    for cents in rows.cents[:count] do if cents != 0 do clearable = true

    if gui_small_button(clear_right, header, "SURE?" if editing.clearing else "CLEAR", clearable, warn = editing.clearing) {
        if editing.clearing {
            rows.count^ = 0
            rows.notes^, rows.cents^ = {}, {}
            editing.selected = -1
            editing.popup = .NONE
            changed = true
        }
        editing.clearing = !editing.clearing
    } else if gfx.mouse_pressed() || !clearable {
        editing.clearing = false
    }
    if stringed do return

    count = offset_row_count(rows)
    if gui_small_button(add_x - 12, header, "REMOVE", editing.selected >= 0) {
        for row in editing.selected ..< count - 1 {
            rows.notes[row] = rows.notes[row + 1]
            rows.cents[row] = rows.cents[row + 1]
        }
        count -= 1
        rows.count^ = count
        editing.selected = -1
        editing.popup = .NONE
        changed = true
    }

    add_rect := [2]f32{add_x, header.y + (header.height - OFFSET_BUTTONS_HEIGHT) / 2}
    if gui_icon_button(add_rect, OFFSET_BUTTONS_HEIGHT, ICON_PLUS, "Add", count < MAX_NOTE_OFFSETS) {
        rows.notes[count] = offset_new_row_note(rows, target)
        rows.cents[count] = 0
        rows.count^ = count + 1

        // Selected, it's set next
        editing.selected = count
        editing.popup = .NONE
        changed = true
    }
    return
}

// The selected row's values with large steppers, in a balloon that points at what was tapped
gui_offset_popup :: proc(rows: OffsetRows, grid: OffsetGrid, editing: NoteOffsetsEditing) -> (changed: bool) {
    row := editing.selected
    rect := offset_popup_rect(grid, editing.popup, row)
    gfx.draw_rounded_rect(rect, OFFSET_POPUP_RADIUS, pill_dark)

    // The balloon's point, line by line, it's slanted
    POINT_WIDTH :: 16
    POINT_HEIGHT :: 8
    inset: f32 = OFFSET_POPUP_RADIUS + POINT_WIDTH / 2 // off the round corners
    tip_x := clamp(offset_popup_anchor(grid, editing.popup), rect.x + inset, rect.x + rect.width - inset)
    under := rect.y > offset_row_y(grid, row)
    line_height := 1 / pixel_fonts.scale
    for offset: f32 = 0; offset < POINT_HEIGHT; offset += line_height {
        half := POINT_WIDTH / 2 * (1 - offset / POINT_HEIGHT)
        y := rect.y - offset - line_height if under else rect.y + rect.height + offset
        gfx.draw_rect({tip_x - half, y}, {2 * half, line_height}, pill_dark)
    }

    // Each stepper reaches halfway into the gap beside it, the outer ones to the edges of the popup
    x := rect.x + OFFSET_POPUP_PAD
    switch editing.popup {
    case .NOTE:
        names, shown := OFFSET_NAMES, offset_shown_semitone(rows, row)
        note_rect := gfx.Rect{x, rect.y, OFFSET_POPUP_NOTE_WIDTH, rect.height}
        note_reach := [2]f32{rect.x, x + OFFSET_POPUP_NOTE_WIDTH + OFFSET_POPUP_GAP / 2}
        if step := gui_offset_spin(note_rect, note_reach, names[shown %% 12], ICON_CARET_DOWN, ICON_CARET_UP, large = true);
           step != 0 {
            rows.notes[row] = offset_step_note(rows, row, step)
            changed = true
        }

        x += OFFSET_POPUP_NOTE_WIDTH + OFFSET_POPUP_GAP
        octave_rect := gfx.Rect{x, rect.y, OFFSET_POPUP_OCTAVE_WIDTH, rect.height}
        octave_reach := [2]f32{x - OFFSET_POPUP_GAP / 2, rect.x + rect.width}
        octave := fmt.ctprintf("%d", shown / 12)
        if step := gui_offset_spin(octave_rect, octave_reach, octave, ICON_CARET_DOWN, ICON_CARET_UP, large = true); step != 0 {
            rows.notes[row] = offset_step_octave(rows, row, step)
            changed = true
        }
    case .CENTS:
        cents := &rows.cents[row]
        cents_rect := gfx.Rect{x, rect.y, OFFSET_POPUP_CENTS_WIDTH, rect.height}
        reach := [2]f32{rect.x, rect.x + rect.width}
        if step := gui_offset_spin(cents_rect, reach, offset_cents_text(cents^), ICON_MINUS, ICON_PLUS, large = true); step != 0 {
            cents^ = offset_step_cents(cents^, step)
            changed = true
        }
    case .NONE:
    }
    return
}


// The selected preset's offsets on the instrument's sheet, under its first_row rows: a row with the title and
// the buttons, then a row an offset. target is the note the tuner is on counted from A0, a new row starts
// there, or -1. Returns true when the rows changed.
//
// With a mouse the selected row is lighter and its values are steppers, one row at a time, the rows stay
// where they are. A finger would cover what it steps, tapped the note or the cents open a popup over the row
// with the steppers large.
gui_note_offsets :: proc(sheet_layout: SheetLayout, first_row: int, config: ^Config, target: int) -> (changed: bool) {
    preset := selected_preset(config)
    setup := preset_setup(config, preset)
    tuning, _ := setup_tuning(setup)
    rows := OffsetRows {
        notes     = &config.note_offset_notes[preset],
        cents     = &config.note_offset_cents[preset],
        count     = &config.note_offset_counts[preset],
        strings   = tuning.strings,
        transpose = transpose_key(setup),
    }
    count := offset_row_count(rows)

    // Taller rows where all of them fit, on a phone, shorter ones for the mouse on the desktop. As tall as the
    // most rows there can be, a row added doesn't move the others.
    header := settings_row(sheet_layout, first_row, "Note offsets", 0)
    top := header.y - SHEET_CONTROL_MARGIN
    rows_top := top + sheet_layout.row_height
    most := count if len(rows.strings) > 0 else MAX_NOTE_OFFSETS
    left := sheet_layout.rows.x
    right := left + sheet_layout.width
    grid := OffsetGrid {
        sheet      = sheet_layout.sheet,
        left       = left,
        right      = right,
        top        = top,
        rows_top   = rows_top,
        row_height = clamp(math.floor((sheet_layout.bottom - rows_top) / f32(max(most, 1))), OFFSET_ROW_HEIGHT_MIN, OFFSET_ROW_HEIGHT_MAX),
        bar_x      = left + OFFSET_NAME_COLUMN + OFFSET_BAR_GAP,
        cents_x    = right - OFFSET_CENTS_COLUMN,
    }

    editing := &note_offsets_editing
    touch := gfx.touch_input()
    if editing.selected >= count do editing.selected = -1
    if editing.selected < 0 || !touch do editing.popup = .NONE

    // A tap on the popup is its own, the controls under it don't see it. A tap anywhere else puts it away and
    // goes on to what's there, on the other value it opens that one's popup.
    was_disabled := gui_disabled
    if editing.popup != .NONE {
        if gfx.point_in_rect(gfx.mouse_position(), offset_popup_rect(grid, editing.popup, editing.selected)) {
            if gfx.mouse_pressed() do gui_press_taken = true

            gui_disabled = true
        } else if gui_background_pressed(grid.sheet) {
            editing.popup = .NONE
        }
    }

    for row in 0 ..< count {
        if gui_offset_row(rows, grid, row, editing, touch) do changed = true
    }
    rows_rect := gfx.Rect{grid.sheet.x, rows_top, grid.sheet.width, f32(count) * grid.row_height}
    if gui_offset_buttons(rows, grid, header, editing, target) do changed = true

    // A tap on the sheet away from the rows and the buttons above them unselects the row
    title_row := gfx.Rect{grid.sheet.x, top, grid.sheet.width, sheet_layout.row_height}
    mouse := gfx.mouse_position()
    if gui_background_pressed(grid.sheet) && !gfx.point_in_rect(mouse, rows_rect) && !gfx.point_in_rect(mouse, title_row) {
        editing.selected = -1
        editing.popup = .NONE
    }
    gui_disabled = was_disabled

    // The popup, over everything
    if editing.popup != .NONE && gui_offset_popup(rows, grid, editing^) do changed = true

    return
}
