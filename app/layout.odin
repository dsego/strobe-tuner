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

// Where everything goes, worked out every frame from the window size and the safe area, in points.
// The same on the desktop and a phone, both are portrait windows: the strobe on top, the panel under it.

Layout :: struct {
    strobe:         Rect,
    strobe_top:     f32, // top of the visible strobe, below the notch
    strobe_scale:   f32, // size of the strobe tracks relative to the desktop
    ruler:          Rect,
    ruler_scale:    f32, // size of the ruler's notes relative to the desktop
    note:           [2]f32, // top left of the note without the ruler
    measurements:   [2]f32, // see ReadoutAlign
    readout_align:  ReadoutAlign,
    stats:          [2]f32,
    lock:           [2]f32, // the middle of the button
    transpose:      [2]f32, // left edge, the middle of the stepper, the label is above it
    response:       [2]f32, // hidden with the trace
    level_meter:    [2]f32, // left of the icon, top of the bar
    settings:       [2]f32,
    note_offset:    [2]f32, // the middle of the note's offset, between the letter and the lock
    note_offsets:   [2]f32, // the ± left of the settings, like them the top left of the icon
    offsets_led:    [2]f32, // the LED and label left of the ±: their right edge and middle
}

PANEL_PADDING :: 16
DESKTOP_HEIGHT :: 620 // the window, as wide as the strobe, most of the strobe shows above the settings
LEVEL_METER_WIDTH :: 80 // the microphone icon and the bar after it

RULER_HEIGHT :: 110
// Larger notes and readout values than the ruler was drawn at, they're read from a music stand
RULER_SCALE :: 1.3
// Above the ruler and centred, without it right aligned with the values on the baseline of the note letter
READOUT_WIDTH :: HZ_COLUMN_OFFSET + 75 // enough for "4186.0"
READOUT_HEIGHT :: 48
// Inter's letters and digits fill less than their font size: the cap height is 0.6 of it, the baseline
// 0.8 down from the top. The ruler is spaced by what's drawn.
CAP_HALF :: 0.3 // the letter's top and baseline from its middle, in font sizes
BASELINE :: 0.8 // from the top of the text, in font sizes
RULER_GAP :: 32 // between the letter and the lock, the note's offset is halfway
READOUT_NOTE_TOP :: NOTE_BASELINE - 40 // the 24pt values and the labels above them

// Where the right arrow of the note ends, the readout keeps clear of it
note_right :: proc(l: Layout) -> f32 {
    return l.note.x + NOTE_WIDTH - NOTE_RIGHT_ARROW_INSET + NOTE_ARROW_SLOT
}

compute_layout :: proc(window: [2]f32, safe: Rect, ruler: bool) -> (l: Layout) {
    left := safe.x + PANEL_PADDING
    right := safe.x + safe.width - PANEL_PADDING
    bottom := safe.y + safe.height - PANEL_PADDING

    // The strobe takes about half of the safe area, its background runs up behind the notch
    l.strobe_scale = clamp(0.5 * safe.height / STROBE_HEIGHT, 1, 1.4)
    l.strobe_top = safe.y
    l.strobe = {0, 0, window.x, safe.y + l.strobe_scale * STROBE_HEIGHT}
    panel := l.strobe.y + l.strobe.height

    l.stats = {left + 131, panel + 80}
    panel_layout(&l, left, right, bottom, ruler, RULER_SCALE)
    return
}

// The response and the level meter in a row just under the strobe, the note with the readout above it
// and the lock under it, and the transpose and the settings in the bottom corners
panel_layout :: proc(l: ^Layout, left, right, bottom: f32, ruler: bool, ruler_scale: f32) {
    panel := l.strobe.y + l.strobe.height

    // The response changes how fast the strobe spins, it sits just under it on the left, the level meter
    // opposite it on the right. The 4pt bar lines up with the LED.
    l.response = {left, panel + 20}
    l.level_meter = {right - LEVEL_METER_WIDTH, l.response.y - 2}

    // A row along the bottom like the one under the strobe
    corners := bottom - SETTINGS_ICON_SIZE / 2
    l.transpose = {left, corners}
    l.settings = {right - SETTINGS_ICON_SIZE, corners - SETTINGS_ICON_SIZE / 2}
    // The ± with its touch area next to the settings', the indicator an icon's width from it
    l.note_offsets = l.settings - {2 * SETTINGS_ICON_SIZE, 0}
    l.offsets_led = {l.note_offsets.x - SETTINGS_ICON_SIZE, corners}

    if ruler {
        // The readout in the top row, the response and the level meter centred on its values, the labels
        // sit above. The note with the lock under it centred between the readout values and the bottom row.
        // Offsets from the middle of the ruler.
        l.ruler_scale = ruler_scale
        readout_top := l.response.y - LABEL_SIZE / 2
        readout_bottom := readout_top + READOUT_VALUE_Y + BASELINE * ruler_scale * READOUT_SIZE
        l.response.y = readout_bottom - CAP_HALF * ruler_scale * READOUT_SIZE
        l.level_meter.y = l.response.y - 2
        rows_bottom := corners - TRANSPOSE_LABEL_TOP

        note_top := -CAP_HALF * ruler_scale * RULER_NOTE_SIZE
        lock_y := -note_top + RULER_GAP + LOCK_BUTTON_HEIGHT / 2
        middle := (readout_bottom + rows_bottom) / 2 - (note_top + lock_y + LOCK_BUTTON_HEIGHT / 2) / 2

        center := (left + right) / 2
        height := ruler_scale * RULER_HEIGHT
        l.ruler = {left, middle - height / 2, right - left, height}
        l.measurements = {center, readout_top}
        l.readout_align = .CENTER
        l.lock = {center, middle + lock_y}
        l.note_offset = l.lock - {0, (LOCK_BUTTON_HEIGHT + RULER_GAP) / 2}
        return
    }

    // The readout next to the note when there's room, otherwise under it, and the lock under both
    l.ruler_scale = 1
    // Below the response, the top of the note is the room above the letter
    l.note = {left + NOTE_ARROW_SLOT, panel + 24}
    lock_y := l.note.y + NOTE_HEIGHT + 24
    if right - READOUT_WIDTH >= note_right(l^) + 12 {
        l.measurements = {right, l.note.y + READOUT_NOTE_TOP}
    } else {
        l.measurements = {right, l.note.y + NOTE_HEIGHT}
        lock_y = l.measurements.y + READOUT_HEIGHT + 24
    }
    // Centred on the note without its arrows
    l.lock = {l.note.x + (NOTE_WIDTH - NOTE_RIGHT_ARROW_INSET) / 2, lock_y}
    l.note_offset = l.lock - {0, (LOCK_BUTTON_HEIGHT + RULER_GAP) / 2}
}

// The settings, a sheet up from the bottom as tall as its rows, the strobe above it stays in sight to
// show the changes.
SettingsLayout :: struct {
    sheet:      Rect, // runs to the bottom of the window
    title:      [2]f32,
    close:      Rect, // touch area of the ✕
    rows:       [2]f32, // top left of the first row
    width:      f32,
    row_height: f32, // the controls are SETTINGS_CONTROL_MARGIN shorter at the top and bottom
    bottom:     f32, // as far from the home indicator as the rows are from the sides, for what sits under the rows
}

SETTINGS_ICON_SIZE :: ICON_LARGE_SIZE // the sliders, right aligned on the main screen
SETTINGS_ROW_HEIGHT :: 44 // a finger
SETTINGS_CONTROL_MARGIN :: 6 // between the pills and their row, the touch area is the whole row
SETTINGS_TITLE_HEIGHT :: 36 // from the top of the title to the first row

// open is how far the sheet has slid up, 0 is hidden below the window and 1 is all the way. The settings
// have SETTINGS_ROWS, a track's sheet fewer. Either covers the whole panel under the strobe at least, a
// short sheet would leave half the panel peeking out above it. extra is more room under the rows for what
// isn't a row, the note offsets ask for the whole window.
compute_settings_layout :: proc(
    window: [2]f32,
    safe: Rect,
    open: f32,
    rows: int,
    strobe: Rect,
    extra: f32 = 0,
) -> (
    l: SettingsLayout,
) {
    left := safe.x + PANEL_PADDING
    l.width = safe.width - 2 * PANEL_PADDING
    l.row_height = SETTINGS_ROW_HEIGHT

    // Below the rows, the home indicator on a phone
    below := window.y - (safe.y + safe.height) + PANEL_PADDING / 2
    height := PANEL_PADDING + SETTINGS_TITLE_HEIGHT + f32(rows) * l.row_height + extra + below
    height = max(height, window.y - (strobe.y + strobe.height))
    height = min(height, window.y - safe.y)
    l.sheet = {0, window.y - open * height, window.x, height}
    l.bottom = l.sheet.y + height - (window.y - (safe.y + safe.height)) - PANEL_PADDING

    top := l.sheet.y + PANEL_PADDING
    l.title = {left, top}
    // Right aligned with the rows, centred on the title
    l.close = {left + l.width - 32, top - 11, 48, 48}
    l.rows = {left, top + SETTINGS_TITLE_HEIGHT}
    return
}
