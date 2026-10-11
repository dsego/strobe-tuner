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

import "../gfx"

// Where everything goes, worked out every frame from the window size and the safe area, in points. A window
// taller than wide stacks the panel under the strobe: a phone, a tablet held upright, the desktop window as it
// opens. One wider than tall puts the panel beside the strobe, on the right, and turns the strobe so the
// disc's hub hides behind the panel as it does under it: a tablet on a music stand, the desktop window
// stretched.

Layout :: struct {
    beside:         bool, // the panel is beside the strobe, not under it
    strobe:         gfx.Rect, // the strobe's background, out to the window's edges or as wide as its disc allows
    strobe_view:    gfx.Rect, // the visible strobe below the notch, where the trace and the scope's views go
    strobe_scale:   f32, // size of the strobe tracks relative to the desktop
    strobe_turned:  bool, // the strobe set into its pane a quarter turn, see strobe_upright
    panel:          gfx.Rect, // the controls, in the safe area, a sheet covers it
    ruler:          gfx.Rect,
    gauge:          [2]f32, // under the ruler's note, the middle of its top, see draw_cents_gauge
    measurements:   [2]f32, // the top middle of the readout, see draw_measurements
    stats:          [2]f32,
    lock:           [2]f32, // the middle of the button
    display:        [2]f32, // the display button's left edge and middle, see gui_display_button
    level_meter:    [2]f32, // left of the icon, top of the bar
    settings:       [2]f32,
    note_offset:    [2]f32, // the middle of the note's offset, between the letter and the lock
    instrument:     [2]f32, // the icon and the label of what's tuned to in the bottom left corner: their left edge and middle
}

STROBE_WIDTH :: 488 // the widest a strobe gets at its scale, see compute_layout
STROBE_HEIGHT :: 306

// The tracks grow with the window up to this many times the desktop's, see compute_layout. A tablet's
// landscape pane fills with them at about 2.3.
STROBE_MAX_SCALE :: 2.4

// A wide window shows more of the disc than the desktop window does, the arcs sweep down to the corners.
// Set, the strobe is cut down to this many times the desktop's width at its scale, in the middle with the
// window's background either side. 0 shows the disc across the whole window.
STROBE_CUTOUT :: 0.0

PANEL_PADDING :: 16
PANEL_MIN_WIDTH :: 424 // the column beside the strobe at its narrowest, the readout still clears the display button and the level meter
STROBE_MIN_WIDTH :: 360 // a phone's, the narrowest the strobe gets
DESKTOP_HEIGHT :: 620 // the window, as wide as the strobe, most of the strobe shows above the settings
WINDOW_MIN_SIZE :: [2]i32{STROBE_MIN_WIDTH, DESKTOP_HEIGHT} // the desktop window shrinks to a phone's width and stretches for the panel beside the strobe
LEVEL_METER_WIDTH :: 80 // the microphone icon and the bar after it
LEVEL_METER_HEIGHT :: 6 // the bar's

RULER_HEIGHT :: 110

// Larger notes and readout values than the ruler was drawn at, they're read from a music stand
RULER_SCALE :: 1.3

// Inter's letters and digits fill less than their font size: the cap height is 0.6 of it, the baseline
// 0.8 down from the top. The ruler is spaced by what's drawn.
CAP_HALF :: 0.3 // the letter's top and baseline from its middle, in font sizes
BASELINE :: 0.8 // from the top of the text, in font sizes

LOCK_BUTTON_HEIGHT :: 24

// Between the columns of the readout, room for the sign
READOUT_GUTTER :: 40

// From the top of the labels to the top of the values
READOUT_VALUE_Y :: 18

// offsets is a preset's, room for the note's offset under the gauge
compute_layout :: proc(window: [2]f32, safe: gfx.Rect, offsets: bool) -> (layout: Layout) {
    // Beside the strobe when the window is wider than tall and half of it is a column for the panel, under
    // it otherwise
    layout.beside = safe.width > safe.height && safe.width >= 2 * PANEL_MIN_WIDTH

    // The disc is the desktop's at the strobe's scale, the strobe the whole window across, or cut down to
    // the desktop's proportions, see STROBE_CUTOUT
    if layout.beside {
        // The strobe and the panel split the window, the strobe on the left never wider than the panel.
        // Turned, its tracks run the pane's height and grow to fill its width.
        half := safe.width / 2
        panel_x := safe.x + half
        layout.panel = {panel_x, safe.y, half, safe.height}
        layout.strobe_turned = true
        layout.strobe_scale = clamp(panel_x / STROBE_HEIGHT, 1, STROBE_MAX_SCALE)
        height := safe.height
        when STROBE_CUTOUT > 0 do height = min(height, STROBE_CUTOUT * STROBE_WIDTH * layout.strobe_scale)

        y := safe.y + (safe.height - height) / 2
        layout.strobe = {0, y, panel_x, height}
        layout.strobe_view = {safe.x, y, panel_x - safe.x, height}
    } else {
        // The strobe takes about half of the safe area, its background runs up behind the notch
        layout.strobe_scale = clamp(0.5 * safe.height / STROBE_HEIGHT, 1, STROBE_MAX_SCALE)
        width := window.x
        when STROBE_CUTOUT > 0 do width = min(width, STROBE_CUTOUT * STROBE_WIDTH * layout.strobe_scale)

        x := (window.x - width) / 2
        layout.strobe = {x, 0, width, safe.y + layout.strobe_scale * STROBE_HEIGHT}
        layout.strobe_view = {x, safe.y, width, layout.strobe_scale * STROBE_HEIGHT}
        strobe_bottom := layout.strobe.y + layout.strobe.height
        layout.panel = {safe.x, strobe_bottom, safe.width, safe.y + safe.height - strobe_bottom}
    }

    layout.stats = {layout.panel.x + PANEL_PADDING + 131, layout.panel.y + 80}
    panel_layout(&layout, offsets)
    return
}

// The display button and the level meter in a row along the top of the panel, the note with the readout
// above it and the lock under it, and the instrument and the settings in the bottom corners
panel_layout :: proc(layout: ^Layout, offsets: bool) {
    panel := layout.panel
    left := panel.x + PANEL_PADDING
    right := panel.x + panel.width - PANEL_PADDING
    bottom := panel.y + panel.height - PANEL_PADDING

    // The display button picks what the strobe area shows, it sits at the top of the panel on the left, the
    // level meter opposite it on the right. The bar lines up with the button's icon.
    layout.display = {left, panel.y + 20}
    layout.level_meter = {right - LEVEL_METER_WIDTH, layout.display.y - LEVEL_METER_HEIGHT / 2}

    // A row along the bottom like the one under the strobe
    corners := bottom - SETTINGS_ICON_SIZE / 2
    layout.settings = {right - SETTINGS_ICON_SIZE, corners - SETTINGS_ICON_SIZE / 2}
    layout.instrument = {left, corners}

    // The readout in the top row, the display button and the level meter centred on its values, the labels
    // sit above. The note with the gauge and the lock under it between the readout values and the bottom row.
    // Offsets from the middle of the ruler.
    readout_top := layout.display.y - LABEL_SIZE / 2
    readout_bottom := readout_top + READOUT_VALUE_Y + BASELINE * RULER_SCALE * READOUT_SIZE
    layout.display.y = readout_bottom - CAP_HALF * RULER_SCALE * READOUT_SIZE
    layout.level_meter.y = layout.display.y - LEVEL_METER_HEIGHT / 2
    rows_bottom := corners - BOTTOM_ROW_CLEARANCE

    // The readout, the letter with its octave, the gauge, the lock and the bottom row evenly apart. A
    // preset's note offset is a caption under the gauge, the gap to the lock is under the caption.
    OCTAVE_BELOW :: 4 // past the letter's baseline
    MIN_GAP :: 12
    CAPTION_GAP :: 6 // from the gauge to the offset
    caption: f32 = CAPTION_GAP + LABEL_SIZE if offsets else 0
    note_top: f32 = -CAP_HALF * RULER_SCALE * RULER_NOTE_SIZE
    note_bottom := -note_top + RULER_SCALE * OCTAVE_BELOW
    contents := note_bottom - note_top + GAUGE_HEIGHT + caption + LOCK_BUTTON_HEIGHT
    gap := max((rows_bottom - readout_bottom - contents) / 4, MIN_GAP)
    gauge_y := note_bottom + gap
    caption_y := gauge_y + GAUGE_HEIGHT + CAPTION_GAP + LABEL_SIZE / 2
    lock_y := gauge_y + GAUGE_HEIGHT + caption + gap + LOCK_BUTTON_HEIGHT / 2
    middle := readout_bottom + gap - note_top

    center := (left + right) / 2

    // Centred on the notes and stopping above the gauge, a press on the gauge doesn't swipe the notes
    height := min(RULER_SCALE * RULER_HEIGHT, 2 * gauge_y)
    layout.ruler = {left, middle - height / 2, right - left, height}
    layout.measurements = {center, readout_top}
    layout.gauge = {center, middle + gauge_y}
    layout.lock = {center, middle + lock_y}
    layout.note_offset = {center, middle + caption_y}
}

SETTINGS_ICON_SIZE :: ICON_LARGE_SIZE // the sliders, right aligned on the main screen
BOTTOM_ROW_CLEARANCE :: 46 // from the middle of the bottom row up to the room the note and the lock are centred in
