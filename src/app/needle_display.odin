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
// out, the last cents to in tune are the widest. It shows every track as it is, each partial at its own cents,
// the fundamental's the marker: a string's upper partials stand a few cents sharp of it. Tapped, only the
// readout's marker stays.

NEEDLE_RANGE_CENTS :: 50 // the tape's ends, further pins the marker there

// How spread out the tape is near in tune, a cent's place goes as log(1 + cents / spread). At 2.5 the 5 cents
// next to in tune are as wide as the 15 after them, and the 30 out to the end a little narrower.
// -define:NEEDLE_SPREAD_CENTS=n to try another.
NEEDLE_SPREAD_CENTS :: f32(#config(NEEDLE_SPREAD_CENTS, 2.5))

// The notches either side, every half cent out to 2, every cent to 5 and past it only the labelled ones. The
// half cents only mark halfway where the tape is widest, half a cent is inside the In-tune tap and less than a
// plucked string drifts, the readout's tenths show it. Past 5 the needle says which way and about how far,
// every 2 and 5 cents there squeezed into a comb.
NEEDLE_NOTCHES :: [?]f32{0, 0.5, 1, 1.5, 2, 3, 4, 5, 10, 20, NEEDLE_RANGE_CENTS}

// Labelled and the long notches, either side. Each about as far from the next on the tape, a 1 crowded the 0.
NEEDLE_LABELS :: [?]f32{0, 2, 5, 10, 20, NEEDLE_RANGE_CENTS}

// The short and the long notches as tall, of the tape's height, and the needle's lines and the long notches as
// wide in points, the short notches a point. Two heights only, a third for the whole cents near in tune read as
// another kind of mark, the long ones stand out by their width too. A needle on a long notch covers it.
// -define:NEEDLE_NOTCH_HEIGHT=n, NEEDLE_LONG_NOTCH_HEIGHT=n and NEEDLE_LINE_WIDTH=n to try others.
NEEDLE_NOTCH_HEIGHT :: f32(#config(NEEDLE_NOTCH_HEIGHT, 0.12))
NEEDLE_LONG_NOTCH_HEIGHT :: f32(#config(NEEDLE_LONG_NOTCH_HEIGHT, 0.21))
NEEDLE_LINE_WIDTH :: f32(#config(NEEDLE_LINE_WIDTH, 1.5))

// The marker's glow, as wide and at its middle as opaque
NEEDLE_GLOW_WIDTH :: #config(NEEDLE_GLOW_WIDTH, 22)
NEEDLE_GLOW_ALPHA :: #config(NEEDLE_GLOW_ALPHA, 150)
// The triangles under and over the lines pointing at their notches, the marker's and the partials', the labels
// past them
MARKER_POINTER_WIDTH :: 12
PARTIAL_POINTER_WIDTH :: 9

// How lit a line stays once its stripes are gone, at the last reading they showed, like the readout's gray
// number. Until the track reads again after a pluck, another note clears it.
NEEDLE_HELD_LIGHT :: 0.3

NeedleDisplay :: struct {
    // The readout's track: NaN without one, and as lit as its stripes, see measure
    cents:  f32,
    light:  f32,

    // The last readings shown, the readout's and each track's, see needle_lines
    marker: HeldNeedle,
    tracks: [core.MAX_BANDS]HeldNeedle,
}

HeldNeedle :: struct {
    cents:   f32,
    freq_hz: f32, // the strobe's or the track's then, another note's tracks start over
    shown:   bool,
}

// A line on the tape, the marker's or a partial's
NeedleLine :: struct {
    cents:  f32,
    light:  f32,
    marker: bool, // in a glow, the readout's or the fundamental's
    track:  int, // its label's, -1 for the readout's marker
}

// The tape across the middle of the view, its notches standing on a line with the labels under it and mirrored
// hanging from a line over it. The needle is the colorway's: the marker a sharp line in its lit color in a glow,
// the partials the same line without one, each with a triangle under and over it pointing at its notches. The
// tape is a neutral gray on whole pixels, it stays
// out of the needle's way. Sharp with the retro glow too, it's the strobe's lamp and the scope's phosphor: a
// bloom softened the point wide notches, and a lamp behind the tape didn't look like anything.
draw_needle_display :: proc(self: ^NeedleDisplay, rect: gfx.Rect, lock_in: ^core.StrobeLockIn, config: ^Config) {
    MARGIN :: 32 // either side, the end labels fit

    line_color, background := gfx.hex(strobe_colors(config).x), gfx.hex(strobe_bg_color)

    // The tape's height follows the view's, the line its notches stand on just under the middle
    height := clamp(0.4 * rect.height, 48, 120)
    tape := gfx.Rect{rect.x + MARGIN, rect.y + (rect.height - height) / 2, rect.width - 2 * MARGIN, height}
    partials := config.needle_partials && config.strobe_mode == .HARMONIC
    lines := needle_lines(self, lock_in, partials)

    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

    gfx.begin_scissor(rect)
    draw_needle_glows(tape, lines, line_color)
    draw_needle_tape(tape)
    draw_needle_lines(tape, lines, line_color)
    gfx.end_scissor()

    draw_needle_labels(tape)
    if partials do draw_needle_partial_labels(tape, lock_in, lines, config.needle_labels)
}

// The readout's marker, or with the partials every track as it is, each as lit as its stripes: the fundamental's
// the marker, last so it's over the others. A weak fundamental fades out where it is, the marker doesn't move
// over to the partial the readout follows instead. Faded, each stays at NEEDLE_HELD_LIGHT where it last read.
// Until the end of the frame.
needle_lines :: proc(self: ^NeedleDisplay, lock_in: ^core.StrobeLockIn, partials: bool) -> []NeedleLine {
    lines := make([dynamic]NeedleLine, context.temp_allocator)
    if !partials {
        marker := &self.marker
        if !math.is_nan(self.cents) {
            marker^ = {self.cents, lock_in.base_freq_hz, true}
            append(&lines, NeedleLine{self.cents, max(self.light, NEEDLE_HELD_LIGHT), true, -1})
        } else if marker.shown && marker.freq_hz == lock_in.base_freq_hz {
            append(&lines, NeedleLine{marker.cents, NEEDLE_HELD_LIGHT, true, -1})
        } else {
            marker^ = {}
        }
        return lines[:]
    }

    fundamental: Maybe(NeedleLine)
    for band, index in lock_in.bands {
        line, shown := track_needle_line(&self.tracks[index], lock_in, index)
        if !shown do continue

        if band.interval == 1 {
            fundamental = line
        } else {
            append(&lines, line)
        }
    }
    if line, shown := fundamental.?; shown do append(&lines, line)
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

// The notches and the lines they stand on and hang from
draw_needle_tape :: proc(tape: gfx.Rect) {
    draw_needle_notches(tape)

    draw_crisp_rect({tape.x, tape.y - 1}, {tape.width, 2}, text_color_muted)
    draw_crisp_rect({tape.x, tape.y + tape.height - 1}, {tape.width, 2}, text_color_muted)
}

// The labelled notches long and the rest short, up from the bottom line and down from the top one, all in the
// gray of the ruler's other notes
draw_needle_notches :: proc(tape: gfx.Rect) {
    baseline := tape.y + tape.height
    labels := NEEDLE_LABELS
    for cents in NEEDLE_NOTCHES {
        labelled := false
        for label in labels do labelled ||= cents == label

        height := (NEEDLE_LONG_NOTCH_HEIGHT if labelled else NEEDLE_NOTCH_HEIGHT) * tape.height
        width := NEEDLE_LINE_WIDTH if labelled else 1
        for side in ([2]f32{-1, 1}) {
            if cents == 0 && side < 0 do continue

            left := needle_x(tape, side * cents) - width / 2
            draw_crisp_rect({left, baseline - height}, {width, height}, text_color_muted)
            draw_crisp_rect({left, tape.y}, {width, height}, text_color_muted)
        }
    }
}

// A sharp line from the top line of the tape down to the bottom one, as wide as a long notch on whole pixels, and
// a triangle under and over it pointing at the notches, faded by light
draw_needle_line :: proc(tape: gfx.Rect, cents, light: f32, color: gfx.Color, alpha: u8, pointer_width: f32) {
    line := with_alpha(color, f32(alpha) * light)
    baseline := tape.y + tape.height
    left, width := crisp_span(needle_x(tape, cents) - NEEDLE_LINE_WIDTH / 2, NEEDLE_LINE_WIDTH)
    gfx.draw_rect({left, tape.y}, {width, tape.height}, line)

    // Their points on the line's ends, as tall as most of their width
    middle := left + width / 2
    height := 0.8 * pointer_width
    gfx.draw_triangle({middle, baseline}, {middle + pointer_width / 2, baseline + height}, {middle - pointer_width / 2, baseline + height}, line)
    gfx.draw_triangle({middle, tape.y}, {middle - pointer_width / 2, tape.y - height}, {middle + pointer_width / 2, tape.y - height}, line)
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

// The track's line as it reads, or where it last read while it starts over after a pluck, held as the track's
// last reading. Gone on another note.
track_needle_line :: proc(held: ^HeldNeedle, lock_in: ^core.StrobeLockIn, index: int) -> (line: NeedleLine, shown: bool) {
    band := lock_in.bands[index]
    fundamental := band.interval == 1
    if reads_partial(lock_in, index) {
        held^ = {band.err_cents, band.freq_hz, true}
        return {band.err_cents, max(track_light(band), NEEDLE_HELD_LIGHT), fundamental, index}, true
    }
    if held.shown && held.freq_hz == band.freq_hz && core.measures_band(lock_in, index) {
        return {held.cents, NEEDLE_HELD_LIGHT, fundamental, index}, true
    }

    held^ = {}
    return
}

// A track with a reading of its own: one that fitted since the pluck like the readout's, a track that never did
// reads 0 without having measured anything. A dark track's cents stay where its stripes last fully showed.
reads_partial :: proc(lock_in: ^core.StrobeLockIn, index: int) -> bool {
    band := lock_in.bands[index]
    if !core.measures_band(lock_in, index) || !band.in_range || band.rate_time_s < core.READOUT_SETTLE_S do return false

    return abs(band.err_cents) <= core.READOUT_RANGE_CENTS
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

// Each line's label over it, its partial, frequency or note in the cyan of the strobe's track labels, as lit as
// the line. Each in a row of its own so none overlap, the same row however the others come and go: the
// fundamental's right over the triangles on the tape, the others' up from it in the tracks' order.
draw_needle_partial_labels :: proc(tape: gfx.Rect, lock_in: ^core.StrobeLockIn, lines: []NeedleLine, type: PartialLabelType) {
    GAP :: 0.8 * MARKER_POINTER_WIDTH + 6
    ROW_GAP :: 2
    if type == .NONE do return

    // The tracks up to each one that aren't the fundamental
    rows: [core.MAX_BANDS]int
    others := 0
    for band, index in lock_in.bands {
        if band.interval == 1 do continue

        others += 1
        rows[index] = others
    }

    row_height := pixel_fonts.band_label.size + ROW_GAP
    for line in lines {
        if line.track < 0 do continue

        text, font := partial_label(type, lock_in.bands[line.track])
        size := measure_label(font, text)
        bottom := tape.y - GAP - f32(rows[line.track]) * row_height
        color := with_alpha(accent_color, f32(accent_color.a) * line.light)
        draw_label(font, text, snap_to_pixels({needle_x(tape, line.cents) - size.x / 2, bottom - size.y}), color)
    }
}
