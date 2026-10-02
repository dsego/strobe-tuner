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

// The sheets that slide up over the main screen: the settings, a track's and the instrument's. The main
// screen keeps running under them and ignores taps until they're all the way down again. What's on them is
// in settings.odin, instrument.odin and note_offsets.odin.

// A sheet up from the bottom as tall as its rows, the strobe above it stays in sight to show the changes
SheetLayout :: struct {
    sheet:      Rect, // runs to the bottom of the window
    title:      [2]f32,
    close:      Rect, // touch area of the ✕
    rows:       [2]f32, // top left of the first row
    width:      f32,
    row_height: f32, // the controls are SHEET_CONTROL_MARGIN shorter at the top and bottom
    bottom:     f32, // as far from the home indicator as the rows are from the sides, for what sits under the rows
}

// A finger on a phone, a mouse needs less and the settings cover less of the strobe
SHEET_ROW_HEIGHT :: 44 when IOS else 36
SHEET_CONTROL_MARGIN :: 6 // between the pills and their row, the touch area is the whole row
SHEET_TITLE_HEIGHT :: 36 // from the top of the title to the first row

// open is how far the sheet has slid up, 0 is hidden below the window and 1 is all the way. The settings
// have SETTINGS_ROWS, a track's sheet fewer. Either covers the whole panel under the strobe at least, a
// short sheet would leave half the panel peeking out above it. extra is more room under the rows for what
// isn't a row, the instrument's with its note offsets asks for the whole window.
compute_sheet_layout :: proc(
    window: [2]f32,
    safe: Rect,
    open: f32,
    rows: int,
    strobe: Rect,
    extra: f32 = 0,
) -> (
    sheet_layout: SheetLayout,
) {
    left := safe.x + PANEL_PADDING
    sheet_layout.width = safe.width - 2 * PANEL_PADDING
    sheet_layout.row_height = SHEET_ROW_HEIGHT

    // Below the rows, the home indicator on a phone
    below := window.y - (safe.y + safe.height) + PANEL_PADDING / 2
    height := PANEL_PADDING + SHEET_TITLE_HEIGHT + f32(rows) * sheet_layout.row_height + extra + below
    height = max(height, window.y - (strobe.y + strobe.height))
    height = min(height, window.y - safe.y)
    sheet_layout.sheet = {0, window.y - open * height, window.x, height}
    sheet_layout.bottom = sheet_layout.sheet.y + height - (window.y - (safe.y + safe.height)) - PANEL_PADDING

    top := sheet_layout.sheet.y + PANEL_PADDING
    sheet_layout.title = {left, top}
    // Right aligned with the rows, centred on the title
    sheet_layout.close = {left + sheet_layout.width - 32, top - 11, 48, 48}
    sheet_layout.rows = {left, top + SHEET_TITLE_HEIGHT}
    return
}

Sheet :: struct {
    open:     bool,
    slide:    f32, // how far up it is, 0 is hidden and 1 all the way, it follows open
    was_open: bool, // at the start of the frame, the tap that opens the sheet doesn't reach it
    drag:     SheetDrag,
}

// A sheet follows the finger down from anywhere that isn't a control
SheetDrag :: struct {
    active:   bool,
    grab:     f32, // from the top of the sheet to the finger
    last_y:   f32,
    velocity: f32, // points per second, down is positive
}

// Per second, how quickly a sheet closes the distance, like the ruler
SHEET_SLIDE_SPEED :: 14

// Released this far down, or flicked down this fast, the sheet closes, otherwise it slides back up
SHEET_DISMISS_SLIDE :: 0.7
SHEET_DISMISS_VELOCITY :: 600

// At the start of the frame, the sheet eases towards open or closed and snaps the last bit. Dragged all
// the way off it closes, it isn't there to see the finger let go.
slide_sheet :: proc(sheet: ^Sheet) {
    if sheet.drag.active && sheet.slide == 0 do close_sheet(sheet)
    sheet.was_open = sheet.open
    target := f32(int(sheet.open))
    sheet.slide += (target - sheet.slide) * min(1, SHEET_SLIDE_SPEED * gfx_frame_time())
    if abs(target - sheet.slide) < 0.002 do sheet.slide = target
}

close_sheet :: proc(sheet: ^Sheet) {
    sheet.open = false
    sheet.drag = {}
}

// Lays out a sheet that's up, as far as the finger dragging it has moved it, with the strobe's shadow
// on it. swiped is a drag let go to close the sheet. extra is room under the rows, see
// compute_sheet_layout.
begin_sheet :: proc(
    sheet: ^Sheet,
    rows: int,
    strobe_display: ^StrobeDisplay,
    strobe: Rect,
    extra: f32 = 0,
) -> (
    sheet_layout: SheetLayout,
    swiped: bool,
) {
    // Moves the sheet while it's dragged, returns true when it's let go to close
    drag_sheet :: proc(sheet: ^Sheet, sheet_layout: SheetLayout) -> (close: bool) {
        drag := &sheet.drag
        if !drag.active do return false
        mouse := mouse_position()

        if !mouse_down() {
            drag.active = false
            return sheet.slide < SHEET_DISMISS_SLIDE || drag.velocity > SHEET_DISMISS_VELOCITY
        }

        // Smoothed, a finger stops for a frame or two before it lets go
        if dt := gfx_frame_time(); dt > 0 {
            drag.velocity += ((mouse.y - drag.last_y) / dt - drag.velocity) * 0.5
        }
        drag.last_y = mouse.y

        window := gfx_window_size()
        sheet.slide = clamp((window.y - (mouse.y - drag.grab)) / sheet_layout.sheet.height, 0, 1)
        return false
    }

    // Not the tap that opened it, not while it slides away or follows the finger
    gui_disabled = !(sheet.was_open && sheet.open) || sheet.drag.active

    sheet_layout = compute_sheet_layout(gfx_window_size(), gfx_safe_area(), sheet.slide, rows, strobe, extra)
    swiped = drag_sheet(sheet, sheet_layout)
    if sheet.drag.active {
        sheet_layout = compute_sheet_layout(gfx_window_size(), gfx_safe_area(), sheet.slide, rows, strobe, extra)
    }

    // The strobe looks set into the window above the sheet like above the panel, and the edge shades the
    // panel on the way up
    draw_strobe_bottom_shadow(strobe_display, strobe, sheet_layout.sheet.y)
    return
}

// After the sheet's controls, a press on the sheet that none of them took starts dragging it
grab_sheet :: proc(sheet: ^Sheet, sheet_layout: SheetLayout) {
    mouse := mouse_position()
    if gui_press_taken || sheet.drag.active || !gui_background_pressed(sheet_layout.sheet) do return
    sheet.drag = {
        active = true,
        grab   = mouse.y - sheet_layout.sheet.y,
        last_y = mouse.y,
    }
}

// The sheet's background, its title with the lighter details after it, and the ✕. Returns true when the ✕
// is tapped.
draw_sheet_header :: proc(sheet_layout: SheetLayout, title: cstring, details: cstring = nil) -> (close: bool) {
    sheet, close_area, title_position := sheet_layout.sheet, sheet_layout.close, sheet_layout.title
    draw_rect({sheet.x, sheet.y}, {sheet.width, sheet.height}, hex(sheet_bg_color))
    draw_label(pixel_fonts.title, title, title_position, text_color_white, 1)

    if details != nil {
        title_size := measure_label(pixel_fonts.title, title, 1)
        details_y := title_position.y + (title_size.y - LABEL_SIZE) / 2
        draw_label(pixel_fonts.label, details, {title_position.x + title_size.x + 12, details_y}, text_color_light, 1)
    }

    // A 16pt icon in the middle of a larger touch area
    draw_icon(ICON_X, {close_area.x + (close_area.width - 16) / 2, close_area.y + (close_area.height - 16) / 2}, icon_color)
    return gui_button(close_area)
}

// The strobe above the sheet, a tap there closes it
above_sheet :: proc(sheet_layout: SheetLayout) -> Rect {
    return {0, 0, sheet_layout.sheet.width, sheet_layout.sheet.y}
}
