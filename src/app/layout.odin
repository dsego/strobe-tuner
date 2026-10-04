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

import "../gfx"

// Where everything goes, worked out every frame from the window size and the safe area, in points.
// The same on the desktop and a phone, both are portrait windows: the strobe on top, the panel under it.

Layout :: struct {
    strobe:         gfx.Rect,
    strobe_top:     f32, // top of the visible strobe, below the notch
    strobe_scale:   f32, // size of the strobe tracks relative to the desktop
    ruler:          gfx.Rect,
    ruler_scale:    f32, // size of the ruler's notes relative to the desktop
    gauge:          [2]f32, // under the ruler's note, the middle of its top, see draw_cents_gauge
    note:           [2]f32, // top left of the note without the ruler
    measurements:   [2]f32, // see ReadoutAlign
    readout_align:  ReadoutAlign,
    stats:          [2]f32,
    lock:           [2]f32, // the middle of the button
    response:       [2]f32, // hidden with the trace
    level_meter:    [2]f32, // left of the icon, top of the bar
    settings:       [2]f32,
    note_offset:    [2]f32, // the middle of the note's offset, between the letter and the lock
    instrument:     [2]f32, // the icon and the label of what's tuned to in the bottom left corner: their left edge and middle
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
RULER_GAP :: 32 // without the ruler, between the note and the lock, the note's offset is halfway
READOUT_NOTE_TOP :: NOTE_BASELINE - 40 // the 24pt values and the labels above them

// Where the right arrow of the note ends, the readout keeps clear of it
note_right :: proc(layout: Layout) -> f32 {
    return layout.note.x + NOTE_WIDTH - NOTE_RIGHT_ARROW_INSET + NOTE_ARROW_SLOT
}

// offsets is a preset's, room for the note's offset under the gauge
compute_layout :: proc(window: [2]f32, safe: gfx.Rect, ruler: bool, offsets: bool) -> (layout: Layout) {
    left := safe.x + PANEL_PADDING
    right := safe.x + safe.width - PANEL_PADDING
    bottom := safe.y + safe.height - PANEL_PADDING

    // The strobe takes about half of the safe area, its background runs up behind the notch
    layout.strobe_scale = clamp(0.5 * safe.height / STROBE_HEIGHT, 1, 1.4)
    layout.strobe_top = safe.y
    layout.strobe = {0, 0, window.x, safe.y + layout.strobe_scale * STROBE_HEIGHT}
    panel := layout.strobe.y + layout.strobe.height

    layout.stats = {left + 131, panel + 80}
    panel_layout(&layout, left, right, bottom, ruler, RULER_SCALE, offsets)
    return
}

// The response and the level meter in a row just under the strobe, the note with the readout above it
// and the lock under it, and the instrument and the settings in the bottom corners
panel_layout :: proc(layout: ^Layout, left, right, bottom: f32, ruler: bool, ruler_scale: f32, offsets: bool) {
    panel := layout.strobe.y + layout.strobe.height

    // The response changes how fast the strobe spins, it sits just under it on the left, the level meter
    // opposite it on the right. The 4pt bar lines up with the LED.
    layout.response = {left, panel + 20}
    layout.level_meter = {right - LEVEL_METER_WIDTH, layout.response.y - 2}

    // A row along the bottom like the one under the strobe
    corners := bottom - SETTINGS_ICON_SIZE / 2
    layout.settings = {right - SETTINGS_ICON_SIZE, corners - SETTINGS_ICON_SIZE / 2}
    layout.instrument = {left, corners}

    if ruler {
        // The readout in the top row, the response and the level meter centred on its values, the labels
        // sit above. The note with the gauge and the lock under it between the readout values and the bottom
        // row. Offsets from the middle of the ruler.
        layout.ruler_scale = ruler_scale
        readout_top := layout.response.y - LABEL_SIZE / 2
        readout_bottom := readout_top + READOUT_VALUE_Y + BASELINE * ruler_scale * READOUT_SIZE
        layout.response.y = readout_bottom - CAP_HALF * ruler_scale * READOUT_SIZE
        layout.level_meter.y = layout.response.y - 2
        rows_bottom := corners - BOTTOM_ROW_CLEARANCE

        // The readout, the letter with its octave, the gauge, the lock and the bottom row evenly apart. A
        // preset's note offset is a caption under the gauge, the gap to the lock is under the caption.
        OCTAVE_BELOW :: 4 // past the letter's baseline
        MIN_GAP :: 12
        CAPTION_GAP :: 6 // from the gauge to the offset
        caption: f32 = CAPTION_GAP + LABEL_SIZE if offsets else 0
        note_top := -CAP_HALF * ruler_scale * RULER_NOTE_SIZE
        note_bottom := -note_top + ruler_scale * OCTAVE_BELOW
        contents := note_bottom - note_top + GAUGE_HEIGHT + caption + LOCK_BUTTON_HEIGHT
        gap := max((rows_bottom - readout_bottom - contents) / 4, MIN_GAP)
        gauge_y := note_bottom + gap
        caption_y := gauge_y + GAUGE_HEIGHT + CAPTION_GAP + LABEL_SIZE / 2
        lock_y := gauge_y + GAUGE_HEIGHT + caption + gap + LOCK_BUTTON_HEIGHT / 2
        middle := readout_bottom + gap - note_top

        center := (left + right) / 2
        // Centred on the notes and stopping above the gauge, a press on the gauge doesn't swipe the notes
        height := min(ruler_scale * RULER_HEIGHT, 2 * gauge_y)
        layout.ruler = {left, middle - height / 2, right - left, height}
        layout.measurements = {center, readout_top}
        layout.readout_align = .CENTER
        layout.gauge = {center, middle + gauge_y}
        layout.lock = {center, middle + lock_y}
        layout.note_offset = {center, middle + caption_y}
        return
    }

    // The readout next to the note when there's room, otherwise under it, and the lock under both
    layout.ruler_scale = 1
    // Below the response, the top of the note is the room above the letter
    layout.note = {left + NOTE_ARROW_SLOT, panel + 24}
    lock_y := layout.note.y + NOTE_HEIGHT + 24
    if right - READOUT_WIDTH >= note_right(layout^) + 12 {
        layout.measurements = {right, layout.note.y + READOUT_NOTE_TOP}
    } else {
        layout.measurements = {right, layout.note.y + NOTE_HEIGHT}
        lock_y = layout.measurements.y + READOUT_HEIGHT + 24
    }
    // Centred on the note without its arrows
    layout.lock = {layout.note.x + (NOTE_WIDTH - NOTE_RIGHT_ARROW_INSET) / 2, lock_y}
    layout.note_offset = layout.lock - {0, (LOCK_BUTTON_HEIGHT + RULER_GAP) / 2}
}

SETTINGS_ICON_SIZE :: ICON_LARGE_SIZE // the sliders, right aligned on the main screen
BOTTOM_ROW_CLEARANCE :: 46 // from the middle of the bottom row up to the room the note and the lock are centred in
