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

import "core:fmt"
import "core:math"

import "../core"
import "../gfx"

// The readout's cents as a marker over a tape, one of the display types. A meter's needle laid flat: in tune in
// the middle, flat to the left, sharp to the right. The tape is spread out near the note and squeezed further
// out, the last cents to in tune are the widest. Tapped, it shows every track as it is instead, each partial at
// its own cents, the fundamental's the thick one: a string's upper partials stand a few cents sharp of it.

NEEDLE_RANGE_CENTS :: 50 // the tape's ends, further pins the marker there

// How spread out the tape is near in tune, a cent's place goes as log(1 + cents / spread). At 2.5 the 5 cents
// next to in tune are as wide as the 15 after them, and the 30 out to the end a little narrower.
// -define:NEEDLE_SPREAD_CENTS=n to try another.
NEEDLE_SPREAD_CENTS :: f32(#config(NEEDLE_SPREAD_CENTS, 2.5))

// A notch every step out to that many cents, closer notches where the tape is spread out
NeedleNotches :: struct {
    out_to, step: f32,
}
NEEDLE_NOTCHES :: [?]NeedleNotches{{5, 0.5}, {10, 1}, {20, 2}, {NEEDLE_RANGE_CENTS, 5}}

// Labelled and the tallest notches, either side
NEEDLE_LABELS :: [?]f32{0, 5, 10, 20, NEEDLE_RANGE_CENTS}

// The marker's glow, as wide and at its middle as opaque
NEEDLE_GLOW_WIDTH :: #config(NEEDLE_GLOW_WIDTH, 22)
NEEDLE_GLOW_ALPHA :: #config(NEEDLE_GLOW_ALPHA, 150)

// The triangles under the lines pointing up at their notch, the marker's and the partials', the labels under them
MARKER_POINTER_WIDTH :: 10
PARTIAL_POINTER_WIDTH :: 7

// The marker's, the readout's track: NaN without one, and as lit as its stripes, see measure
NeedleDisplay :: struct {
    cents: f32,
    light: f32,
}

// A line on the tape, the marker's or a partial's
NeedleLine :: struct {
    cents:  f32,
    light:  f32,
    marker: bool, // in a glow, the readout's or the fundamental's
}

// The tape across the middle of the view, its notches standing on a line with the labels under it. The needle is
// the colorway's: the marker a sharp line in its lit color in a glow, the partials the same line without one,
// each with a triangle under it pointing up at its notch. The tape is a neutral gray on whole pixels, it stays
// out of the needle's way. With the retro glow only the needle blooms: the glow's offscreen pass softens a point
// wide notch, so the tape goes over it sharp and the needle's lines over the tape again.
draw_needle_display :: proc(
    self: ^NeedleDisplay,
    targets: ^GlowTargets,
    rect: gfx.Rect,
    lock_in: ^core.StrobeLockIn,
    config: ^Config,
) {
    MARGIN :: 32 // either side, the end labels fit

    line_color, background := gfx.hex(strobe_colors(config).x), gfx.hex(strobe_bg_color)

    // The tape's height follows the view's, the line its notches stand on just under the middle
    height := clamp(0.4 * rect.height, 48, 120)
    tape := gfx.Rect{rect.x + MARGIN, rect.y + (rect.height - height) / 2, rect.width - 2 * MARGIN, height}
    partials := config.needle_partials && config.strobe_mode == .HARMONIC
    lines := needle_lines(self, lock_in, partials)

    if config.strobe_glow {
        begin_glow(targets, rect, background)
        draw_needle_glows(tape, lines, line_color)
        draw_needle_lines(tape, lines, line_color)
        end_glow(targets, rect, 1)

        draw_needle_tape(tape)
        draw_needle_lines(tape, lines, line_color)
    } else {
        gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

        gfx.begin_scissor(rect)
        draw_needle_glows(tape, lines, line_color)
        draw_needle_tape(tape)
        draw_needle_lines(tape, lines, line_color)
        gfx.end_scissor()
    }

    draw_needle_labels(tape)
    if partials do draw_needle_partial_labels(tape, lock_in, config.needle_labels, line_color)
}

// The readout's marker, or with the partials every track as it is, each as lit as its stripes: the fundamental's
// the marker, last so it's over the others. A weak fundamental fades out where it is, the marker doesn't move
// over to the partial the readout follows instead. Until the end of the frame.
needle_lines :: proc(self: ^NeedleDisplay, lock_in: ^core.StrobeLockIn, partials: bool) -> []NeedleLine {
    lines := make([dynamic]NeedleLine, context.temp_allocator)
    if !partials {
        if !math.is_nan(self.cents) do append(&lines, NeedleLine{self.cents, self.light, true})
        return lines[:]
    }

    fundamental := -1
    for band, index in lock_in.bands {
        if !shows_partial(lock_in, index) do continue

        if band.interval == 1 {
            fundamental = index
        } else {
            append(&lines, NeedleLine{band.err_cents, track_light(band), false})
        }
    }
    if fundamental >= 0 {
        band := lock_in.bands[fundamental]
        append(&lines, NeedleLine{band.err_cents, track_light(band), true})
    }
    return lines[:]
}

// Where cents go across the tape, its left end to its right
needle_x :: proc(tape: gfx.Rect, cents: f32) -> f32 {
    distance := min(abs(cents), NEEDLE_RANGE_CENTS)
    place := math.ln(1 + distance / NEEDLE_SPREAD_CENTS) / math.ln(1 + NEEDLE_RANGE_CENTS / NEEDLE_SPREAD_CENTS)
    return tape.x + tape.width / 2 * (1 + math.sign(cents) * place)
}

// The marker's glow fading out to its sides, straight at its top and bottom like the line.
// -define:NEEDLE_GLOW_WIDTH=n and NEEDLE_GLOW_ALPHA=n to try others.
draw_needle_glows :: proc(tape: gfx.Rect, lines: []NeedleLine, color: gfx.Color) {
    width := f32(NEEDLE_GLOW_WIDTH)
    for line in lines {
        if !line.marker do continue

        glow := with_alpha(color, NEEDLE_GLOW_ALPHA * line.light)
        gfx.draw_side_fade({needle_x(tape, line.cents) - width / 2, tape.y, width, tape.height}, glow)
    }
}

// The marker's and the partials' sharp lines with their triangles, the partials' a little dimmer
draw_needle_lines :: proc(tape: gfx.Rect, lines: []NeedleLine, color: gfx.Color) {
    for line in lines {
        alpha: u8 = 255 if line.marker else 220
        pointer := f32(MARKER_POINTER_WIDTH if line.marker else PARTIAL_POINTER_WIDTH)
        draw_needle_line(tape, line.cents, line.light, color, alpha, pointer)
    }
}

// The notches and the line they stand on
draw_needle_tape :: proc(tape: gfx.Rect) {
    draw_needle_notches(tape)

    rule := text_color_muted
    rule.a = 160
    draw_crisp_rect({tape.x, tape.y + tape.height - 1}, {tape.width, 2}, rule)
}

// The labelled notches the tallest, the whole cents near in tune taller than the rest, gray like the ruler's
// other notes
draw_needle_notches :: proc(tape: gfx.Rect) {
    baseline := tape.y + tape.height
    labels := NEEDLE_LABELS

    // Each group starts a step past where the one before ended, the first at in tune
    previous: f32 = -1
    for notches in NEEDLE_NOTCHES {
        start := previous + notches.step if previous >= 0 else 0
        for cents := start; cents <= notches.out_to + 0.01; cents += notches.step {
            labelled := false
            for label in labels do labelled ||= abs(cents - label) < 0.01
            whole := abs(cents - math.round(cents)) < 0.01

            height, alpha: f32 = 0.2 * tape.height, 110
            if whole && cents < 5 do height, alpha = 0.35 * tape.height, 170
            if labelled do height, alpha = 0.55 * tape.height, 255

            notch := text_color_muted
            notch.a = u8(alpha)
            for side in ([2]f32{-1, 1}) {
                if cents == 0 && side < 0 do continue

                x := needle_x(tape, side * cents)
                draw_crisp_rect({x - 0.5, baseline - height}, {1, height}, notch)
            }
        }
        previous = notches.out_to
    }
}

// A sharp line from over the tape down to the line the notches stand on, a point wide on whole pixels, and a
// triangle under it pointing up at the notch, faded by light
draw_needle_line :: proc(tape: gfx.Rect, cents, light: f32, color: gfx.Color, alpha: u8, pointer_width: f32) {
    line := with_alpha(color, f32(alpha) * light)
    baseline := tape.y + tape.height
    left, width := crisp_span(needle_x(tape, cents) - 0.5, 1)
    gfx.draw_rect({left, tape.y}, {width, tape.height}, line)

    // Its point on the line's middle, as tall as most of its width
    middle := left + width / 2
    height := 0.8 * pointer_width
    gfx.draw_triangle({middle, baseline}, {middle + pointer_width / 2, baseline + height}, {middle - pointer_width / 2, baseline + height}, line)
}

// From start for size points, both ends on whole pixels, at least one pixel: a thin line stays sharp
crisp_span :: proc(start, size: f32) -> (snapped_start, snapped_size: f32) {
    scale := gfx.dpi_scale()
    snapped_start = math.round(start * scale) / scale
    snapped_size = max(math.round(size * scale), 1) / scale
    return
}

draw_crisp_rect :: proc(position, size: [2]f32, color: gfx.Color) {
    x, width := crisp_span(position.x, size.x)
    y, height := crisp_span(position.y, size.y)
    gfx.draw_rect({x, y}, {width, height}, color)
}

with_alpha :: proc(color: gfx.Color, alpha: f32) -> gfx.Color {
    return {color.r, color.g, color.b, u8(clamp(alpha, 0, 255))}
}

// A track with a reading of its own on the tape: one that fitted since the pluck like the readout's, a track
// that never did reads 0 without having measured anything
shows_partial :: proc(lock_in: ^core.StrobeLockIn, index: int) -> bool {
    band := lock_in.bands[index]
    if !core.measures_band(lock_in, index) || !band.in_range || band.rate_time_s < core.READOUT_SETTLE_S do return false

    return abs(band.err_cents) <= core.READOUT_RANGE_CENTS && track_light(band) > 0
}

// As lit as the track's stripes, see core.STROBE_FADE_SNR_DB
track_light :: proc(band: core.PhaseBand) -> f32 {
    fade := core.STROBE_FADE_SNR_DB
    return math.smoothstep(fade[0], fade[1], band.envelope_snr_db)
}

// The labelled notches' cents under the line they stand on, in the trace's font and the notches' gray
draw_needle_labels :: proc(tape: gfx.Rect) {
    GAP :: 0.8 * MARKER_POINTER_WIDTH + 6
    font := pixel_fonts.band_label
    y := tape.y + tape.height + GAP
    for cents in NEEDLE_LABELS {
        for side in ([2]f32{-1, 1}) {
            if cents == 0 && side < 0 do continue

            text: cstring = "0" if cents == 0 else fmt.ctprintf("%+.0f", side * cents)
            width := measure_label(font, text).x
            draw_label(font, text, snap_to_pixels({needle_x(tape, side * cents) - width / 2, y}), text_color_muted)
        }
    }
}

// Each track's label over its line, its partial, frequency or note like the strobe's, in their color and as lit
// as it. Each in a row of its own so none overlap, the same row however the others come and go: the fundamental's
// right over the tape, the others' up from it in the tracks' order.
draw_needle_partial_labels :: proc(tape: gfx.Rect, lock_in: ^core.StrobeLockIn, type: PartialLabelType, line_color: gfx.Color) {
    GAP :: 6
    ROW_GAP :: 2
    if type == .NONE do return

    row_height := pixel_fonts.band_label.size + ROW_GAP
    others := 0 // the tracks up to this one that aren't the fundamental
    for band, index in lock_in.bands {
        row := 0
        if band.interval != 1 {
            others += 1
            row = others
        }
        if !shows_partial(lock_in, index) do continue

        text, font := partial_label(type, band)
        size := measure_label(font, text)
        bottom := tape.y - GAP - f32(row) * row_height
        color := line_color
        color.a = u8(f32(color.a) * track_light(band))
        draw_label(font, text, snap_to_pixels({needle_x(tape, band.err_cents) - size.x / 2, bottom - size.y}), color)
    }
}
