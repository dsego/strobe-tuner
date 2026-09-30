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

import "core:math"

// The cents over the last few seconds as a line, one of the display types.
// Shows what the strobe can't: the pluck going sharp and settling, vibrato, a held note drifting.

TRACE_SECONDS :: 5
TRACE_CAPACITY :: 256 // readings, they come about 20 times a second
TRACE_RANGE :: 25 // cents from the middle to the top and bottom, further is clamped to the edge
TRACE_BAND :: 5 // cents either side of in tune, marked with faint lines
TRACE_CURVE_STEPS :: 8 // pieces of the curve between two readings

// Only the actual readings with their time, the curve through them is worked out when drawing
TraceSample :: struct {
    time:  f32, // seconds on the trace's clock
    cents: f32, // NaN marks where the pitch was lost, the line has a gap there
}

Trace :: struct {
    samples: []TraceSample,
    head:    int, // where the next one goes
    count:   int,
    clock:   f32,
}

create_trace :: proc() -> (self: Trace) {
    self.samples = make([]TraceSample, TRACE_CAPACITY)
    return self
}

destroy_trace :: proc(self: ^Trace) {
    delete(self.samples)
}

trace_sample :: proc(self: ^Trace, i: int) -> TraceSample {
    capacity := len(self.samples)
    return self.samples[(self.head - self.count + i + capacity) % capacity]
}

push_sample :: proc(self: ^Trace, sample: TraceSample) {
    self.samples[self.head] = sample
    self.head = (self.head + 1) % len(self.samples)
    self.count = min(self.count + 1, len(self.samples))
}

// Called every frame, fresh tells a new reading from the previous one repeated
record_trace :: proc(self: ^Trace, cents: f32, fresh: bool, frame_time: f32) {
    self.clock += frame_time

    lost := self.count > 0 && math.is_nan(trace_sample(self, self.count - 1).cents)
    if math.is_nan(cents) {
        // One marker where the pitch goes, not one every frame
        if self.count > 0 && !lost do push_sample(self, {self.clock, cents})
    } else if fresh || lost || self.count == 0 {
        push_sample(self, {self.clock, cents})
    }
}

// Oldest on the left, the latest point on the right edge, sharp is up
// The line in the colorway's lit color, the in tune band in its second color
draw_cents_trace :: proc(self: ^Trace, rect: Rect, line_color, band_color, background: Color) {
    draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

    PADDING :: 28
    plot := Rect{rect.x, rect.y + PADDING, rect.width, rect.height - 2 * PADDING}
    middle := plot.y + plot.height / 2

    // The in tune band and a line through the middle of it
    band := band_color
    band.a = 110
    // ±TRACE_BAND of the ±TRACE_RANGE the plot covers, f32 as the constants would divide as integers
    band_height := f32(TRACE_BAND) / TRACE_RANGE * plot.height
    draw_rect({plot.x, middle - band_height / 2}, {plot.width, band_height}, band)
    center_line := line_color
    center_line.a = 120
    draw_rect({plot.x, middle - 1}, {plot.width, 2}, center_line)

    draw_label(pixel_fonts.label_large, "+25", {plot.x + 10, plot.y - 8}, text_color_muted, 1)
    draw_label(pixel_fonts.label_large, "-25", {plot.x + 10, plot.y + plot.height - 12}, text_color_muted, 1)

    // Like a lit pen: a soft see-through glow under the line. Both are stamped as anti-aliased dots evenly
    // spaced along the whole line, so the edges and joins are smooth and the glow builds up the same
    // everywhere (4 dots overlap at any point).
    GLOW_RADIUS :: 4.5
    LINE_RADIUS :: 1.25
    glow := line_color
    glow.a = 16

    // Placed by time, the newest reading is at the right edge now and scrolls left
    point :: proc(sample: TraceSample, clock: f32, plot: Rect, middle: f32) -> [2]f32 {
        x := plot.x + plot.width - (clock - sample.time) / TRACE_SECONDS * plot.width
        return {x, middle - clamp(sample.cents / TRACE_RANGE, -1, 1) * plot.height / 2}
    }
    usable :: proc(self: ^Trace, i: int) -> bool {
        return i >= 0 && i < self.count && !math.is_nan(trace_sample(self, i).cents)
    }

    begin_scissor(rect)
    defer end_scissor()

    for pass in 0 ..< 2 {
        pen := Pen {
            radius = GLOW_RADIUS if pass == 0 else LINE_RADIUS,
            color  = glow if pass == 0 else line_color,
        }

        for i in 0 ..< self.count {
            if !usable(self, i) do continue
            p1 := point(trace_sample(self, i), self.clock, plot, middle)
            if !usable(self, i - 1) do pen_start(&pen, p1) // the start of a run
            if !usable(self, i + 1) do continue
            p2 := point(trace_sample(self, i + 1), self.clock, plot, middle)

            // A curve through the readings (Catmull-Rom), the neighbours on either side set its direction
            p0 := point(trace_sample(self, i - 1), self.clock, plot, middle) if usable(self, i - 1) else p1
            p3 := point(trace_sample(self, i + 2), self.clock, plot, middle) if usable(self, i + 2) else p2
            for step in 1 ..= TRACE_CURVE_STEPS {
                progress := f32(step) / TRACE_CURVE_STEPS
                bend := 2 * p0 - 5 * p1 + 4 * p2 - p3
                twist := 3 * p1 - p0 - 3 * p2 + p3
                on_curve := 0.5 * (2 * p1 + (p2 - p0) * progress + bend * progress * progress + twist * progress * progress * progress)
                pen_line_to(&pen, on_curve)
            }
        }
    }
}

draw_dot :: proc(center: [2]f32, radius: f32, color: Color) {
    draw_rounded_rect({center.x - radius, center.y - radius, 2 * radius, 2 * radius}, radius, color)
}

// Draws a line as dots half a radius apart, the spacing carries over from one piece of the line to the next
Pen :: struct {
    radius:     f32,
    color:      Color,
    position:   [2]f32,
    until_next: f32, // distance left to the next dot
}

pen_start :: proc(pen: ^Pen, position: [2]f32) {
    draw_dot(position, pen.radius, pen.color)
    pen.position = position
    pen.until_next = 0.5 * pen.radius
}

pen_line_to :: proc(pen: ^Pen, to: [2]f32) {
    delta := to - pen.position
    length := math.sqrt(delta.x * delta.x + delta.y * delta.y)
    travelled: f32 = 0
    for travelled + pen.until_next <= length {
        travelled += pen.until_next
        draw_dot(pen.position + delta * (travelled / length), pen.radius, pen.color)
        pen.until_next = 0.5 * pen.radius
    }
    pen.until_next -= length - travelled
    pen.position = to
}
