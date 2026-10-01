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


import "../core"


// an active dropdown menu should not trigger other GUI controls
exclusive_control_mode := false

// The controls being drawn don't take input, e.g. the main screen under the settings sheet
gui_disabled := false

// A control took this frame's press, one that nothing took drags a sheet down
gui_press_taken := false

text_color_dark := hex(0x15141BFF)
text_color_light := hex(0xBDBDBDFF)
text_color_white := hex(0xFBFBFBFF) // the note and readout while there's a pitch, titles
text_color_muted := hex(0x7D7E8FFF) // the note and readout without a pitch, the ruler's neighbours
text_color_disabled := hex(0x5C5D6AFF) // a control that does nothing right now, on a dark pill
icon_color := hex(0x9A9BAAFF)

// Buttons
pill_gray := text_color_muted
pill_mint := hex(0x61FFCAFF)
pill_violet := hex(0xA277FFFF)
pill_yellow := hex(0xFFCA85FF)
pill_dark := hex(0x2D2E35FF)

// A label with an LED to its left that lights up while the toggle is on, like the indicator lamps on
// old hardware. pos is the left edge, vertically centred.
gui_led_toggle :: proc(pos: [2]f32, label: cstring, on: bool, color: Color) -> bool {
    LED_SIZE :: 8
    LABEL_GAP :: 10
    TOUCH_HEIGHT :: 44

    draw_led({pos.x, pos.y - LED_SIZE / 2, LED_SIZE, LED_SIZE}, on, color)

    label_x := pos.x + LED_SIZE + LABEL_GAP
    label_width := measure_label(pixel_fonts.label, label, 1).x
    draw_label(pixel_fonts.label, label, {label_x, pos.y - 7}, text_color_white if on else text_color_light, 1)

    // The whole of the LED and the label, a little past them on each side
    width := label_x + label_width - pos.x
    return gui_button({pos.x - 12, pos.y - TOUCH_HEIGHT / 2, width + 24, TOUCH_HEIGHT})
}

draw_led :: proc(led: Rect, on: bool, color: Color) {
    if on {
        // A thin ring of light, stepped down over a few points
        for ring in ([2][2]f32{{3, 50}, {1.5, 110}}) {
            glow := color
            glow.a = u8(ring[1])
            draw_pill({led.x - ring[0], led.y - ring[0], led.width + 2 * ring[0], led.height + 2 * ring[0]}, glow)
        }
    }
    draw_pill(led, color if on else pill_dark)
}

LOCK_BUTTON_HEIGHT :: 24

// The most important toggle gets a whole button, gray while off and violet while locked. center is the
// middle of the button.
gui_lock_toggle :: proc(center: [2]f32, locked: bool) -> bool {
    LABEL :: "LOCK NOTE"
    PADDING :: 10
    TOUCH_HEIGHT :: 44

    label_size := measure_label(pixel_fonts.label, LABEL, 1)
    width := label_size.x + 2 * PADDING
    rect := Rect{center.x - width / 2, center.y - LOCK_BUTTON_HEIGHT / 2, width, LOCK_BUTTON_HEIGHT}

    draw_pill(rect, pill_violet if locked else pill_gray)
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
draw_strobe_partial :: proc(position: [2]f32, type: PartialLabelType, band: core.PhaseBand) {
    text: cstring
    font := pixel_fonts.label_large

    if type == .FREQUENCY {
        font = pixel_fonts.label
        text = fmt.ctprintf("%.1fHz", band.freq_hz)
    } else if type == .NOTE_NAMES {
        // Inter has no ♯, a plain # reads fine at this size
        text = fmt.ctprintf(
            "%v%v%v",
            band.note.name,
            "#" if band.note.is_accidental else "",
            band.note.octave,
        )
    } else {
        text = fmt.ctprintf("%v×", partial_text(band.interval))
    }

    text_size := measure_label(font, text)
    bounds: Rect = {position.x - text_size.x, position.y, text_size.x, text_size.y}

    draw_label(font, text, {bounds.x, bounds.y}, hex(0x82E2FFFF))

    if band.offset_cents != 0 {
        offset_font := pixel_fonts.label
        offset := fmt.ctprintf("%+.1f¢", band.offset_cents)
        offset_size := measure_label(offset_font, offset)
        center_y := bounds.y + text_size.y / 2
        draw_label(offset_font, offset, {bounds.x - 6 - offset_size.x, center_y - offset_size.y / 2}, hex(0x82E2FFFF))
    }
}


// Without the ruler: the note on its own with arrows either side to step it, the layout leaves room for them
NOTE_ARROW_SLOT :: 32
NOTE_WIDTH :: 112
NOTE_HEIGHT :: 116
NOTE_BASELINE :: 98 // bottom of the letter, from the top of the note
// The octave number ends short of NOTE_WIDTH, the right arrow moves in to be as far from it as the left one
NOTE_RIGHT_ARROW_INSET :: 13

draw_note :: proc(note: core.Note, pos: [2]f32, freq_estimation_active: bool) {
    if note.frequency == 0 do return

    color := text_color_white if freq_estimation_active else text_color_muted

    // Note name
    draw_label(pixel_fonts.note_name, fmt.ctprintf("%v", note.name), pos, color)

    // Sharp sign
    if note.is_accidental {
        draw_label(pixel_fonts.note_name_sharp, "♯", {pos.x + 76, pos.y + 12}, color)
    }

    // Octave number
    draw_label(pixel_fonts.note_octave, fmt.ctprintf("%v", note.octave), {pos.x + 76, pos.y + 72}, color)
}

// A locked note shows arrows either side of it to step by a semitone
gui_note_arrows :: proc(pos: [2]f32, locked: bool) -> (step: int) {
    if !locked do return

    prev := Rect{pos.x - NOTE_ARROW_SLOT, pos.y, NOTE_ARROW_SLOT, NOTE_HEIGHT}
    next := Rect{pos.x + NOTE_WIDTH - NOTE_RIGHT_ARROW_INSET, pos.y, NOTE_ARROW_SLOT, NOTE_HEIGHT}

    font := pixel_fonts.note_arrow
    ARROW_HEIGHT :: 18 // of the triangle itself, it sits in the middle of the line
    for arrow, i in ([2]cstring{"◀", "▶"}) {
        slot := prev if i == 0 else next
        size := measure_text(font.font, arrow, font.size, 0)
        // Sitting on the baseline of the letter
        center_y := slot.y + NOTE_BASELINE - ARROW_HEIGHT / 2
        position := snap_to_pixels({slot.x + (slot.width - size.x) / 2, center_y - size.y / 2})
        draw_text(font.font, arrow, position, font.size, 0, text_color_white)
    }

    // A finger is wider than the slots, the touch areas reach a little past them
    if gui_button({prev.x - 6, prev.y, prev.width + 12, prev.height}) do step = -1
    if gui_button({next.x - 6, next.y, next.width + 12, next.height}) do step = 1

    return
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
RULER_SLIDE_SPEED :: 14 // per second, how quickly the slide closes the distance
RULER_SWIPE_START :: 10 // points sideways before a press on the ruler is a swipe and not a tap
RULER_COAST_MAX :: 20 // notes per second
RULER_COAST_MIN :: 2 // notes per second, let go slower than this it settles on the nearest note
RULER_COAST_FRICTION :: 4 // how far a flick coasts, 1/4 of a second at the finger's speed, in about 1/2 a second

// Where the middle of the ruler is, counted in its notes, it follows the target note a little behind
ruler_position: f32
ruler_initialized: bool

// A press on the ruler. Let go where it was, a tap on a neighbour selects it. Moved sideways it's a swipe,
// the row follows the finger, and let go it coasts on with the finger's speed and slows down. Only the
// note it settles on becomes the target.
RulerSwipe :: struct {
    pressed:  bool,
    swiping:  bool,
    press_x:  f32, // where the finger was when the row started following it
    grab:     f32, // ruler_position then
    last_x:   f32,
    velocity: f32, // points per second, right is positive
    caught:   bool, // pressed while it coasted, let go without swiping it settles where it is
    coast:    f32, // seconds the coast takes, 0 unless coasting
    coasted:  f32, // seconds so far
    from:     f32, // ruler_position when let go
    stop_at:  f32, // the note it coasts to
}

ruler_swipe: RulerSwipe

// notes[target] is the target note, none hides the ruler. Returns how many notes to step when another note is
// tapped or a swipe lands, and while swiping how far the note in the middle is from the target.
gui_note_ruler :: proc(rect: Rect, notes: []core.Note, target: int, active: bool) -> (step: int, browse: int) {
    swipe := &ruler_swipe
    if len(notes) == 0 {
        swipe^ = {}
        return
    }
    highest := f32(len(notes) - 1)

    // The gaps grow with the letters, the fonts were loaded at the layout's size
    scale := pixel_fonts.ruler_scale
    center_gap := scale * RULER_CENTER_GAP

    // As many neighbours as fit, up to 2 a side, the same distance apart in any width
    room := rect.width / 2 - scale * RULER_EDGE - center_gap
    spacing := scale * RULER_SPACING
    per_side := clamp(int(room / spacing), 1, RULER_MAX_PER_SIDE)

    if !ruler_initialized {
        ruler_position = f32(target)
        ruler_initialized = true
    }

    mouse := mouse_position()
    dt := gfx_frame_time()
    tapped := false
    // Where it settles, the nearest note or the next one on the way
    settle := math.round(ruler_position)
    land := false
    if gui_disabled {
        // A sheet opened over it
        land = swipe.swiping || swipe.coast != 0 || swipe.caught
        if !land do swipe^ = {}
    } else if swipe.coast != 0 && mouse_pressed() {
        // Caught on the ruler it stops there and can be swiped on, a press anywhere else settles it
        caught := gui_background_pressed(rect)
        swipe^ = {
            pressed = caught,
            caught  = caught,
            press_x = mouse.x,
            last_x  = mouse.x,
        }
        land = !caught
    } else if swipe.coast != 0 {
        // Slowing down steadily to a stop on the note, from the finger's speed
        swipe.coasted += dt
        left := max(1 - swipe.coasted / swipe.coast, 0)
        ruler_position = swipe.stop_at + (swipe.from - swipe.stop_at) * left * left
        settle = math.round(ruler_position)
        land = left == 0
    } else if !swipe.pressed {
        if gui_background_pressed(rect) {
            swipe^ = {
                pressed = true,
                press_x = mouse.x,
                last_x  = mouse.x,
            }
        }
    } else if mouse_down() {
        // Smoothed, a finger stops for a frame or two before it lets go
        if dt > 0 do swipe.velocity += ((mouse.x - swipe.last_x) / dt - swipe.velocity) * 0.5
        swipe.last_x = mouse.x
        if !swipe.swiping && abs(mouse.x - swipe.press_x) > RULER_SWIPE_START {
            // From here, the few points it took don't make the row jump
            swipe.swiping = true
            swipe.press_x = mouse.x
            swipe.grab = ruler_position
        }
        // The row under the finger, to the left brings in the notes on the right
        if swipe.swiping do ruler_position = swipe.grab + (swipe.press_x - mouse.x) / spacing
        settle = math.round(ruler_position)
    } else if swipe.swiping {
        swipe.pressed = false
        swipe.swiping = false
        swipe.caught = false
        // Where friction would stop it, rounded to a note on the way, and slowing down evenly from the
        // finger's speed it takes twice as long as at that speed
        speed := clamp(-swipe.velocity / spacing, -RULER_COAST_MAX, RULER_COAST_MAX)
        stop := ruler_position + speed / RULER_COAST_FRICTION
        swipe.stop_at = clamp(math.round(stop), 0, highest)
        if speed > 0 do swipe.stop_at = max(swipe.stop_at, math.ceil(ruler_position))
        if speed < 0 do swipe.stop_at = min(swipe.stop_at, math.floor(ruler_position))
        distance := swipe.stop_at - ruler_position
        if abs(speed) < RULER_COAST_MIN || abs(distance) < 0.002 {
            land = true
        } else {
            swipe.coast = 2 * distance / speed
            swipe.coasted = 0
            swipe.from = ruler_position
        }
    } else if swipe.caught {
        land = true
    } else {
        tapped = true
        swipe^ = {}
    }

    // Not past the ends
    if ruler_position <= 0 || ruler_position >= highest {
        ruler_position = clamp(ruler_position, 0, highest)
        settle = math.round(ruler_position)
        if swipe.coast != 0 do land = true
    }

    moving := swipe.swiping || swipe.coast != 0 || swipe.caught
    // Settled, the note becomes the target and the ruler eases onto it from where it is
    if land {
        step = int(settle) - target
        swipe^ = {}
    }
    if moving && !land {
        browse = int(settle) - target
    } else {
        // Slide to the next note, and settle exactly on it, a jump further snaps
        shown := target + step
        if abs(f32(shown) - ruler_position) > 1 && step == 0 do ruler_position = f32(shown)
        ruler_position += (f32(shown) - ruler_position) * min(1, RULER_SLIDE_SPEED * dt)
        if abs(f32(shown) - ruler_position) < 0.002 do ruler_position = f32(shown)
    }

    center := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}

    // The target note is white while there's a pitch, like the note without the ruler
    note_color := text_color_white if active else text_color_muted

    // Notes slide in and out at the ends, fading, the next one out is only drawn while it slides
    first := max(int(math.floor(ruler_position)) - per_side - 1, 0)
    last := min(int(math.ceil(ruler_position)) + per_side + 1, len(notes) - 1)
    for index in first ..= last {
        offset := f32(index) - ruler_position
        distance := abs(offset)
        x := center.x + offset * spacing + math.sign(offset) * center_gap * min(distance, 1)

        ruler_note := notes[index]

        // Large in the middle and small a note away, in between it grows as it comes in and shrinks as it
        // goes, drawn from the large letters scaled down. Settled they're the fonts' own sizes.
        large := 1 - math.smoothstep(f32(0), 1, distance)
        name_font, sharp_font := pixel_fonts.neighbour, pixel_fonts.neighbour_sharp
        if large == 1 {
            name_font, sharp_font = pixel_fonts.note, pixel_fonts.note_sharp
        } else if large > 0 {
            name_font = {pixel_fonts.note.font, math.lerp(pixel_fonts.neighbour.size, pixel_fonts.note.size, large)}
            sharp_font = {pixel_fonts.note_sharp.font, math.lerp(pixel_fonts.neighbour_sharp.size, pixel_fonts.note_sharp.size, large)}
        }
        // The octave fades in on the way to the middle, gone halfway so there's only ever one
        octave := 1 - math.smoothstep(f32(0), 0.5, distance)

        // The sharp and the octave hang off to the right. Centred on the letter the note looks pushed right,
        // centred with them the letter looks pushed left, they're small and thin and weigh less than their
        // width. Halfway looks centred, once it's settled.
        OPTICAL_WEIGHT :: 0.5
        suffix := octave * measure_label(pixel_fonts.octave, fmt.ctprintf("%v", ruler_note.octave)).x
        if ruler_note.is_accidental do suffix = max(suffix, measure_text(sharp_font.font, "♯", sharp_font.size, 0).x)
        x -= large * OPTICAL_WEIGHT * suffix / 2

        // Muted a note away, the ones at the ends fade out
        color: Color
        for channel in 0 ..< 4 {
            color[channel] = u8(math.round(math.lerp(f32(text_color_muted[channel]), f32(note_color[channel]), large)))
        }
        color.a = u8(f32(color.a) * clamp(f32(per_side) + 1 - distance, 0, 1))
        draw_ruler_note(ruler_note, {x, center.y}, name_font, sharp_font, octave, color)

        // Tapping another note locks it
        if tapped && index != target && distance <= f32(per_side) && point_in_rect(mouse, {x - spacing / 2, rect.y, spacing, rect.height}) {
            step = index - target
        }
    }

    return
}

// The name centred on pos, the sharp and the octave (in the middle, octave is how much of it shows) to the
// right, gui_note_ruler moves the note over to centre them all.
// Drawn at the fonts' sizes, their own ones are texel for pixel.
draw_ruler_note :: proc(note: core.Note, pos: [2]f32, name_font, sharp_font: PixelFont, octave: f32, color: Color) {
    size := name_font.size

    name := fmt.ctprintf("%v", note.name)
    name_size := measure_text(name_font.font, name, size, 0)

    // Centred on the letter, the sharp hangs off to the right so the letters are evenly spaced
    top_left := snap_to_pixels(pos - name_size / 2)
    draw_text(name_font.font, name, top_left, size, 0, color)

    right := top_left.x + name_size.x
    if note.is_accidental {
        sharp_pos := snap_to_pixels({right, top_left.y + 0.1 * size})
        draw_text(sharp_font.font, "♯", sharp_pos, sharp_font.size, 0, color)
    }

    if octave > 0 {
        font := pixel_fonts.octave
        octave_color := color
        octave_color.a = u8(f32(color.a) * octave)
        octave_pos := snap_to_pixels({right, top_left.y + name_size.y - 1.3 * font.size})
        draw_text(font.font, fmt.ctprintf("%v", note.octave), octave_pos, font.size, 0, octave_color)
    }
}


// The gauge under the ruler's note: a row of ticks, the middle one red, slides with the pitch like an old
// bathroom scale's dial. The red tick is as far off the note as the pitch, flat on the left like the lower
// notes on the ruler, and the gauge closes in under the note as it's tuned. It glides after the pitch and
// is held where it was while there's no pitch. The ticks fade out towards the ends of the gauge's room.
// The distances are evenly spaced ticks, each a wider range of cents than the one before it, so the last
// few cents to the middle take as many ticks as the rest.
// Up to half a semitone, where the next note takes over on the ruler. A string is tuned up from further
// away, past half a semitone its longer ticks go on a semitone each.
GAUGE_CENTS :: [?]f32{0, 5, 10, 20, 35, 50} // the distances in ticks from the middle outwards
GAUGE_SEMITONE_TICKS :: 3
GAUGE_SPACING :: 13 // between the ticks, it grows with the ruler
GAUGE_TICK :: 12 // tall, the red one and every few are GAUGE_HEIGHT
GAUGE_HEIGHT :: 20
GAUGE_SLIDE_SPEED :: 6 // per second, how quickly it closes the distance, slow enough to ride over the jitter
GAUGE_TOLERANCE :: 0.3 // ticks, it only goes after the pitch once it's moved this far

// Where the red tick is, counted in ticks from under the note, flat is negative
gauge_position: f32
gauge_target: f32 // where it's going, within GAUGE_TOLERANCE of the pitch

// top is the middle of the gauge at its top. Follows the cents from the target while there's a pitch.
draw_cents_gauge :: proc(top: [2]f32, cents: f32, lit: bool, semitones: bool, color: Color) {
    ticks := GAUGE_CENTS
    per_side := len(ticks) - 1 + (GAUGE_SEMITONE_TICKS if semitones else 0)

    // The cents in ticks, between two ticks in proportion, the outermost for anything further. The gauge
    // goes after the pitch once it's moved past the tolerance, and to where it is, it doesn't stop short.
    if lit {
        distance := abs(cents)
        tick := f32(per_side)
        for index in 1 ..= per_side {
            upper := ticks[index] if index < len(ticks) else 100 * f32(index - len(ticks) + 1)
            lower := ticks[index - 1] if index - 1 < len(ticks) else 100 * f32(index - len(ticks))
            if distance <= upper {
                tick = f32(index - 1) + (distance - lower) / (upper - lower)
                break
            }
        }
        pitch := math.sign(cents) * tick
        if abs(pitch - gauge_target) > GAUGE_TOLERANCE do gauge_target = pitch
    }

    gauge_target = clamp(gauge_target, -f32(per_side), f32(per_side))
    gauge_position += (gauge_target - gauge_position) * min(1, GAUGE_SLIDE_SPEED * gfx_frame_time())

    // The ticks either side of the red one, as far as the room reaches from under the note, every few long
    // like a ruler's. Not snapped to the pixels, they glide.
    LONG_EVERY :: 5
    spacing := pixel_fonts.ruler_scale * GAUGE_SPACING
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
        tick_color := color if red && lit else text_color_muted
        tick_color.a = u8(f32(tick_color.a) * fade)
        draw_rect({top.x + along * spacing - width / 2, top.y + (GAUGE_HEIGHT - height) / 2}, {width, height}, tick_color)
    }
}

// Strobe speeds per cent of detuning, fast spins 4× faster for the final adjustment
RESPONSE_SPEEDS :: [2]f32{0.0125, 0.05}

// Slow unless the LED is lit
gui_response_toggle :: proc(pos: [2]f32, speed: f32) -> (f32, bool) {
    speeds := RESPONSE_SPEEDS

    // The config can hold any speed, show the closest step
    step := 0
    for option, i in speeds {
        if abs(math.log2(option / speed)) < abs(math.log2(speeds[step] / speed)) do step = i
    }

    if gui_led_toggle(pos, "FAST", step == 1, pill_mint) {
        return speeds[(step + 1) % len(speeds)], true
    }

    return speed, false
}

gui_button :: proc(bounds: Rect) -> bool {
    if !gui_background_pressed(bounds) do return false
    gui_press_taken = true
    return true
}

// A press on the background, it doesn't take the press like a button so it can still drag the sheet
gui_background_pressed :: proc(bounds: Rect) -> bool {
    return mouse_pressed() && point_in_rect(mouse_position(), bounds) && !exclusive_control_mode && !gui_disabled
}

// Like gui_button, and held down it goes on firing, after a pause and then steadily, like a key repeat.
// Sliding off the button pauses it, sliding back on carries on.
gui_button_repeat :: proc(bounds: Rect) -> bool {
    REPEAT_DELAY :: 400 * time.Millisecond
    REPEAT_INTERVAL :: 80 * time.Millisecond

    if gui_button(bounds) {
        repeat_button = bounds
        repeat_next = time.tick_add(time.tick_now(), REPEAT_DELAY)
        return true
    }
    if repeat_button != bounds || !gui_button_held(bounds) do return false

    now := time.tick_now()
    if time.tick_diff(repeat_next, now) < 0 do return false
    repeat_next = time.tick_add(now, REPEAT_INTERVAL)
    return true
}

repeat_button: Rect
repeat_next: time.Tick

// Whether the button is being held down, to draw it in its pressed shade
gui_button_held :: proc(bounds: Rect) -> bool {
    return mouse_down() && point_in_rect(mouse_position(), bounds) && !exclusive_control_mode && !gui_disabled
}


GuiOption :: struct {
    id:    i32,
    label: string,
}

gui_dropdown :: proc(
    position: [2]f32,
    width: f32,
    options: []GuiOption,
    selected_idx: ^int,
    edit_mode: bool,
    left_pad: f32 = 12,
    height: f32 = 24,
    down := false, // the menu opens under the button, it's drawn after the controls below it
    dividers: []int = nil, // the options with a line above them, each starts a group
) -> bool {
    edit_mode := edit_mode
    btn_bounds := Rect{position.x, position.y, width, height}

    // TODO: make it either a prop or depend on actual width
    max_text_len := 25

    // Draw the button
    draw_pill(btn_bounds, pill_dark)
    draw_icon(ICON_CARET_DOWN, {position.x + width - 22, position.y + (height - 16) / 2}, icon_color)

    if selected_idx != nil {
        label := strings.cut(options[selected_idx^].label, 0, max_text_len)
        draw_label(
            pixel_fonts.label,
            fmt.ctprintf("%s", label),
            {position.x + left_pad, position.y + (height - LABEL_SIZE) / 2},
            text_color_light,
            1,
        )
    }

    // The menu sits 6pt above the button, or below it, the gap counts as part of it for the clicks
    MENU_RADIUS :: 12
    MENU_PAD :: 4 // above the first option and below the last one, part of them and their highlight
    DIVIDER_SPACE :: 8 // between the groups, the line in the middle
    is_divider :: proc(dividers: []int, option, count: int) -> bool {
        return option > 0 && option < count && slice.contains(dividers, option)
    }
    menu_height := f32(len(options) * 24) + 2 * MENU_PAD
    for option in 0 ..< len(options) {
        if is_divider(dividers, option, len(options)) do menu_height += DIVIDER_SPACE
    }
    menu_bounds := Rect{position.x, position.y - menu_height - 6, width, menu_height + 6}
    if down do menu_bounds.y = position.y + height

    mouse_point := mouse_position()

    if mouse_pressed() {
        if edit_mode {
            // An option or clicked outside, either way the menu's
            gui_press_taken = true
            if !point_in_rect(mouse_point, menu_bounds) {
                edit_mode = false
                exclusive_control_mode = false
            }
        } else {
            if !exclusive_control_mode && !gui_disabled && point_in_rect(mouse_point, btn_bounds) {
                edit_mode = true
                exclusive_control_mode = true
                gui_press_taken = true
            }
        }
    }

    // Draw the dropdown menu
    if edit_mode {
        menu_position := [2]f32{menu_bounds.x, menu_bounds.y + (f32(6) if down else 0)}

        draw_rounded_rect({menu_position.x, menu_position.y, width, menu_height}, MENU_RADIUS, pill_dark)
        // debug
        // draw_rect_lines(menu_bounds, 1.0, ORANGE)

        spaced: f32 = 0 // by the dividers above
        for opt, i in options {
            first, last := i == 0, i == len(options) - 1
            divider := is_divider(dividers, i, len(options))
            if divider do spaced += DIVIDER_SPACE
            text_y := menu_position.y + MENU_PAD + f32(i * 24) + spaced + 4

            option_bounds := Rect {
                menu_position.x,
                menu_position.y + MENU_PAD + f32(i * 24) + spaced,
                width,
                24,
            }
            if first {
                option_bounds.y -= MENU_PAD
                option_bounds.height += MENU_PAD
            }
            if last {
                option_bounds.height += MENU_PAD
            }

            hover := false

            if edit_mode && point_in_rect(mouse_point, option_bounds) {
                hover = true
                if mouse_pressed() {
                    edit_mode = false
                    exclusive_control_mode = false
                    selected_idx^ = i
                }
            }

            if hover {
                // The highlight follows the menu's corners on the first and the last option: rounded all
                // around, then the side facing the other options squared off
                highlight := hex(0x15141BFF)
                square := [2]f32{option_bounds.width, option_bounds.height - MENU_RADIUS}

                if first || last {
                    draw_rounded_rect(option_bounds, MENU_RADIUS, highlight)
                }
                if !first {
                    draw_rect({option_bounds.x, option_bounds.y}, square, highlight)
                }
                if !last {
                    draw_rect({option_bounds.x, option_bounds.y + MENU_RADIUS}, square, highlight)
                }
            }

            text_pos := [2]f32{option_bounds.x + 12, text_y}
            label := strings.cut(opt.label, 0, max_text_len)
            draw_label(pixel_fonts.label, fmt.ctprintf("%s", label), text_pos, hex(0xFFFFFFFF) if hover else text_color_light, 1)

            // A line in the sheet's colour, a little in from the edges of the menu
            if divider {
                INSET :: 6
                draw_rect({option_bounds.x + INSET, option_bounds.y - DIVIDER_SPACE / 2 - 1}, {width - 2 * INSET, 2}, hex(sheet_bg_color))
            }
        }
    }

    return edit_mode
}


ReadoutAlign :: enum {
    RIGHT, // the right edges of both columns are fixed, pos is the top right of the cents column
    CENTER, // pos is the top middle of the gutter, Hz right aligned before it and cents left aligned after it
}

// Two columns, Hz and cents. Centred, the sign of the cents hangs into the gutter so the pair looks centred
// whatever the digits.
draw_measurements :: proc(
    pos: [2]f32,
    align: ReadoutAlign,
    steady_pitch: core.PitchInfo, // the strong detections averaged, a raw one each frame is too jumpy to read
    freq_estimation_active: bool,
) {
    hz := steady_pitch.detected_freq
    cents := steady_pitch.err_cents
    show_placeholder := !steady_pitch.measured

    color := text_color_white if freq_estimation_active else text_color_muted
    value := pixel_fonts.readout

    // The labels stay in the background, the values and the note are what's read
    VALUE_Y :: READOUT_VALUE_Y
    label_font := pixel_fonts.label.font
    hz_str := "-" if show_placeholder else fmt.ctprintf("%.1f", hz)
    cents_str := "-" if show_placeholder else fmt.ctprintf("%.1f", math.abs(cents))
    // No sign on a rounded zero
    sign: cstring = "-" if cents < 0 else "+"
    signed := !show_placeholder && cents_str != "0.0"

    switch align {
    case .CENTER:
        hz_right := pos + {-READOUT_GUTTER / 2, 0}
        draw_text_right(label_font, "Hz", hz_right, pixel_fonts.label.size, 1, text_color_muted)
        draw_text_right(value.font, hz_str, hz_right + {0, VALUE_Y}, value.size, 0, color)

        cents_left := pos + {READOUT_GUTTER / 2, 0}
        draw_text(label_font, "Cents", snap_to_pixels(cents_left), pixel_fonts.label.size, 1, text_color_muted)
        draw_text(value.font, cents_str, snap_to_pixels(cents_left + {0, VALUE_Y}), value.size, 0, color)
        if signed do draw_text_right(value.font, sign, cents_left + {-2, VALUE_Y}, value.size, 0, color)
    case .RIGHT:
        hz_right := pos + {-HZ_COLUMN_OFFSET, 0}
        draw_text_right(label_font, "Hz", hz_right, pixel_fonts.label.size, 1, text_color_muted)
        draw_text_right(value.font, hz_str, hz_right + {0, VALUE_Y}, value.size, 0, color)

        draw_text_right(label_font, "Cents", pos, pixel_fonts.label.size, 1, text_color_muted)
        width := draw_text_right(value.font, cents_str, pos + {0, VALUE_Y}, value.size, 0, color)
        // The sign hangs to the left of the number
        if signed do draw_text_right(value.font, sign, pos + {-width - 2, VALUE_Y}, value.size, 0, color)
    }
}

// Between the columns of the centred readout, room for the sign
READOUT_GUTTER :: 40

// From the top of the labels to the top of the values
READOUT_VALUE_Y :: 18

// From the right edge of the cents column to the right edge of the Hz column
HZ_COLUMN_OFFSET :: 100

// pos is the top right of the text, returns its width
draw_text_right :: proc(font: Font, text: cstring, pos: [2]f32, size, spacing: f32, color: Color) -> f32 {
    width := measure_text(font, text, size, spacing).x
    draw_text(font, text, snap_to_pixels({pos.x - width, pos.y}), size, spacing, color)
    return width
}
