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
// A dot at now leaves the line behind it, a little way in from the right edge, notches across now mark the
// cents.

// Readings, one a frame at the most, the longest span at 120 fps fits with room to spare. The span and the
// range, how many cents from the middle to the top and bottom, are in the config, further is clamped to
// the edge.
TRACE_CAPACITY :: 1024
TRACE_MIN_S :: 0.5
TRACE_MAX_S :: 8 // fits TRACE_CAPACITY at MAX_FPS
TRACE_BAND :: 5 // cents either side of in tune, marked with faint lines
TRACE_CURVE_STEPS :: 8 // pieces of the curve between two readings

// Over and under the plot, clear of the tuning arrows
TRACE_PADDING :: 28

// From now to the view's right edge in points, the in tune band and its line go on across it.
// -define:TRACE_GAP=n to try another.
TRACE_GAP :: f32(#config(TRACE_GAP, 56))

// The notches across now, at the tens halfway out and at the ends, as long in points.
// -define:TRACE_NOTCH=n to try another.
TRACE_NOTCH :: f32(#config(TRACE_NOTCH, 14))

// The dot at now, its radius in points, -define:TRACE_DOT_RADIUS=n to try another
TRACE_DOT_RADIUS :: f32(#config(TRACE_DOT_RADIUS, 6))

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

// The readings' part of the view, left of now. Now is its right edge.
trace_plot :: proc(view: gfx.Rect) -> gfx.Rect {
    return {view.x, view.y + TRACE_PADDING, view.width - TRACE_GAP, view.height - 2 * TRACE_PADDING}
}

// Oldest on the left, the newest at now on the plot's right edge, sharp is up. The config's trace seconds
// across, its range in cents from the middle to the top and bottom.
// The line in the colorway's lit color, the in tune band in its second color
draw_trace_display :: proc(self: ^TraceDisplay, rect: gfx.Rect, config: ^Config) {
    // The trace, and the dot at now over its end
    draw_plot :: proc(self: ^TraceDisplay, plot: gfx.Rect, span, cents_range: f32, line_color: gfx.Color) {
        middle := plot.y + plot.height / 2

        // Without a glow, its edges fade over a pixel
        LINE_RADIUS :: 1.25
        pixel := 1 / gfx.dpi_scale()

        // The plot's scales, seconds and cents to points
        axes := TraceAxes{plot, middle, {plot.width / span, plot.height / 2 / cents_range}}
        draw_trace_line(self, axes, 2 * LINE_RADIUS + pixel, pixel, line_color)

        // As lit as the newest reading, gone with the pitch. A pill as tall as it's wide, round like the
        // buttons' ends.
        newest := self.count - 1
        if !usable_trace_sample(self, newest) do return

        now := [2]f32{plot.x + plot.width, trace_point(self, newest, axes).y}
        light := trace_sample(self, newest).light
        radius := TRACE_DOT_RADIUS
        gfx.draw_pill({now.x - radius, now.y - radius, 2 * radius, 2 * radius}, fade_color(line_color, light))
    }

    colors := strobe_colors(config)
    line_color, band_color, background := gfx.hex(colors.x), gfx.hex(colors.y), gfx.hex(strobe_bg_color)

    // As the config file has them, none or longer than the readings kept is as far as they go
    span := clamp(config.trace_seconds, TRACE_MIN_S, TRACE_MAX_S)
    cents_range := max(config.trace_range_cents, TRACE_BAND)
    plot := trace_plot(rect)
    middle := plot.y + plot.height / 2

    // Sharp with the retro glow too, it's the strobe's lamp and the scope's phosphor, a plot has neither
    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

    // The in tune band, ±TRACE_BAND of the ±cents_range the plot covers, across the whole view. Through the
    // middle of it a thin line in the notches' gray, the scale's zero, the colorway's lit color is the trace's.
    band := band_color
    band.a = 110
    band_height := TRACE_BAND / cents_range * plot.height
    gfx.draw_rect({rect.x, middle - band_height / 2}, {rect.width, band_height}, band)
    gfx.draw_rect(snap_to_pixels({rect.x, middle - 0.5}), {rect.width, 1}, text_color_muted)

    draw_trace_notches(plot, cents_range)

    gfx.begin_scissor(rect)
    draw_plot(self, plot, span, cents_range, line_color)
    gfx.end_scissor()
}

// Across now at the tens halfway out and at the ends, each with its cents in a small label right of it, in the
// ruler's gray: every notch says what it is. In tune is the band's line, the band's edges are ±TRACE_BAND.
draw_trace_notches :: proc(plot: gfx.Rect, cents_range: f32) {
    LABEL_GAP :: 3

    draw_notch :: proc(plot: gfx.Rect, cents, cents_range: f32) {
        now := plot.x + plot.width
        y := plot.y + plot.height / 2 * (1 - cents / cents_range)
        gfx.draw_rect(snap_to_pixels({now - TRACE_NOTCH / 2, y - 0.5}), {TRACE_NOTCH, 1}, text_color_muted)

        font := pixel_fonts.label_small
        text := fmt.ctprintf("%+.0f¢", cents)
        position := [2]f32{now + TRACE_NOTCH / 2 + LABEL_GAP, y - measure_label(font, text).y / 2}
        draw_label(font, text, snap_to_pixels(position), text_color_muted)
    }

    // 10 on the narrow range, 20 on the wide one, none on a range too narrow for it
    halfway := math.floor(cents_range / 2 / 10) * 10
    for side in ([2]f32{-1, 1}) {
        if halfway > 0 do draw_notch(plot, side * halfway, cents_range)
        draw_notch(plot, side * cents_range, cents_range)
    }
}

// A curve through the readings, dimmed along the line as the readings' light, with a gap where the pitch
// was lost
draw_trace_line :: proc(self: ^TraceDisplay, axes: TraceAxes, thickness, feather: f32, color: gfx.Color) {
    // Each run of readings between the gaps, its own curve. One that starts left of the plot is cut there.
    start := first_shown_trace_sample(self, axes)
    for start < self.count {
        if !usable_trace_sample(self, start) {
            start += 1
            continue
        }

        end := start
        for usable_trace_sample(self, end + 1) do end += 1

        draw_trace_run(self, start, end, axes, thickness, feather, color)
        start = end + 1
    }
}

// Where the readings go on the plot
TraceAxes :: struct {
    plot:   gfx.Rect,
    middle: f32, // in tune
    scale:  [2]f32, // seconds and cents to points
}

// Placed by time, a reading is at the right edge when it comes and scrolls left
trace_point :: proc(self: ^TraceDisplay, index: int, axes: TraceAxes) -> [2]f32 {
    sample := trace_sample(self, index)
    x := axes.plot.x + axes.plot.width - f32(self.clock - sample.time) * axes.scale.x
    limit := axes.plot.height / 2
    return {x, axes.middle - clamp(sample.cents * axes.scale.y, -limit, limit)}
}

// A reading with a pitch, not past either end
usable_trace_sample :: proc(self: ^TraceDisplay, index: int) -> bool {
    return index >= 0 && index < self.count && !math.is_nan(trace_sample(self, index).cents)
}

// The last reading left of the plot, the older ones are past its left edge
first_shown_trace_sample :: proc(self: ^TraceDisplay, axes: TraceAxes) -> int {
    shown_from := self.clock - f64(axes.plot.width / axes.scale.x)
    first := 0
    for first + 1 < self.count && trace_sample(self, first + 1).time < shown_from do first += 1
    return first
}

// A Catmull-Rom curve through the readings from start to end, fading from each one's light to the next
// one's. The usable neighbours either side set the curve's direction, at its ends too. The newest reading
// holds on to now, the dot's there.
draw_trace_run :: proc(self: ^TraceDisplay, start, end: int, axes: TraceAxes, thickness, feather: f32, color: gfx.Color) {
    points := make([dynamic][2]f32, context.temp_allocator)
    colors := make([dynamic]gfx.Color, context.temp_allocator)
    append(&points, trace_point(self, start, axes))
    append(&colors, fade_color(color, trace_sample(self, start).light))

    for index in start ..< end {
        from := trace_point(self, index, axes)
        to := trace_point(self, index + 1, axes)
        before := trace_point(self, index - 1, axes) if usable_trace_sample(self, index - 1) else from
        after := trace_point(self, index + 2, axes) if usable_trace_sample(self, index + 2) else to
        light_from, light_to := trace_sample(self, index).light, trace_sample(self, index + 1).light

        for step in 1 ..= TRACE_CURVE_STEPS {
            progress := f32(step) / TRACE_CURVE_STEPS
            append(&points, core.catmull_rom(before, from, to, after, progress))
            append(&colors, fade_color(color, math.lerp(light_from, light_to, progress)))
        }
    }

    newest := points[len(points) - 1]
    now := axes.plot.x + axes.plot.width
    if end == self.count - 1 && newest.x < now {
        append(&points, [2]f32{now, newest.y})
        append(&colors, colors[len(colors) - 1])
    }
    gfx.draw_soft_polyline(points[:], colors[:], thickness, feather)
}
