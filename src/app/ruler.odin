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
import "../gfx"


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
