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

import "../core"
import "../gfx"
import "core:fmt"
import "core:math"

// The debug plots of the DEBUG_STATS build, the NSDF and the spectrum of the latest pitch detection

// The NSDF over the first lags, a cross on each key maximum, the chosen one pink
draw_nsdf :: proc(rect: gfx.Rect,nsdf: ^core.NSDF, font: gfx.Font) {
    LAGS :: 1500
    points: [LAGS][2]f32

    lag_width := rect.width / f32(LAGS - 1)
    middle := rect.y + rect.height / 2
    gain := 1.0 / nsdf.values[0]
    for &point, lag in points {
        point = {rect.x + f32(lag) * lag_width, middle - nsdf.values[lag] * (rect.height / 2) * gain}
    }

    draw_time_plot(rect, LAGS, 1000, font)
    gfx.draw_line_strip(points[:], gfx.GOLD)

    for peak, index in nsdf.peaks {
        cross := [2]f32{rect.x + peak.x * lag_width, middle - peak.y * gain * (rect.height / 2)}
        if cross.x > rect.x + rect.width do break

        // A line down to the frequency, every other one lower so they don't overlap
        gfx.draw_line(cross, {cross.x, rect.y + rect.height}, 0.5, gfx.LIGHTGRAY)
        label_y := rect.y + rect.height + (24 if index % 2 == 0 else 8)
        gfx.draw_text(font, fmt.ctprintf("%.2fHz", core.SAMPLERATE / peak.x), {cross.x, label_y}, 12, 0, gfx.LIGHTGRAY)

        color := gfx.PINK if index == nsdf.chosen_peak else gfx.LIGHTGRAY
        gfx.draw_line(cross - {7, 0}, cross + {7, 0}, 2.0, color)
        gfx.draw_line(cross - {0, 7}, cross + {0, 7}, 2.0, color)
    }
}


draw_time_plot :: proc(rect: gfx.Rect,len_samples: int, div_samples: int, font: gfx.Font) {
    // Horizontal lines at 1,0,-1
    gfx.draw_line({rect.x, rect.y}, {rect.x + rect.width, rect.y}, 0.5, gfx.LIGHTGRAY)
    gfx.draw_text(font, "1", {rect.x - 16, rect.y - 8}, 12, 0, gfx.LIGHTGRAY)

    gfx.draw_line(
        {rect.x, rect.y + rect.height / 2},
        {rect.x + rect.width, rect.y + rect.height / 2},
        0.5,
        gfx.LIGHTGRAY,
    )
    gfx.draw_text(font, "0", {rect.x - 16, rect.y + rect.height / 2 - 8}, 12, 0, gfx.LIGHTGRAY)

    gfx.draw_line(
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        gfx.LIGHTGRAY,
    )
    gfx.draw_text(font, "-1", {rect.x - 24, rect.y + rect.height - 8}, 12, 0, gfx.LIGHTGRAY)

    // Vertical lines every div_samples
    sample_width := rect.width / f32(len_samples)
    for sample := 0; sample < len_samples; sample += div_samples {
        x := rect.x + f32(sample) * sample_width
        gfx.draw_line({x, rect.y}, {x, rect.y + rect.height}, 0.5, gfx.LIGHTGRAY)
    }

    gfx.draw_line(
        {rect.x + rect.width, rect.y},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        gfx.LIGHTGRAY,
    )
}

// The power spectrum of the lowest bins in dB, the peaks that stand out marked with their frequency
draw_freq_plot :: proc(rect: gfx.Rect,nsdf: ^core.NSDF, font: gfx.Font) {
    FreqPeak :: struct {
        position:  [2]f32,
        magnitude: f32,
        frequency: f32,
    }
    BINS :: 256
    DB_MIN :: f32(-100.0)
    DB_MAX :: f32(0.0)

    points: [BINS][2]f32
    bin_width := rect.width / f32(BINS - 1)

    gfx.draw_text(font, "0dB", {rect.x, rect.y - 16}, 12, 0, gfx.LIGHTGRAY)
    gfx.draw_text(font, "-100dB", {rect.x, rect.y + rect.height + 8}, 12, 0, gfx.LIGHTGRAY)

    gfx.draw_line({rect.x, rect.y}, {rect.x + rect.width, rect.y}, 0.5, gfx.LIGHTGRAY)
    gfx.draw_line(
        {rect.x, rect.y + rect.height / 2},
        {rect.x + rect.width, rect.y + rect.height / 2},
        0.5,
        gfx.LIGHTGRAY,
    )
    gfx.draw_line(
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        gfx.LIGHTGRAY,
    )
    gfx.draw_line({rect.x, rect.y}, {rect.x, rect.y + rect.height}, 0.5, gfx.LIGHTGRAY)

    magnitudes: [BINS]f32
    for &point, bin in points {
        magnitudes[bin] = abs(nsdf.spectrum[bin])
        db := 20 * math.log10(magnitudes[bin] / f32(nsdf.fft_size))
        scaled := clamp((db - DB_MIN) / (DB_MAX - DB_MIN), 0, 1)
        point = {rect.x + f32(bin) * bin_width, rect.y + rect.height - scaled * rect.height}
    }

    // Every local maximum, then the ones that stand out from their neighbours, the rest is jagged
    candidates: [BINS]FreqPeak
    candidate_count := 0
    for bin in 1 ..< BINS - 1 {
        if magnitudes[bin] <= magnitudes[bin - 1] || magnitudes[bin] <= magnitudes[bin + 1] do continue

        offset, magnitude := core.parabolic(magnitudes[bin - 1], magnitudes[bin], magnitudes[bin + 1])
        frequency := (f32(bin) + offset) * core.SAMPLERATE / f32(nsdf.fft_size)
        candidates[candidate_count] = {points[bin], magnitude, frequency}
        candidate_count += 1
    }

    gfx.draw_line_strip(points[:], gfx.PINK)

    MIN_PROMINENCE :: 1.4125 // 3 dB
    for index in 1 ..< max(candidate_count - 1, 1) {
        peak := candidates[index]
        prominent :=
            peak.magnitude > candidates[index - 1].magnitude * MIN_PROMINENCE &&
            peak.magnitude > candidates[index + 1].magnitude * MIN_PROMINENCE &&
            peak.magnitude > 10
        if !prominent do continue

        gfx.draw_line(peak.position, {peak.position.x, rect.y + rect.height}, 0.5, gfx.LIGHTGRAY)
        gfx.draw_circle(peak.position, 3.0, gfx.GOLD)
        gfx.draw_text(font, fmt.ctprintf("%.1fHz", peak.frequency), peak.position - {0, 20}, 12, 0, gfx.GOLD)
    }
}
