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

// The cents over the last few seconds as a line, one of the display types.
// Shows what the strobe can't: the pluck going sharp and settling, vibrato, a held note drifting.

// Readings, one a frame at the most, the longest span at 120 fps fits with room to spare. The span and the
// range, how many cents from the middle to the top and bottom, are in the config, further is clamped to
// the edge.
TRACE_CAPACITY :: 1024
TRACE_MIN_SECONDS :: 0.5
TRACE_MAX_SECONDS :: 8 // fits TRACE_CAPACITY at MAX_FPS
TRACE_BAND :: 5 // cents either side of in tune, marked with faint lines
TRACE_CURVE_STEPS :: 8 // pieces of the curve between two readings

// Only the actual readings with their time, the curve through them is worked out when drawing
TraceSample :: struct {
    time:  f64, // seconds on the trace's clock
    cents: f32, // NaN marks where the pitch was lost, the line has a gap there
    light: f32, // 0 to 1, as lit as the strobe track's stripes
}

Trace :: struct {
    samples: []TraceSample,
    head:    int, // where the next one goes
    count:   int,
    // Since the app started, in f64: in f32 a frame would round away after a day and a half left open
    clock:   f64,
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
record_trace :: proc(self: ^Trace, cents, light: f32, fresh: bool, frame_time: f32) {
    self.clock += f64(frame_time)

    lost := self.count > 0 && math.is_nan(trace_sample(self, self.count - 1).cents)
    if math.is_nan(cents) {
        // One marker where the pitch goes, not one every frame
        if self.count > 0 && !lost do push_sample(self, {self.clock, cents, 0})
    } else if fresh || lost || self.count == 0 {
        push_sample(self, {self.clock, cents, light})
    }
}

// Oldest on the left, the latest point on the right edge, sharp is up. seconds across, range_cents from
// the middle to the top and bottom.
// The line in the colorway's lit color, the in tune band in its second color
draw_cents_trace :: proc(self: ^Trace, rect: gfx.Rect, seconds, range_cents: f32, line_color, band_color, background: gfx.Color) {
    // As the config file has them, none or longer than the readings kept is as far as they go
    seconds := clamp(seconds, TRACE_MIN_SECONDS, TRACE_MAX_SECONDS)
    range_cents := max(range_cents, TRACE_BAND)
    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

    PADDING :: 28
    plot := gfx.Rect{rect.x, rect.y + PADDING, rect.width, rect.height - 2 * PADDING}
    middle := plot.y + plot.height / 2

    // The in tune band and a line through the middle of it
    band := band_color
    band.a = 110

    // ±TRACE_BAND of the ±range_cents the plot covers
    band_height := TRACE_BAND / range_cents * plot.height
    gfx.draw_rect({plot.x, middle - band_height / 2}, {plot.width, band_height}, band)
    center_line := line_color
    center_line.a = 120
    gfx.draw_rect({plot.x, middle - 1}, {plot.width, 2}, center_line)

    // Inside the plot's top and bottom edges, clear of the tuning arrows above it, in the font and color of
    // the partials on the strobe's tracks
    font := pixel_fonts.band_label
    draw_label(font, fmt.ctprintf("+%.0f¢", range_cents), {plot.x + 10, plot.y + 4}, accent_color)
    draw_label(font, fmt.ctprintf("-%.0f¢", range_cents), {plot.x + 10, plot.y + plot.height - 4 - font.size}, accent_color)

    // Like a lit pen: a soft see-through glow under the line. Both are stamped as anti-aliased dots evenly
    // spaced along the whole line, so the edges and joins are smooth and the glow builds up the same
    // everywhere (4 dots overlap at any point).
    GLOW_RADIUS :: 4.5
    LINE_RADIUS :: 1.25
    glow := line_color
    glow.a = 16

    // The plot's scales, seconds and cents to points
    scale := [2]f32{plot.width / seconds, plot.height / 2 / range_cents}

    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    draw_trace_line(self, plot, middle, scale, GLOW_RADIUS, glow)
    draw_trace_line(self, plot, middle, scale, LINE_RADIUS, line_color)
}

// A curve through the readings, dimmed along the line as the readings' light, with a gap where the pitch
// was lost
draw_trace_line :: proc(self: ^Trace, plot: gfx.Rect, middle: f32, scale: [2]f32, radius: f32, color: gfx.Color) {
    // Placed by time, the newest reading is at the right edge now and scrolls left
    point :: proc(sample: TraceSample, clock: f64, plot: gfx.Rect, middle: f32, scale: [2]f32) -> [2]f32 {
        x := plot.x + plot.width - f32(clock - sample.time) * scale.x
        limit := plot.height / 2
        return {x, middle - clamp(sample.cents * scale.y, -limit, limit)}
    }
    usable :: proc(self: ^Trace, i: int) -> bool {
        return i >= 0 && i < self.count && !math.is_nan(trace_sample(self, i).cents)
    }

    pen := Pen {
        radius = radius,
        color  = color,
    }
    alpha := f32(color.a)

    for i in 0 ..< self.count {
        if !usable(self, i) do continue

        p1 := point(trace_sample(self, i), self.clock, plot, middle, scale)
        if !usable(self, i - 1) {
            // the start of a run
            pen.color.a = u8(alpha * trace_sample(self, i).light)
            pen_start(&pen, p1)
        }
        if !usable(self, i + 1) do continue

        p2 := point(trace_sample(self, i + 1), self.clock, plot, middle, scale)

        // The neighbours on either side set the curve's direction
        p0 := point(trace_sample(self, i - 1), self.clock, plot, middle, scale) if usable(self, i - 1) else p1
        p3 := point(trace_sample(self, i + 2), self.clock, plot, middle, scale) if usable(self, i + 2) else p2
        light1, light2 := trace_sample(self, i).light, trace_sample(self, i + 1).light
        pen_curve_to(&pen, p0, p1, p2, p3, alpha * light1, alpha * light2)
    }
}

// The round shape in one quad, a rounded rect as round draws its four corners
draw_dot :: proc(center: [2]f32, radius: f32, color: gfx.Color) {
    gfx.draw_disc({center.x - radius, center.y - radius, 2 * radius, 2 * radius}, color)
}

// Draws a line as dots half a radius apart, the spacing carries over from one piece of the line to the next
Pen :: struct {
    radius:     f32,
    color:      gfx.Color,
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

// A curve from p1 to p2 (Catmull-Rom), p0 before it and p3 after it set its direction. The pen fades from
// alpha1 to alpha2 along it.
pen_curve_to :: proc(pen: ^Pen, p0, p1, p2, p3: [2]f32, alpha1, alpha2: f32) {
    for step in 1 ..= TRACE_CURVE_STEPS {
        progress := f32(step) / TRACE_CURVE_STEPS
        pen.color.a = u8(math.lerp(alpha1, alpha2, progress))
        pen_line_to(pen, core.catmull_rom(p0, p1, p2, p3, progress))
    }
}
