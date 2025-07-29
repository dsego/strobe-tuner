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
import "core:fmt"
import "core:math"
import rl "vendor:raylib"

draw_nsdf :: proc(rect: rl.Rectangle, nsdf: ^core.NSDFConfig, peak: core.Vec2, font: rl.Font) {
    points: [4096]rl.Vector2 = {}


    start := 0 // enables me to move the start to zoom into a portion of the graph
    // end := len(nsdf.nsdf)
    end := 1500
    len := end - start

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(len - 1)

    x := rect.x
    gain := 1.0 / nsdf.nsdf[0]

    for i in 0 ..< len {
        y := rect.y + (rect.height / 2.0) - nsdf.nsdf[start + i] * (rect.height / 2.0) * gain
        points[i] = {x, y}
        x += px_per_sample
    }

    draw_time_plot(rect, len, 1000, font)
    rl.DrawLineStrip(raw_data(points[:]), i32(len), rl.GOLD)

    // Mark peak positions with a cross
    for peak, i in nsdf.nsdf_peaks {
        val := peak.y / nsdf.nsdf[0]
        rel_lag := f32(peak.x) - f32(start)

        cx := rect.x + rel_lag * f32(rect.width) / f32(len - 1)
        cy := rect.y + (rect.height / 2.0) - val * (rect.height / 2.0)

        if cx > rect.x + rect.width do break

        // Vertical ruler
        rl.DrawLineEx({cx, cy}, {cx, rect.y + rect.height}, 0.5, rl.LIGHTGRAY)
        ruler_label_y := rect.y + rect.height + 8
        // small vertical offset so labels don't overlap
        if i % 2 == 0 {
            ruler_label_y += 16
        }
        rl.DrawTextEx(
            font,
            fmt.ctprintf("%.2fHz", f32(nsdf.samplerate) / peak.x),
            {cx, ruler_label_y},
            12,
            0,
            rl.LIGHTGRAY,
        )

        // X marker - cross
        color := rl.LIGHTGRAY
        if nsdf.chosen_peak_idx == i {
            color = rl.PINK
        }
        rl.DrawLineEx({cx - 7.0, cy}, {cx + 7.0, cy}, 2.0, color)
        rl.DrawLineEx({cx, cy - 7.0}, {cx, cy + 7.0}, 2.0, color)
    }
}


draw_time_plot :: proc(rect: rl.Rectangle, len_samples: int, div_samples: int, font: rl.Font) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({rect.x, rect.y}, {rect.x + rect.width, rect.y}, 0.5, rl.LIGHTGRAY)
    rl.DrawTextEx(font, "1", {rect.x - 16, rect.y - 8}, 12, 0, rl.LIGHTGRAY)

    rl.DrawLineEx(
        {rect.x, rect.y + rect.height / 2},
        {rect.x + rect.width, rect.y + rect.height / 2},
        0.5,
        rl.LIGHTGRAY,
    )
    rl.DrawTextEx(font, "0", {rect.x - 16, rect.y + rect.height / 2 - 8}, 12, 0, rl.LIGHTGRAY)

    rl.DrawLineEx(
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        rl.LIGHTGRAY,
    )
    rl.DrawTextEx(font, "-1", {rect.x - 24, rect.y + rect.height - 8}, 12, 0, rl.LIGHTGRAY)

    // Vertical lines every x samples
    px_per_sample := rect.width / f32(len_samples)

    for d := 0; d < len_samples; d += div_samples {
        px := rect.x + f32(d) * px_per_sample
        rl.DrawLineEx({px, rect.y}, {px, rect.y + rect.height}, 0.5, rl.LIGHTGRAY)
    }

    rl.DrawLineEx(
        {rect.x + rect.width, rect.y},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        rl.LIGHTGRAY,
    )
}

FreqPeak :: struct {
    position:  rl.Vector2,
    magnitude: f32,
    frequency: f32,
}

draw_freq_plot :: proc(rect: rl.Rectangle, nsdf: ^core.NSDFConfig, font: rl.Font) {
    points: [256]rl.Vector2 = {}
    peak_candidates: [256]FreqPeak = {}
    peaks: [256]FreqPeak = {}

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(len(points) - 1)

    x := rect.x
    gain: f32 = 1.0 / f32(nsdf.fft_size)

    rl.DrawTextEx(font, "0dB", {rect.x, rect.y - 16}, 12, 0, rl.LIGHTGRAY)
    rl.DrawTextEx(font, "-100dB", {rect.x, rect.y + rect.height + 8}, 12, 0, rl.LIGHTGRAY)

    rl.DrawLineEx({rect.x, rect.y}, {rect.x + rect.width, rect.y}, 0.5, rl.LIGHTGRAY)
    rl.DrawLineEx(
        {rect.x, rect.y + rect.height / 2},
        {rect.x + rect.width, rect.y + rect.height / 2},
        0.5,
        rl.LIGHTGRAY,
    )
    rl.DrawLineEx(
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        rl.LIGHTGRAY,
    )
    rl.DrawLineEx({rect.x, rect.y}, {rect.x, rect.y + rect.height}, 0.5, rl.LIGHTGRAY)

    for i in 0 ..< len(points) {
        normalized_magnitude := abs(nsdf.fft[i]) / f32(nsdf.fft_size)
        db_val := 20 * math.log10(normalized_magnitude)
        db_min :: f32(-100.0)
        db_max :: f32(0.0)

        scaled := (db_val - db_min) / (db_max - db_min)
        scaled = clamp(scaled, 0, 1)

        y := rect.y + rect.height - scaled * rect.height
        points[i] = {x, y}
        x += px_per_sample


    }
    // first pass
    j := 0

    for i in 0 ..< len(points) {
        if i > 0 &&
           i < len(points) - 1 &&
           abs(nsdf.fft[i]) > abs(nsdf.fft[i - 1]) &&
           abs(nsdf.fft[i]) > abs(nsdf.fft[i + 1]) {
            delta, magnitude := core.parabolic(
                abs(nsdf.fft[i - 1]),
                abs(nsdf.fft[i]),
                abs(nsdf.fft[i + 1]),
            )
            peak_candidates[j] = {
                {points[i].x, points[i].y},
                magnitude,
                (f32(i) + delta) * f32(nsdf.samplerate) / f32(nsdf.fft_size),
            }
            j += 1
        }
    }

    // second pass to remove the jaggedness
    min_prominence: f32 = 1.4125 // 3dB
    k := 0
    for i in 0 ..< len(peak_candidates) {
        if i > 0 &&
           i < len(peak_candidates) - 1 &&
           peak_candidates[i].magnitude > peak_candidates[i - 1].magnitude * min_prominence &&
           peak_candidates[i].magnitude > peak_candidates[i + 1].magnitude * min_prominence &&
           peak_candidates[i].magnitude > 10 {
            peaks[k] = peak_candidates[i]
            k += 1
        }
    }
    found := k

    rl.DrawLineStrip(raw_data(points[:]), i32(len(points)), rl.PINK)

    for i in 0 ..< found {
        rl.DrawLineEx(
            {peaks[i].position.x, peaks[i].position.y},
            {peaks[i].position.x, rect.y + rect.height},
            0.5,
            rl.LIGHTGRAY,
        )
        rl.DrawCircleV({peaks[i].position.x, peaks[i].position.y}, 3.0, rl.GOLD)
        rl.DrawTextEx(
            font,
            fmt.ctprintf("%.1fHz", peaks[i].frequency),
            {peaks[i].position.x, peaks[i].position.y - 20},
            12,
            0,
            rl.GOLD,
        )
    }
}
