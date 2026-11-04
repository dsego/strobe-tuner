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

// The DEBUG_STATS build's view of the harmonic stack, see core.HarmonicStack: its latest spectrum, and a
// spectrogram of how far each frequency stood over its background, a column a detection, the newest on the
// right. The pitch the tuner detected is marked on it, the stack's harmonics as dots, the note named where a lit
// note changes. Whichever way the pitch detection goes, the stack runs for it, see core.PitchDetector.stack_shown.

DEBUG_SPECTROGRAM_COLUMNS :: 330 // a detection each, 5.5 s at 60 a second
DEBUG_SPECTROGRAM_ROWS :: 170 // from SPECTRUM_LOW_HZ to the detector's low-pass on a log scale
DEBUG_SPECTROGRAM_RANGE_DB :: 40 // over the background, the brightest grey at this and over

// The brightest grey, the marks over it are lighter: on white a hum's ridge hid the pitch's line whatever its colour
DEBUG_SPECTROGRAM_BRIGHTEST :: 140

DebugSpectrogram :: struct {
    prominence: [DEBUG_SPECTROGRAM_COLUMNS][DEBUG_SPECTROGRAM_ROWS]u8, // each row's dB over the background
    marks:      [DEBUG_SPECTROGRAM_COLUMNS]DebugMark,
    next:       int, // the column the next detection goes in, over the oldest
    texture:    gfx.Texture, // the frame before's, released once it's drawn
    pixels:     [DEBUG_SPECTROGRAM_ROWS * DEBUG_SPECTROGRAM_COLUMNS * 4]u8,
    labels:     [dynamic]DebugLabel, // oldest first, see record_debug_column
    recorded:   int, // the columns so far
    unnamed:    int, // columns since the last name
}

// What a detection made of it
DebugMark :: struct {
    freq:      f32, // the detected pitch, 0 for none
    lit:       bool, // the tuner had a note
    harmonics: [core.HARMONICS_COUNT]f32, // each of the stack's harmonics' peak, 0 for none or under HARMONICS_LOW_DB
}

// A note's name printed on the spectrogram, it scrolls away with the column it was printed at
DebugLabel :: struct {
    note:   core.Note,
    column: int, // counted from the first
}

// A note's name this many columns after the one before at least, side by side they ran into each other. As wide as
// a name at most, a name scrolls this far under the left edge before it's dropped.
DEBUG_LABEL_GAP_COLUMNS :: 20

debug_spectrogram: DebugSpectrogram

destroy_debug_spectrogram :: proc(self: ^DebugSpectrogram) {
    gfx.unload_texture(self.texture)
    delete(self.labels)
}

// A column of the stack's latest detection, each row the most a bin under it stood over the background. Its
// harmonics only when the stack heard a pitch, down in the noise they were everywhere.
record_debug_column :: proc(
    self: ^DebugSpectrogram,
    stack: ^core.HarmonicStack,
    pitch: core.PitchInfo,
    lit: bool,
    shown: core.Note,
    sample_rate: f32,
) {
    if stack.short.top_bin <= 1 do return

    low, high := f32(SPECTRUM_LOW_HZ), core.pitch_lowpass_hz(sample_rate)
    for &value, row in self.prominence[self.next] {
        from := low * math.pow(high / low, f32(row) / DEBUG_SPECTROGRAM_ROWS)
        to := low * math.pow(high / low, f32(row + 1) / DEBUG_SPECTROGRAM_ROWS)
        level, background := stack_level_between(stack, from, to)
        value = u8(DEBUG_SPECTROGRAM_BRIGHTEST * clamp((level - background) / DEBUG_SPECTROGRAM_RANGE_DB, 0, 1))
    }

    mark := DebugMark{freq = pitch.detected_freq, lit = lit}
    if stack.score_db >= core.HARMONICS_LOW_DB {
        for peak, index in stack.harmonics do mark.harmonics[index] = peak.freq
    }
    self.marks[self.next] = mark

    print_debug_label(self, lit, shown)
    self.next = (self.next + 1) % DEBUG_SPECTROGRAM_COLUMNS
    self.recorded += 1
}

// The shown note's name at this column where the lit note changes, decided once as the column comes in. Worked out
// again every frame, a name stuck to the left edge once its column had scrolled off. The names past the left edge
// by more than a name's width are dropped.
print_debug_label :: proc(self: ^DebugSpectrogram, lit: bool, shown: core.Note) {
    self.unnamed += 1
    changed := len(self.labels) == 0 || self.labels[len(self.labels) - 1].note.cents != shown.cents
    if lit && changed && self.unnamed >= DEBUG_LABEL_GAP_COLUMNS {
        append(&self.labels, DebugLabel{shown, self.recorded})
        self.unnamed = 0
    }

    oldest := self.recorded - DEBUG_SPECTROGRAM_COLUMNS - DEBUG_LABEL_GAP_COLUMNS
    for len(self.labels) > 0 && self.labels[0].column < oldest do ordered_remove(&self.labels, 0)
}

// The columns oldest to newest across rect, low notes at the bottom and a C every octave. Over them the detected
// pitch outlined in black, green while the tuner has a note and grey without, the stack's harmonics pink, and the
// note the tuner showed named where it changed, see print_debug_label.
draw_debug_spectrogram :: proc(self: ^DebugSpectrogram, rect: gfx.Rect, sample_rate, pitch_standard: f32, font: gfx.Font) {
    low, high := f32(SPECTRUM_LOW_HZ), core.pitch_lowpass_hz(sample_rate)
    y_at :: proc(freq, low, high: f32, rect: gfx.Rect) -> f32 {
        return rect.y + rect.height * (1 - math.ln(freq / low) / math.ln(high / low))
    }

    draw_spectrogram_image(self, rect)
    draw_spectrogram_octaves(rect, low, high, pitch_standard, font)

    // The outline first, all of it, a column's would cut into the line of the one before
    column_width := rect.width / DEBUG_SPECTROGRAM_COLUMNS
    for column in 0 ..< DEBUG_SPECTROGRAM_COLUMNS {
        mark := self.marks[(self.next + column) % DEBUG_SPECTROGRAM_COLUMNS]
        if mark.freq < low || mark.freq > high do continue

        x := rect.x + (f32(column) + 0.5) * column_width
        y := y_at(mark.freq, low, high, rect)
        gfx.draw_rect({x - 2, y - 2.5}, {column_width + 3, 5}, gfx.BLACK)
    }

    for column in 0 ..< DEBUG_SPECTROGRAM_COLUMNS {
        mark := self.marks[(self.next + column) % DEBUG_SPECTROGRAM_COLUMNS]
        x := rect.x + (f32(column) + 0.5) * column_width

        for freq in mark.harmonics {
            if freq < low || freq > high do continue
            gfx.draw_rect({x - 1, y_at(freq, low, high, rect) - 1}, {2, 2}, gfx.PINK)
        }

        if mark.freq >= low && mark.freq <= high {
            y := y_at(mark.freq, low, high, rect)
            gfx.draw_rect({x - 1, y - 1.5}, {column_width + 1, 3}, gfx.GREEN if mark.lit else gfx.LIGHTGRAY)
        }
    }

    // The names clipped at the edges, they scroll under the left one
    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    oldest := self.recorded - DEBUG_SPECTROGRAM_COLUMNS
    for label in self.labels {
        note := label.note
        if note.frequency < low || note.frequency > high do continue

        x := rect.x + (f32(label.column - oldest) + 0.5) * column_width
        y := y_at(note.frequency, low, high, rect)
        gfx.draw_text(font, fmt.ctprintf("%s", core.note_name(note)), {x + 2, y - 16}, 12, 0, gfx.GREEN)
    }
}

// The prominences as grey levels, a texture made again every frame and the frame before's released, it was drawn
// and is done with
draw_spectrogram_image :: proc(self: ^DebugSpectrogram, rect: gfx.Rect) {
    gfx.unload_texture(self.texture)

    for column in 0 ..< DEBUG_SPECTROGRAM_COLUMNS {
        oldest_first := (self.next + column) % DEBUG_SPECTROGRAM_COLUMNS
        for value, row in self.prominence[oldest_first] {
            // Low notes at the bottom
            pixel := 4 * ((DEBUG_SPECTROGRAM_ROWS - 1 - row) * DEBUG_SPECTROGRAM_COLUMNS + column)
            self.pixels[pixel], self.pixels[pixel + 1], self.pixels[pixel + 2], self.pixels[pixel + 3] = value, value, value, 255
        }
    }

    self.texture = gfx.create_texture(DEBUG_SPECTROGRAM_COLUMNS, DEBUG_SPECTROGRAM_ROWS, self.pixels[:])
    gfx.draw_texture(self.texture, {0, 0, DEBUG_SPECTROGRAM_COLUMNS, DEBUG_SPECTROGRAM_ROWS}, rect)
}

// A line across at each C, named on the left
draw_spectrogram_octaves :: proc(rect: gfx.Rect, low, high, pitch_standard: f32, font: gfx.Font) {
    line := gfx.LIGHTGRAY
    line.a = 60
    for octave in 1 ..= 8 {
        c_hz := core.freq_at_cents(pitch_standard, f32((octave - 4) * 1200 - 900))
        if c_hz < low || c_hz > high do continue

        y := rect.y + rect.height * (1 - math.ln(c_hz / low) / math.ln(high / low))
        gfx.draw_rect({rect.x, y}, {rect.width, 1}, line)
        gfx.draw_text(font, fmt.ctprintf("C%d", octave), {rect.x - 24, y - 6}, 12, 0, gfx.LIGHTGRAY)
    }
}

// The stack's latest spectrum across rect on the spectrogram's log scale: each bin's level in dB, the background
// under it grey, the peaks it kept grey dots, the note's harmonics gold and numbered, and over the plot the
// note, its Hz and the stack's score
// The stack's level and background from from_hz to to_hz, a pixel's or a row's, in the transform it looks there
// in, see core.stack_transform_at: the loudest bin among them, or between the bins either side where they're
// narrower than a bin. The bin under them repeated drew a low note's as blocks several pixels wide.
stack_level_between :: proc(stack: ^core.HarmonicStack, from_hz, to_hz: f32) -> (level, background: f32) {
    transform := core.stack_transform_at(stack, from_hz)
    from := from_hz / transform.bin_hz
    to := min(to_hz / transform.bin_hz, f32(transform.top_bin))

    first, last := max(int(math.ceil(from)), 1), int(to)
    if last >= first {
        level = transform.levels[first]
        for bin in first + 1 ..= last do level = max(level, transform.levels[bin])
        return level, transform.background[first]
    }

    middle := (from + to) / 2
    below := clamp(int(middle), 1, transform.top_bin - 1)
    between := middle - f32(below)
    level = math.lerp(transform.levels[below], transform.levels[below + 1], between)
    background = math.lerp(transform.background[below], transform.background[below + 1], between)
    return
}

draw_stack_plot :: proc(rect: gfx.Rect, stack: ^core.HarmonicStack, pitch: core.PitchInfo, sample_rate: f32, font: gfx.Font) {
    RANGE_DB :: 60 // from the loudest down, the background stays in it

    if stack.short.top_bin <= 1 do return

    // Each pixel's, see stack_level_between
    low, high := f32(SPECTRUM_LOW_HZ), core.pitch_lowpass_hz(sample_rate)
    levels_db := make([]f32, int(rect.width), context.temp_allocator)
    backgrounds_db := make([]f32, int(rect.width), context.temp_allocator)
    loudest := min(f32)
    for x in 0 ..< len(levels_db) {
        from := low * math.pow(high / low, f32(x) / rect.width)
        to := low * math.pow(high / low, f32(x + 1) / rect.width)
        levels_db[x], backgrounds_db[x] = stack_level_between(stack, from, to)
        loudest = max(loudest, levels_db[x])
    }

    x_at :: proc(freq, low, high: f32, rect: gfx.Rect) -> f32 {
        return rect.x + rect.width * math.ln(freq / low) / math.ln(high / low)
    }
    y_at :: proc(db, loudest: f32, rect: gfx.Rect) -> f32 {
        return rect.y + rect.height * clamp((loudest - db) / RANGE_DB, 0, 1)
    }

    gfx.draw_rect({rect.x, rect.y + rect.height}, {rect.width, 1}, gfx.LIGHTGRAY)

    // A point a pixel across
    levels := make([][2]f32, len(levels_db), context.temp_allocator)
    backgrounds := make([][2]f32, len(levels_db), context.temp_allocator)
    for x in 0 ..< len(levels_db) {
        levels[x] = {rect.x + f32(x), y_at(levels_db[x], loudest, rect)}
        backgrounds[x] = {rect.x + f32(x), y_at(backgrounds_db[x], loudest, rect)}
    }
    gfx.draw_polyline(backgrounds, 1, gfx.LIGHTGRAY)
    gfx.draw_polyline(levels, 1, gfx.WHITE)

    // Each transform's where it's drawn
    for transform in ([2]^core.StackTransform{&stack.bass, &stack.short}) {
        for peak in transform.peaks {
            if core.stack_transform_at(stack, peak.freq) != transform do continue

            gfx.draw_circle({x_at(peak.freq, low, high, rect), y_at(peak.level, loudest, rect)}, 2, gfx.LIGHTGRAY)
        }
    }

    for peak, index in stack.harmonics {
        if peak.freq < low || peak.freq > high do continue

        position := [2]f32{x_at(peak.freq, low, high, rect), y_at(peak.level, loudest, rect)}
        gfx.draw_circle(position, 3, gfx.GOLD)
        gfx.draw_text(font, fmt.ctprintf("%d", index + 1), position - {3, 18}, 12, 0, gfx.GOLD)
    }

    if pitch.detected_freq > 0 {
        text := fmt.ctprintf("%s %.1fHz, stack %.0f dB", core.note_name(pitch.detected_note), pitch.detected_freq, pitch.harmonics_db)
        gfx.draw_text(font, text, {rect.x, rect.y - 18}, 12, 0, gfx.GOLD)
    }
}
