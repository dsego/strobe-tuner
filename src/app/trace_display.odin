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

// The glow's alpha inside its fading edges, -define:TRACE_GLOW_ALPHA=n to try another
TRACE_GLOW_ALPHA :: #config(TRACE_GLOW_ALPHA, 80)

// Only the actual readings with their time, the curve through them is worked out when drawing
TraceSample :: struct {
    time:  f64, // seconds on the trace's clock
    cents: f32, // NaN marks where the pitch was lost, the line has a gap there
    light: f32, // 0 to 1, as lit as the strobe track's stripes
}

TraceDisplay :: struct {
    samples: []TraceSample,
    head:    int, // where the next one goes
    count:   int,
    // Since the app started, in f64: in f32 a frame would round away after a day and a half left open
    clock:   f64,
}

init_trace_display :: proc() -> (self: TraceDisplay) {
    self.samples = make([]TraceSample, TRACE_CAPACITY)
    return self
}

destroy_trace_display :: proc(self: ^TraceDisplay) {
    delete(self.samples)
}

trace_sample :: proc(self: ^TraceDisplay, index: int) -> TraceSample {
    capacity := len(self.samples)
    return self.samples[(self.head - self.count + index + capacity) % capacity]
}

push_sample :: proc(self: ^TraceDisplay, sample: TraceSample) {
    self.samples[self.head] = sample
    self.head = (self.head + 1) % len(self.samples)
    self.count = min(self.count + 1, len(self.samples))
}

// Called every frame, fresh tells a new reading from the previous one repeated
record_trace :: proc(self: ^TraceDisplay, cents, light: f32, fresh: bool, frame_time: f32) {
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
// With the retro glow the band and the line glow like the spectrum's curve.
draw_trace_display :: proc(
    self: ^TraceDisplay,
    targets: ^GlowTargets,
    rect: gfx.Rect,
    seconds, range_cents: f32,
    line_color, band_color, background: gfx.Color,
    retro_glow: bool,
) {
    // The in tune band, a line through the middle of it and the trace over them
    draw_plot :: proc(self: ^TraceDisplay, plot: gfx.Rect, span, cents_range: f32, line_color, band_color: gfx.Color) {
        middle := plot.y + plot.height / 2

        band := band_color
        band.a = 110

        // ±TRACE_BAND of the ±cents_range the plot covers
        band_height := TRACE_BAND / cents_range * plot.height
        gfx.draw_rect({plot.x, middle - band_height / 2}, {plot.width, band_height}, band)
        center_line := line_color
        center_line.a = 120
        gfx.draw_rect({plot.x, middle - 1}, {plot.width, 2}, center_line)

        // Like a lit pen: a see-through glow under the line, even across most of it and fading out at its
        // edges. The line's edges fade over a pixel.
        GLOW_RADIUS :: 4.5
        GLOW_FEATHER :: 1.5
        LINE_RADIUS :: 1.25
        glow := line_color
        glow.a = TRACE_GLOW_ALPHA
        pixel := 1 / gfx.dpi_scale()

        // The plot's scales, seconds and cents to points
        scale := [2]f32{plot.width / span, plot.height / 2 / cents_range}

        draw_trace_line(self, plot, middle, scale, 2 * GLOW_RADIUS, GLOW_FEATHER, glow)
        draw_trace_line(self, plot, middle, scale, 2 * LINE_RADIUS + pixel, pixel, line_color)
    }

    // As the config file has them, none or longer than the readings kept is as far as they go
    span := clamp(seconds, TRACE_MIN_SECONDS, TRACE_MAX_SECONDS)
    cents_range := max(range_cents, TRACE_BAND)

    PADDING :: 28
    plot := gfx.Rect{rect.x, rect.y + PADDING, rect.width, rect.height - 2 * PADDING}

    if retro_glow {
        begin_glow(targets, rect, background)
        draw_plot(self, plot, span, cents_range, line_color, band_color)
        end_glow(targets, rect, 1)
    } else {
        gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

        gfx.begin_scissor(rect)
        draw_plot(self, plot, span, cents_range, line_color, band_color)
        gfx.end_scissor()
    }

    // Sharp over it, inside the plot's top and bottom edges, clear of the tuning arrows above it, in the font
    // and color of the partials on the strobe's tracks
    font := pixel_fonts.band_label
    draw_label(font, fmt.ctprintf("+%.0f¢", cents_range), {plot.x + 10, plot.y + 4}, accent_color)
    draw_label(font, fmt.ctprintf("-%.0f¢", cents_range), {plot.x + 10, plot.y + plot.height - 4 - font.size}, accent_color)
}

// A curve through the readings, dimmed along the line as the readings' light, with a gap where the pitch
// was lost
draw_trace_line :: proc(self: ^TraceDisplay, plot: gfx.Rect, middle: f32, scale: [2]f32, thickness, feather: f32, color: gfx.Color) {
    // Placed by time, the newest reading is at the right edge now and scrolls left
    point :: proc(sample: TraceSample, clock: f64, plot: gfx.Rect, middle: f32, scale: [2]f32) -> [2]f32 {
        x := plot.x + plot.width - f32(clock - sample.time) * scale.x
        limit := plot.height / 2
        return {x, middle - clamp(sample.cents * scale.y, -limit, limit)}
    }
    usable :: proc(self: ^TraceDisplay, index: int) -> bool {
        return index >= 0 && index < self.count && !math.is_nan(trace_sample(self, index).cents)
    }

    faded :: proc(color: gfx.Color, alpha: f32) -> gfx.Color {
        return {color.r, color.g, color.b, u8(alpha)}
    }

    // One run of readings at a time, drawn where the pitch is lost or at the newest
    points := make([dynamic][2]f32, context.temp_allocator)
    colors := make([dynamic]gfx.Color, context.temp_allocator)
    alpha := f32(color.a)

    // From the last reading left of the plot on, the older ones are past its left edge
    shown_from := self.clock - f64(plot.width / scale.x)
    first := 0
    for first + 1 < self.count && trace_sample(self, first + 1).time < shown_from do first += 1

    for index in first ..< self.count {
        if !usable(self, index) do continue

        from := point(trace_sample(self, index), self.clock, plot, middle, scale)
        if index == first || !usable(self, index - 1) {
            // the start of a run, or of what's shown
            clear(&points)
            clear(&colors)
            append(&points, from)
            append(&colors, faded(color, alpha * trace_sample(self, index).light))
        }
        if !usable(self, index + 1) {
            gfx.draw_soft_polyline(points[:], colors[:], thickness, feather)
            continue
        }

        to := point(trace_sample(self, index + 1), self.clock, plot, middle, scale)

        // The neighbours on either side set the curve's direction
        before := point(trace_sample(self, index - 1), self.clock, plot, middle, scale) if usable(self, index - 1) else from
        after := point(trace_sample(self, index + 2), self.clock, plot, middle, scale) if usable(self, index + 2) else to
        light_from, light_to := trace_sample(self, index).light, trace_sample(self, index + 1).light

        // A Catmull-Rom curve to the next reading, fading from this one's light to the next one's
        for step in 1 ..= TRACE_CURVE_STEPS {
            progress := f32(step) / TRACE_CURVE_STEPS
            append(&points, core.catmull_rom(before, from, to, after, progress))
            append(&colors, faded(color, math.lerp(alpha * light_from, alpha * light_to, progress)))
        }
    }
}
