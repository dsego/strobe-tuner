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
import "core:strings"
import "core:time"
import "core:unicode/utf8"


import "../core"
import "../gfx"


// Who has the input this frame, the controls ask before they take a press
Gui :: struct {
    menu_open:   bool,      // a dropdown takes every press until it closes
    disabled:    bool,      // the controls being drawn ignore input, e.g. the main screen under a sheet
    press_taken: bool,      // a control took this frame's press, one nothing took drags a sheet down
    repeat:      GuiRepeat, // the held repeat button and when it fires again
    stepper:     GuiStepper, // the scroll and the clicks on a stepper, see gui_stepper_buttons
}

GuiRepeat :: struct {
    button: gfx.Rect,
    next:   time.Tick,
}

// Each kept for the one stepper it was on, a few on a sheet
GuiStepper :: struct {
    scroll:      f32, // the fraction of a step a trackpad scrolled so far
    scroll_rect: gfx.Rect,
    last_click:  time.Tick, // between the buttons, two soon after each other reset it
    click_rect:  gfx.Rect,
}

gui: Gui

// Before the frame's controls, nothing has taken a press yet
gui_begin_frame :: proc() {
    gui.press_taken = false
}

// A control takes a press, nothing above it has the input
gui_takes_input :: proc() -> bool {
    return !gui.menu_open && !gui.disabled
}

sheet_bg_color: u32 = 0x40414AFF
strobe_bg_color: u32 = 0x15161AFF
settings_separator_color := gfx.hex(0x35363EFF)
note_offset_selected_color := gfx.hex(0x4D4E58FF)
menu_highlight_color := gfx.hex(0x15141BFF) // a dropdown's option under the finger

text_color_dark := gfx.hex(0x15141BFF)
text_color_light := gfx.hex(0xBDBDBDFF)
text_color_white := gfx.hex(0xFBFBFBFF) // the note and readout while there's a pitch, titles
text_color_muted := gfx.hex(0x7D7E8FFF) // the note and readout without a pitch, the ruler's neighbours
text_color_hover := gfx.hex(0xFFFFFFFF) // a dropdown's option under the finger
text_color_disabled := gfx.hex(0x5C5D6AFF) // a control that does nothing right now, on a dark pill
icon_color := gfx.hex(0x9A9BAAFF)
accent_color := gfx.hex(0x82E2FFFF) // the input level, the arrows, the partial labels and the note offsets
warning_color := gfx.hex(0xFFC857FF) // a slow input's warning next to its level

// Buttons
pill_gray := text_color_muted
pill_violet := gfx.hex(0xA277FFFF)
pill_yellow := gfx.hex(0xFFCA85FF)
pill_dark := gfx.hex(0x2D2E35FF)

lerp_color :: proc(from, to: gfx.Color, amount: f32) -> gfx.Color {
    color: gfx.Color
    for channel in 0 ..< 4 {
        color[channel] = u8(math.round(math.lerp(f32(from[channel]), f32(to[channel]), amount)))
    }
    return color
}

// The color with its alpha times amount
fade_color :: proc(color: gfx.Color, amount: f32) -> gfx.Color {
    faded := color
    faded.a = u8(f32(color.a) * amount)
    return faded
}

// The arrows icon and the shown display's name after it, a tap goes on to the next display. pos is the
// left edge, vertically centred.
gui_display_button :: proc(pos: [2]f32, type: StrobeDisplayType) -> bool {
    ICON_GAP :: 8
    TOUCH_HEIGHT :: 44

    draw_icon(ICON_ARROWS_LEFT_RIGHT, {pos.x, pos.y - ICON_SIZE / 2}, icon_color)

    labels := DISPLAY_LABELS
    label := labels[type]
    label_x := pos.x + ICON_SIZE + ICON_GAP
    label_width := measure_label(pixel_fonts.label, label, 1).x
    draw_label(pixel_fonts.label, label, {label_x, pos.y - 7}, text_color_light, 1)

    // The icon and the label, a little past them on each side
    width := label_x + label_width - pos.x
    return gui_button({pos.x - 12, pos.y - TOUCH_HEIGHT / 2, width + 24, TOUCH_HEIGHT})
}

// The note lock as a labelled button, gray while off and violet while locked. center is the middle of the
// button.
gui_lock_toggle :: proc(center: [2]f32, locked: bool) -> bool {
    LABEL :: "LOCK NOTE"
    PADDING :: 10
    TOUCH_HEIGHT :: 44

    label_size := measure_label(pixel_fonts.label, LABEL, 1)
    width := label_size.x + 2 * PADDING
    rect := gfx.Rect{center.x - width / 2, center.y - LOCK_BUTTON_HEIGHT / 2, width, LOCK_BUTTON_HEIGHT}

    gfx.draw_pill(rect, pill_violet if locked else pill_gray)
    draw_label(pixel_fonts.label, LABEL, center - label_size / 2, text_color_dark, 1)

    return gui_button({rect.x, center.y - TOUCH_HEIGHT / 2, rect.width, TOUCH_HEIGHT})
}


// A partial without the ×, the fifth as 1½ like the 1 1½ 2 preset
partial_text :: proc(partial: f32) -> cstring {
    if partial == 1.5 do return "1½"

    return fmt.ctprintf("%v", partial)
}

// Right aligned at position, a track's offset from the exact partial goes before it so it's never hidden.
// Tapping the track opens its sheet, see strobe_track_at.
// position is the label's top right, or its middle when centered
draw_strobe_partial_label :: proc(position: [2]f32, type: PartialLabelType, band: core.PhaseBand, centered := false) {
    text: cstring
    font := pixel_fonts.band_label

    if type == .FREQUENCY {
        font = pixel_fonts.band_label_small
        text = fmt.ctprintf("%.1fHz", band.freq_hz)
    } else if type == .NOTE_NAMES {
        // Inter has no ♯ or ♭, a plain # and b read fine at this size
        text = fmt.ctprintf("%s", core.note_name(band.note))
    } else {
        text = fmt.ctprintf("%v×", partial_text(band.interval))
    }

    text_size := measure_label(font, text)
    bounds: gfx.Rect = {position.x - text_size.x, position.y, text_size.x, text_size.y}
    if centered do bounds.x, bounds.y = position.x - text_size.x / 2, position.y - text_size.y / 2

    draw_label(font, text, {bounds.x, bounds.y}, accent_color)

    // Left of the label, or under a centred one: the turned strobe's labels sit side by side a track apart
    if band.offset_cents != 0 {
        offset_font := pixel_fonts.band_label_small
        offset := offset_cents_text(band.offset_cents)
        offset_size := measure_label(offset_font, offset)
        center_y := bounds.y + text_size.y / 2
        offset_position := [2]f32{bounds.x - 6 - offset_size.x, center_y - offset_size.y / 2}
        if centered do offset_position = {position.x - offset_size.x / 2, bounds.y + text_size.y + 2}

        draw_label(offset_font, offset, offset_position, accent_color)
    }
}


// The ruler, the notes in a row with the target note large in the middle: every semitone, or an
// instrument's strings in the order they're tuned.
// The notes slide over to the next one, further jumps snap, a swipe drags the row. A note grows as it
// comes into the middle and shrinks as it goes.
// The fonts are loaded at the exact sizes, see update_pixel_fonts, and everything lands on whole pixels.

RULER_SPACING :: 70 // between the letters of neighbouring notes, room for a sharp between them
RULER_CENTER_GAP :: 30 // extra room either side of the large note
RULER_EDGE :: 36 // half a letter and a sharp, the outermost ones stay inside the edges
RULER_MAX_PER_SIDE :: 2
RULER_HALFWAY :: 0.5 // notes, closer to the middle than this a note is the one in the middle
RULER_SLIDE_SPEED :: 14 // per second, how quickly the slide closes the distance
RULER_SWIPE_START :: 10 // points sideways before a press on the ruler is a swipe and not a tap
RULER_VELOCITY_S :: 0.024 // the finger's speed smoothed over about this long, half of it each frame at 60 FPS
RULER_COAST_MAX :: 20 // notes per second
RULER_COAST_MIN :: 2 // notes per second, let go slower than this it settles on the nearest note
RULER_COAST_FRICTION :: 4 // how far a flick coasts, 1/4 of a second at the finger's speed, in about 1/2 a second

// The ruler between frames
NoteRuler :: struct {
    position:    f32, // where the middle is, counted in its notes, it follows the target note a little behind
    initialized: bool,
    swipe:       RulerSwipe,
}

note_ruler: NoteRuler

// Where the ruler's notes go in its rect. The gaps grow with the letters, the fonts were loaded at the
// layout's size.
RulerLayout :: struct {
    rect:       gfx.Rect,
    center:     [2]f32,
    spacing:    f32, // between the letters of neighbouring notes
    center_gap: f32, // extra room either side of the large note
    per_side:   int, // as many neighbours as fit, up to 2 a side, the same distance apart in any width
}

// A press on the ruler. Let go where it was, a tap on a neighbour selects it. Moved sideways it's a swipe,
// the row follows the finger, and let go it coasts on with the finger's speed and slows down. Only the
// note it settles on becomes the target.
RulerGesture :: enum {
    NONE,
    PRESSED, // let go where it was it's a tap
    CAUGHT, // pressed while it coasted, let go without swiping it settles where it is
    SWIPING, // the row follows the finger
    COASTING, // let go, it slows down to a stop on a note
}

// The row moved off its note or about to, it lands on one when it's over
RULER_MOVING :: bit_set[RulerGesture]{.CAUGHT, .SWIPING, .COASTING}

RulerSwipe :: struct {
    gesture:  RulerGesture,
    press_x:  f32, // where the finger was when the row started following it
    grab:     f32, // the ruler's position then
    last_x:   f32,
    velocity: f32, // points per second, right is positive
    coast:    f32, // seconds the coast takes
    coasted:  f32, // seconds so far
    from:     f32, // the ruler's position when let go
    stop_at:  f32, // the note it coasts to
}

// notes[target] is the target note, none hides the ruler. Returns how many notes to step when another note is
// tapped or the note in the middle of a swipe changes, whether the target itself was tapped, which toggles the
// lock like the lock button, and whether the row is swiped or coasting, which locks the note even when it
// lands back on the same one.
gui_note_ruler :: proc(
    rect: gfx.Rect,
    notes: []core.Note,
    target: int,
    active: bool,
) -> (
    step: int,
    toggle_lock: bool,
    swiping: bool,
) {
    ruler := &note_ruler
    if len(notes) == 0 {
        ruler.swipe = {}
        return
    }
    if !ruler.initialized {
        ruler.position = f32(target)
        ruler.initialized = true
    }

    layout := ruler_layout(rect)
    settle, land, tapped := ruler_follow_finger(ruler, rect, layout.spacing, f32(len(notes) - 1))
    gesture := ruler.swipe.gesture
    swiping = gesture in RULER_MOVING

    // The note in the middle is the target, already while the row follows the finger or coasts. Settled, the
    // ruler eases onto it from where it is.
    step = int(settle) - target if swiping || land else 0
    if land do ruler.swipe = {}

    if !swiping || land {
        // Slide to the next note, and settle exactly on it, a jump further snaps
        shown := f32(target + step)
        if abs(shown - ruler.position) > 1 && step == 0 do ruler.position = shown

        ruler.position += (shown - ruler.position) * (1 - math.exp(-RULER_SLIDE_SPEED * gfx.frame_time()))
        if abs(shown - ruler.position) < RULER_ON_NOTE do ruler.position = shown
    }

    // The target note is white while there's a pitch
    draw_ruler(layout, notes, ruler.position, text_color_white if active else text_color_muted)

    if tapped do step, toggle_lock = ruler_tap(layout, notes, ruler.position, target)

    return
}

// Moves the row with the finger and the coast. settle is where it settles, the nearest note or the next one
// on the way, land a swipe or a coast that's over, tapped a press let go where it was. The cases in order,
// the first that holds is the one.
ruler_follow_finger :: proc(ruler: ^NoteRuler, rect: gfx.Rect, spacing, highest: f32) -> (settle: f32, land, tapped: bool) {
    swipe := &ruler.swipe
    mouse_x := gfx.mouse_position().x

    switch {
    case gui.disabled:
        // A sheet opened over it, a swipe on the way lands
        land = swipe.gesture in RULER_MOVING
        if !land do swipe^ = {}
    case swipe.gesture == .COASTING && gfx.mouse_pressed():
        // Caught on the ruler it stops there and can be swiped on, a press anywhere else settles it
        if gui_background_pressed(rect) do swipe^ = ruler_press(.CAUGHT, mouse_x)
        else do land = true
    case swipe.gesture == .COASTING:
        land = ruler_coast(swipe, &ruler.position)
    case swipe.gesture == .NONE:
        if gui_background_pressed(rect) do swipe^ = ruler_press(.PRESSED, mouse_x)
    case gfx.mouse_down():
        ruler_drag(swipe, &ruler.position, mouse_x, spacing)
    case swipe.gesture == .SWIPING:
        land = ruler_let_go(swipe, ruler.position, spacing, highest)
    case swipe.gesture == .CAUGHT:
        land = true
    case:
        tapped = true
        swipe^ = {}
    }

    // Not past the ends
    if ruler.position <= 0 || ruler.position >= highest {
        ruler.position = clamp(ruler.position, 0, highest)
        if swipe.gesture == .COASTING do land = true
    }
    settle = math.round(ruler.position)
    return
}

RULER_ON_NOTE :: 0.002 // notes, closer than this the row is on the note

// A press at x, the row follows it once it moves
ruler_press :: proc(gesture: RulerGesture, x: f32) -> RulerSwipe {
    return {gesture = gesture, press_x = x, last_x = x}
}

// Slowing down steadily to a stop on the note, from the finger's speed. Returns true when it's there.
ruler_coast :: proc(swipe: ^RulerSwipe, position: ^f32) -> (land: bool) {
    swipe.coasted += gfx.frame_time()
    left := max(1 - swipe.coasted / swipe.coast, 0)
    position^ = swipe.stop_at + (swipe.from - swipe.stop_at) * left * left
    return left == 0
}

// The row under the finger once it's moved past RULER_SWIPE_START, to the left brings in the notes on the
// right. The finger's speed kept for the coast.
ruler_drag :: proc(swipe: ^RulerSwipe, position: ^f32, mouse_x, spacing: f32) {
    // Smoothed, a finger stops for a frame or two before it lets go
    if dt := gfx.frame_time(); dt > 0 {
        swipe.velocity += ((mouse_x - swipe.last_x) / dt - swipe.velocity) * (1 - math.exp(-dt / RULER_VELOCITY_S))
    }
    swipe.last_x = mouse_x

    if swipe.gesture != .SWIPING && abs(mouse_x - swipe.press_x) > RULER_SWIPE_START {
        // From here, the few points it took don't make the row jump
        swipe.gesture = .SWIPING
        swipe.press_x = mouse_x
        swipe.grab = position^
    }
    if swipe.gesture == .SWIPING do position^ = swipe.grab + (swipe.press_x - mouse_x) / spacing
}

// Let go of a swipe, it coasts to where friction would stop it, rounded to a note on the way. Slowing down
// evenly from the finger's speed it takes twice as long as at that speed. Returns true when it lands where
// it is, too slow or already on the note.
ruler_let_go :: proc(swipe: ^RulerSwipe, position, spacing, highest: f32) -> (land: bool) {
    speed := clamp(-swipe.velocity / spacing, -RULER_COAST_MAX, RULER_COAST_MAX)
    stop := position + speed / RULER_COAST_FRICTION
    swipe.stop_at = clamp(math.round(stop), 0, highest)
    if speed > 0 do swipe.stop_at = max(swipe.stop_at, math.ceil(position))
    if speed < 0 do swipe.stop_at = min(swipe.stop_at, math.floor(position))

    distance := swipe.stop_at - position
    if abs(speed) < RULER_COAST_MIN || abs(distance) < RULER_ON_NOTE do return true

    swipe.gesture = .COASTING
    swipe.coast = 2 * distance / speed
    swipe.coasted = 0
    swipe.from = position
    return false
}

ruler_layout :: proc(rect: gfx.Rect) -> RulerLayout {
    scale :: RULER_SCALE
    layout := RulerLayout {
        rect       = rect,
        center     = {rect.x + rect.width / 2, rect.y + rect.height / 2},
        spacing    = scale * RULER_SPACING,
        center_gap = scale * RULER_CENTER_GAP,
    }
    room := rect.width / 2 - scale * RULER_EDGE - layout.center_gap
    layout.per_side = clamp(int(room / layout.spacing), 1, RULER_MAX_PER_SIDE)
    return layout
}

// The notes around position, and the next one out at each end while it slides in or out
ruler_shown_notes :: proc(layout: RulerLayout, position: f32, count: int) -> (first, last: int) {
    first = max(int(math.floor(position)) - layout.per_side - 1, 0)
    last = min(int(math.ceil(position)) + layout.per_side + 1, count - 1)
    return
}

// Across the middle of a note offset notes from the middle of the ruler, past the gap on either side
ruler_note_x :: proc(layout: RulerLayout, offset: f32) -> f32 {
    return layout.center.x + offset * layout.spacing + math.sign(offset) * layout.center_gap * min(abs(offset), 1)
}

// Notes slide in and out at the ends, fading. note_color is the target's.
draw_ruler :: proc(layout: RulerLayout, notes: []core.Note, position: f32, note_color: gfx.Color) {
    first, last := ruler_shown_notes(layout, position, len(notes))
    for index in first ..= last {
        offset := f32(index) - position
        distance := abs(offset)

        // Large in the middle and small a note away, in between it grows as it comes in and shrinks as it goes
        large := 1 - math.smoothstep(f32(0), 1, distance)

        // The octave fades in on the way to the middle, gone halfway so there's only ever one
        octave := 1 - math.smoothstep(f32(0), RULER_HALFWAY, distance)

        // Muted a note away, the ones at the ends fade out
        color := fade_color(lerp_color(text_color_muted, note_color, large), clamp(f32(layout.per_side) + 1 - distance, 0, 1))

        draw_ruler_note(notes[index], {ruler_note_x(layout, offset), layout.center.y}, large, octave, color)
    }
}

// Tapping another note locks it, tapping the target toggles the lock. The target's touch area reaches over the
// gaps either side of it up to its neighbours'.
ruler_tap :: proc(layout: RulerLayout, notes: []core.Note, position: f32, target: int) -> (step: int, toggle_lock: bool) {
    mouse := gfx.mouse_position()
    rect := layout.rect
    first, last := ruler_shown_notes(layout, position, len(notes))
    for index in first ..= last {
        offset := f32(index) - position
        distance := abs(offset)
        x := ruler_note_x(layout, offset)
        if index == target && distance < RULER_HALFWAY {
            half := layout.spacing / 2 + layout.center_gap
            toggle_lock = gfx.point_in_rect(mouse, {x - half, rect.y, 2 * half, rect.height})
        } else if index != target && distance <= f32(layout.per_side) {
            if gfx.point_in_rect(mouse, {x - layout.spacing / 2, rect.y, layout.spacing, rect.height}) do step = index - target
        }
    }
    return
}

// The name centred on pos, the sharp or the flat and the octave to the right, octave is how much of it shows
// (in the middle). large is how far it's grown from a neighbour to the target, in between it's drawn from the
// large letters scaled down, settled at the fonts' own sizes, texel for pixel.
draw_ruler_note :: proc(note: core.Note, pos: [2]f32, large, octave: f32, color: gfx.Color) {
    SIGNS :: [core.Accidental]cstring{.NATURAL = "", .SHARP = "♯", .FLAT = "♭"}

    // From the letter's top right, of its size, the tops of both signs level with the letter's and their left
    // edges in the octave's column. Noto's monospace flat sits lower and further in in its larger font.
    SIGN_OFFSETS :: [core.Accidental][2]f32{.NATURAL = {0, 0}, .SHARP = {0, 0.1}, .FLAT = {-0.05, -0.05}}

    name_font := lerp_font(pixel_fonts.neighbour, pixel_fonts.note, large)
    sign_font := lerp_font(pixel_fonts.neighbour_sharp, pixel_fonts.note_sharp, large)
    if note.accidental == .FLAT do sign_font = lerp_font(pixel_fonts.neighbour_flat, pixel_fonts.note_flat, large)

    size := name_font.size

    name := fmt.ctprintf("%v", note.name)
    name_size := gfx.measure_text(name_font.font, name, size, 0)
    octave_label := fmt.ctprintf("%v", note.octave)
    signs, sign_offsets := SIGNS, SIGN_OFFSETS
    sign := signs[note.accidental]

    // The sign and the octave hang off to the right. Centred on the letter the note looks pushed right,
    // centred with them the letter looks pushed left, they're small and thin and weigh less than their
    // width. Halfway looks centred, once it's settled. A neighbour is centred on its letter so the letters
    // are evenly spaced.
    OPTICAL_WEIGHT :: 0.5
    suffix := octave * measure_label(pixel_fonts.octave, octave_label).x
    if note.accidental != .NATURAL do suffix = max(suffix, gfx.measure_text(sign_font.font, sign, sign_font.size, 0).x)

    center := pos - {large * OPTICAL_WEIGHT * suffix / 2, 0}

    top_left := snap_to_pixels(center - name_size / 2)
    gfx.draw_text(name_font.font, name, top_left, size, 0, color)

    right := top_left.x + name_size.x
    if note.accidental != .NATURAL {
        sign_pos := snap_to_pixels({right, top_left.y} + sign_offsets[note.accidental] * size)
        gfx.draw_text(sign_font.font, sign, sign_pos, sign_font.size, 0, color)
    }

    if octave > 0 {
        font := pixel_fonts.octave
        octave_pos := snap_to_pixels({right, top_left.y + name_size.y - 1.3 * font.size})
        gfx.draw_text(font.font, octave_label, octave_pos, font.size, 0, fade_color(color, octave))
    }
}


// The gauge under the ruler's note, a row of ticks that slides like an old bathroom scale's dial. The red
// tick is as far off the note as the pitch, flat on the left like the lower notes on the ruler. It's a map,
// the strobe does the fine tuning: it steps tick to tick, glides over, and holds while there's no pitch.
// Each tick out from the middle is a wider range of cents than the one before, up to half a semitone where
// the next note takes over. A string is tuned up from further away, its ticks go on a semitone each.
GAUGE_CENTS :: [?]f32{0, 5, 10, 20, 35, 50} // the distances in ticks from the middle outwards
GAUGE_SEMITONE_TICKS :: 3
GAUGE_SPACING :: 13 // between the ticks, it grows with the ruler
GAUGE_TICK :: 12 // tall, the red one and every few are GAUGE_HEIGHT
GAUGE_HEIGHT :: 20
GAUGE_SLIDE_SPEED :: 6 // per second, how quickly it closes the distance to the next tick
GAUGE_HYSTERESIS_CENTS :: 1 // past the halfway between two ticks, so it doesn't flicker between them

// Where the red tick is, counted in ticks from under the note, flat is negative
gauge_position: f32
gauge_target: f32 // the tick it's going to

// The tick for the cents: the middle one up to the first tick, further out the nearest, the outermost for
// anything further
gauge_snap :: proc(cents: f32, per_side: int) -> f32 {
    tick_cents :: proc(index: int) -> f32 {
        ticks := GAUGE_CENTS
        return ticks[index] if index < len(ticks) else 100 * f32(index - len(ticks) + 1)
    }
    index := 0
    for index < per_side {
        upper := tick_cents(index + 1)
        halfway := upper if index == 0 else (tick_cents(index) + upper) / 2
        if abs(cents) < halfway do break

        index += 1
    }
    return math.sign(cents) * f32(index)
}

// top is the middle of the gauge at its top. Follows the cents from the target while there's a pitch.
draw_cents_gauge :: proc(top: [2]f32, cents: f32, lit: bool, semitones: bool, color: gfx.Color) {
    ticks := GAUGE_CENTS
    per_side := len(ticks) - 1 + (GAUGE_SEMITONE_TICKS if semitones else 0)

    // It stays on its tick while the pitch is within the hysteresis of it
    if lit {
        lowest := gauge_snap(cents - GAUGE_HYSTERESIS_CENTS, per_side)
        highest := gauge_snap(cents + GAUGE_HYSTERESIS_CENTS, per_side)
        if gauge_target < lowest || gauge_target > highest do gauge_target = gauge_snap(cents, per_side)
    }

    gauge_target = clamp(gauge_target, -f32(per_side), f32(per_side))
    gauge_position += (gauge_target - gauge_position) * (1 - math.exp(-GAUGE_SLIDE_SPEED * gfx.frame_time()))

    // The ticks either side of the red one, as far as the room reaches from under the note, every few long
    // like a ruler's. Not snapped to the pixels, they glide.
    LONG_EVERY :: 5
    spacing: f32 = RULER_SCALE * GAUGE_SPACING
    first := int(math.floor(-f32(per_side) - gauge_position)) - 1
    last := int(math.ceil(f32(per_side) - gauge_position)) + 1
    for offset in first ..= last {
        along := f32(offset) + gauge_position
        fade := clamp(f32(per_side) + 1 - abs(along), 0, 1)
        if fade == 0 do continue

        red := offset == 0
        long := red || offset % LONG_EVERY == 0
        height: f32 = GAUGE_HEIGHT if long else GAUGE_TICK
        width: f32 = 2 if red else 1

        // Red while there's a pitch
        tick_color := fade_color(color if red && lit else text_color_muted, fade)
        gfx.draw_rect({top.x + along * spacing - width / 2, top.y + (GAUGE_HEIGHT - height) / 2}, {width, height}, tick_color)
    }
}

gui_button :: proc(bounds: gfx.Rect) -> bool {
    if !gui_background_pressed(bounds) do return false

    gui.press_taken = true
    return true
}

// A press on the background, it doesn't take the press like a button so it can still drag the sheet
gui_background_pressed :: proc(bounds: gfx.Rect) -> bool {
    return gfx.mouse_pressed() && gfx.point_in_rect(gfx.mouse_position(), bounds) && gui_takes_input()
}

// Like gui_button, and held down it goes on firing, after a pause and then steadily, like a key repeat.
// Sliding off the button pauses it, sliding back on carries on.
gui_button_repeat :: proc(bounds: gfx.Rect) -> bool {
    REPEAT_DELAY :: 400 * time.Millisecond
    REPEAT_INTERVAL :: 80 * time.Millisecond

    if gui_button(bounds) {
        gui.repeat = {bounds, time.tick_add(time.tick_now(), REPEAT_DELAY)}
        return true
    }
    if gui.repeat.button != bounds || !gui_button_held(bounds) do return false

    now := time.tick_now()
    if time.tick_diff(gui.repeat.next, now) < 0 do return false

    gui.repeat.next = time.tick_add(now, REPEAT_INTERVAL)
    return true
}

// Whether the button is being held down, to draw it in its pressed shade
gui_button_held :: proc(bounds: gfx.Rect) -> bool {
    return gfx.mouse_down() && gfx.point_in_rect(gfx.mouse_position(), bounds) && gui_takes_input()
}


GuiOption :: struct {
    id:    i32,
    label: string,
}

DROPDOWN_CARET_WIDTH :: 22 // from the button's right edge
DROPDOWN_LABEL_GAP :: 4 // between the button's label and the caret
DROPDOWN_OPTION_HEIGHT :: 24
DROPDOWN_MENU_GAP :: 6 // between the button and the menu, it counts as the menu's for the presses
DROPDOWN_MENU_RADIUS :: 12
DROPDOWN_MENU_PAD :: 4 // above the first option and below the last one, part of them and their highlight
DROPDOWN_DIVIDER_SPACE :: 8 // between the groups, the line in the middle
DROPDOWN_DIVIDER_INSET :: 6 // the line a little in from the edges of the menu
DROPDOWN_TEXT_INSET :: 12 // an option's label from the menu's edges
DROPDOWN_TEXT_DROP :: 4 // an option's label from its top

// A button with the selected option that opens a menu of them above it, or under it with down. Returns
// whether the menu is open, selected changes when an option is picked.
gui_dropdown :: proc(
    position: [2]f32,
    width: f32,
    options: []GuiOption,
    selected: ^int,
    open: bool,
    left_pad: f32 = 12,
    height: f32 = 24,
    down := false, // the menu opens under the button, it's drawn after the controls below it
    dividers: []int = nil, // the options with a line above them, each starts a group
) -> bool {
    button_rect := gfx.Rect{position.x, position.y, width, height}
    draw_dropdown_button(button_rect, options[selected^].label, left_pad)

    menu_rect := dropdown_menu_rect(button_rect, len(options), dividers, down)
    if !dropdown_press(open, button_rect, menu_rect, down) do return false

    picked, was_picked := draw_dropdown_menu(menu_rect, options, dividers)
    if was_picked {
        selected^ = picked
        gui.menu_open = false
        return false
    }
    return true
}

draw_dropdown_button :: proc(rect: gfx.Rect, label: string, left_pad: f32) {
    gfx.draw_pill(rect, pill_dark)
    draw_centered_icon(ICON_CARET_DOWN, {rect.x + rect.width - DROPDOWN_CARET_WIDTH, rect.y, ICON_SIZE, rect.height}, icon_color)

    fitted := fit_label(pixel_fonts.label, label, rect.width - left_pad - DROPDOWN_CARET_WIDTH - DROPDOWN_LABEL_GAP)
    draw_label(pixel_fonts.label, fitted, {rect.x + left_pad, rect.y + (rect.height - LABEL_SIZE) / 2}, text_color_light, 1)
}

// Where the open menu is drawn, the options one under the other with room for the dividers
dropdown_menu_rect :: proc(button_rect: gfx.Rect, count: int, dividers: []int, down: bool) -> gfx.Rect {
    height := f32(count * DROPDOWN_OPTION_HEIGHT) + 2 * DROPDOWN_MENU_PAD
    for index in 0 ..< count {
        if dropdown_divider_above(dividers, index) do height += DROPDOWN_DIVIDER_SPACE
    }

    y := button_rect.y - height - DROPDOWN_MENU_GAP
    if down do y = button_rect.y + button_rect.height + DROPDOWN_MENU_GAP
    return {button_rect.x, y, button_rect.width, height}
}

// Every option in dividers but the first starts a group with a line above it
dropdown_divider_above :: proc(dividers: []int, index: int) -> bool {
    return index > 0 && slice.contains(dividers, index)
}

// A press on the button opens the menu, one outside the menu and its gap closes it. An open menu takes every
// press, an option's or not.
dropdown_press :: proc(open: bool, button_rect, menu_rect: gfx.Rect, down: bool) -> bool {
    if !gfx.mouse_pressed() do return open

    mouse := gfx.mouse_position()
    if open {
        gui.press_taken = true

        reach := menu_rect
        reach.height += DROPDOWN_MENU_GAP
        if down do reach.y -= DROPDOWN_MENU_GAP
        if gfx.point_in_rect(mouse, reach) do return true

        gui.menu_open = false
        return false
    }

    if gui_takes_input() && gfx.point_in_rect(mouse, button_rect) {
        gui.menu_open = true
        gui.press_taken = true
        return true
    }
    return false
}

// The open menu, the option under the finger highlighted and picked by a press
draw_dropdown_menu :: proc(rect: gfx.Rect, options: []GuiOption, dividers: []int) -> (picked: int, was_picked: bool) {
    // Follows the menu's corners on the first and the last option: rounded all around, then the side facing
    // the other options squared off
    draw_option_highlight :: proc(rect: gfx.Rect, first, last: bool) {
        square := [2]f32{rect.width, rect.height - DROPDOWN_MENU_RADIUS}
        if first || last {
            gfx.draw_rounded_rect(rect, DROPDOWN_MENU_RADIUS, menu_highlight_color)
        }
        if !first {
            gfx.draw_rect({rect.x, rect.y}, square, menu_highlight_color)
        }
        if !last {
            gfx.draw_rect({rect.x, rect.y + DROPDOWN_MENU_RADIUS}, square, menu_highlight_color)
        }
    }

    gfx.draw_rounded_rect(rect, DROPDOWN_MENU_RADIUS, pill_dark)

    mouse := gfx.mouse_position()
    spaced: f32 = 0 // by the dividers above
    for option, index in options {
        first, last := index == 0, index == len(options) - 1
        divider := dropdown_divider_above(dividers, index)
        if divider do spaced += DROPDOWN_DIVIDER_SPACE

        option_y := rect.y + DROPDOWN_MENU_PAD + f32(index * DROPDOWN_OPTION_HEIGHT) + spaced

        // The first and the last reach over the padding to the menu's edge
        option_rect := gfx.Rect{rect.x, option_y, rect.width, DROPDOWN_OPTION_HEIGHT}
        if first {
            option_rect.y -= DROPDOWN_MENU_PAD
            option_rect.height += DROPDOWN_MENU_PAD
        }
        if last do option_rect.height += DROPDOWN_MENU_PAD

        hover := gfx.point_in_rect(mouse, option_rect)
        if hover && gfx.mouse_pressed() do picked, was_picked = index, true

        if hover do draw_option_highlight(option_rect, first, last)

        label := fit_label(pixel_fonts.label, option.label, rect.width - 2 * DROPDOWN_TEXT_INSET)
        text_color := text_color_hover if hover else text_color_light
        draw_label(pixel_fonts.label, label, {rect.x + DROPDOWN_TEXT_INSET, option_y + DROPDOWN_TEXT_DROP}, text_color, 1)

        // A line in the sheet's colour between the groups
        if divider {
            line_y := option_rect.y - DROPDOWN_DIVIDER_SPACE / 2 - 1
            line_width := rect.width - 2 * DROPDOWN_DIVIDER_INSET
            gfx.draw_rect({rect.x + DROPDOWN_DIVIDER_INSET, line_y}, {line_width, 2}, gfx.hex(sheet_bg_color))
        }
    }
    return
}

// The label in width at the dropdowns' spacing, a long one cut short with "…", e.g. a device's name
fit_label :: proc(font: PixelFont, text: string, width: f32) -> cstring {
    label := fmt.ctprintf("%s", text)
    if measure_label(font, label, 1).x <= width do return label

    // Whole characters off the end until it fits with the ellipsis
    end := len(text)
    for end > 0 {
        _, size := utf8.decode_last_rune_in_string(text[:end])
        end -= size
        label = fmt.ctprintf("%s…", strings.trim_right_space(text[:end]))
        if measure_label(font, label, 1).x <= width do break
    }
    return label
}


// Two columns, Hz and cents, dashes when there's nothing to show. pos is the top middle of the gutter, Hz
// before it and the cents column after it. The values are right aligned in tabular digits, so the decimal
// point stays put and the digits don't shift as they change. The sign of the cents hangs to the left of the
// number.
draw_measurements :: proc(pos: [2]f32, hz, cents: f32, shown: bool, active: bool) {
    color := text_color_white if active else text_color_muted
    value := pixel_fonts.readout

    // The labels stay in the background, the values and the note are what's read
    VALUE_Y :: READOUT_VALUE_Y
    label_font := pixel_fonts.label.font

    // Four digits like a meter's: a tenth up to 999.9, whole hertz from 1000 on. A tenth of a hertz up there is
    // under 0.2 cents.
    hz_str: cstring = "-"
    if shown do hz_str = fmt.ctprintf("%.1f", hz) if hz < 999.95 else fmt.ctprintf("%.0f", hz)

    // A semitone or more off the cents don't fit the column, the gauge shows how many semitones it is
    cents_shown := shown && abs(cents) < 99.95
    cents_str := fmt.ctprintf("%.1f", abs(cents)) if cents_shown else "-"

    // No sign on a rounded zero
    sign: cstring = "-" if cents < 0 else "+"
    signed := cents_shown && cents_str != "0.0"

    hz_right := pos + {-READOUT_GUTTER / 2, 0}

    // The label left aligned after the gutter, the values in a column as wide as the widest
    cents_left := pos + {READOUT_GUTTER / 2, 0}
    gfx.draw_text(label_font, "Cents", snap_to_pixels(cents_left), pixel_fonts.label.size, 1, text_color_muted)
    cents_right := cents_left + {gfx.measure_text(value.font, "00.0", value.size, 0).x, 0}

    draw_text_right(label_font, "Hz", hz_right, pixel_fonts.label.size, 1, text_color_muted)
    draw_text_right(value.font, hz_str, hz_right + {0, VALUE_Y}, value.size, 0, color)
    width := draw_text_right(value.font, cents_str, cents_right + {0, VALUE_Y}, value.size, 0, color)
    if signed do draw_text_right(value.font, sign, cents_right + {-width - 2, VALUE_Y}, value.size, 0, color)
}

// pos is the top right of the text, returns its width
draw_text_right :: proc(font: gfx.Font, text: cstring, pos: [2]f32, size, spacing: f32, color: gfx.Color) -> f32 {
    width := gfx.measure_text(font, text, size, spacing).x
    gfx.draw_text(font, text, snap_to_pixels({pos.x - width, pos.y}), size, spacing, color)
    return width
}
