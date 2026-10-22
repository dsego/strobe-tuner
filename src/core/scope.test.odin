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


#+build !js
package core

import "core:math"
import "core:testing"


// The phase and amplitude of the reference frequency in the screen from above
scope_test_fundamental :: proc(heights: []f32) -> (phase: f64, amp: f64) {
    dft: SingleFreqDFT
    defer destroy_dft(&dft)
    set_dft_freq(&dft, SCOPE_PERIODS / f32(len(heights)), flat_window(len(heights)))

    bin := scope_bin(&dft, heights)

    // a sine at phase 0 comes out at -90°
    return wrap_phase(math.atan2(imag(bin), real(bin)) + math.PI / 2), abs(bin)
}

scope_test_sine :: proc(samples: []f32, freq_hz: f64, clock: i64) {
    for &sample, i in samples {
        sample = f32(math.sin(math.TAU * freq_hz * f64(clock + i64(i)) / DEFAULT_SAMPLE_RATE))
    }
}

SCOPE_TEST_FRAME :: DEFAULT_SAMPLE_RATE / 60

// The screen of the scope display type
scope_test_init :: proc(freq_hz: f64) -> Scope {
    scope := init_scope(488, 240)
    set_scope_freq(&scope, freq_hz)
    return scope
}

@(test)
test_scope_in_tune_stands_still :: proc(t: ^testing.T) {
    // A7, 13.6 samples a period, where rounding to whole samples made the pattern shimmer
    FREQ :: 3520.0

    // The beam was in every column
    no_dark_columns :: proc(dwell: []f32) -> bool {
        for time in dwell {
            if time <= 0 do return false
        }
        return true
    }

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    for frame in 0 ..< 60 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        clear_scope(&scope)
        sweep_samples(&scope, samples[:])
        heights, dwell := scope_from_above(&scope, .RAW_WAVEFORM)
        phase, amp := scope_test_fundamental(heights)
        testing.expectf(t, abs(phase) < 0.01, "frame %v: phase %v", frame, phase)
        testing.expectf(t, amp > 0.95, "frame %v: amp %v", frame, amp)
        testing.expectf(t, no_dark_columns(dwell), "frame %v: dark columns", frame)
    }
}

@(test)
test_scope_detuned_drifts :: proc(t: ^testing.T) {
    // Several periods a frame. A frame is shorter than the sweep of a low note and leaves a part of it dark.
    FREQ :: 440.0
    OFF_HZ :: 0.5

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    // The wave is ahead by the phase the note gained on the reference, in the middle of the frame
    samples: [SCOPE_TEST_FRAME]f32
    for _ in 0 ..< 90 {
        scope_test_sine(samples[:], FREQ + OFF_HZ, scope.sample_clock)
        clear_scope(&scope)
        sweep_samples(&scope, samples[:])
        heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
        phase, _ := scope_test_fundamental(heights)
        middle_s := (f64(scope.sample_clock) - SCOPE_TEST_FRAME / 2) / DEFAULT_SAMPLE_RATE
        expected := wrap_phase(math.TAU * OFF_HZ * middle_s)
        testing.expectf(t, abs(wrap_phase(phase - expected)) < 0.02, "phase %v, expected %v", phase, expected)
    }
}

@(test)
test_scope_fast_drift_washes_out :: proc(t: ^testing.T) {
    FREQ :: 880.0

    // Half a turn during the frame, from above the stripes keep sinc(0.5) of their contrast
    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    scope_test_sine(samples[:], FREQ + 30, 0)
    sweep_samples(&scope, samples[:])
    heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
    _, amp := scope_test_fundamental(heights)
    testing.expectf(t, abs(amp - 0.637) < 0.03, "amp %v", amp)

    // A full turn, nothing is left
    set_scope_freq(&scope, FREQ)
    scope_test_sine(samples[:], FREQ + 60, 0)
    sweep_samples(&scope, samples[:])
    heights, _ = scope_from_above(&scope, .RAW_WAVEFORM)
    _, amp = scope_test_fundamental(heights)
    testing.expectf(t, amp < 0.03, "amp %v", amp)
}

@(test)
test_scope_beam_is_continuous :: proc(t: ^testing.T) {
    // 12 samples a period exactly, the samples alone are 24 dots across the screen
    FREQ :: 4000.0

    // The first and the last lit row of a column of the screen, -1 for a dark column
    lit_rows :: proc(scope: ^Scope, column: int) -> (top: int, bottom: int) {
        top, bottom = -1, -1
        for row in 0 ..< scope.rows {
            if scope.screen[row * scope.columns + column] == 0 do continue
            if top < 0 do top = row

            bottom = row
        }
        return
    }

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    scope_test_sine(samples[:], FREQ, 0)
    sweep_samples(&scope, samples[:])

    // Lit in every column, and from one column to the next the beam is in the same rows or the ones next to them
    previous_top, previous_bottom := -1, -1
    for column in 0 ..< scope.columns {
        top, bottom := lit_rows(&scope, column)
        testing.expectf(t, top >= 0, "column %v is dark", column)
        if previous_top >= 0 {
            testing.expectf(
                t,
                top <= previous_bottom + 1 && bottom >= previous_top - 1,
                "a gap between the columns %v and %v",
                column - 1,
                column,
            )
        }
        previous_top, previous_bottom = top, bottom
    }

    heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
    phase, amp := scope_test_fundamental(heights)
    testing.expectf(t, abs(phase) < 0.01, "phase %v", phase)
    testing.expectf(t, amp > 0.95, "amp %v", amp)
}

@(test)
test_scope_noise_stays_low :: proc(t: ^testing.T) {
    FREQ :: 220.0
    NOISE :: 0.01 // peak, as loud as the room

    // Longer than the level takes to fall back after a note
    amp_over_noise :: proc(snr_db: f32) -> f64 {
        scope := scope_test_init(FREQ)
        defer destroy_scope(&scope)
        scope.noise_floor = NOISE / math.SQRT_TWO
        scope.snr_db = snr_db

        samples: [SCOPE_TEST_FRAME]f32
        for _ in 0 ..< 120 {
            scope_test_sine(samples[:], FREQ, scope.sample_clock)
            for &sample in samples do sample *= NOISE

            clear_scope(&scope)
            sweep_samples(&scope, samples[:])
        }
        heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
        _, amp := scope_test_fundamental(heights)
        return amp
    }

    // No note, as small as it is over the noise
    amp := amp_over_noise(0)
    expected := math.SQRT_TWO / SCOPE_NOISE_HEADROOM
    testing.expectf(t, abs(amp - expected) < 0.02, "amp %v, expected %v", amp, expected)

    // Out of the noise, a note as quiet fills the screen
    amp = amp_over_noise(STROBE_FADE_SNR_DB[1])
    testing.expectf(t, amp > 0.95, "note: amp %v", amp)
}

@(test)
test_scope_lowpass :: proc(t: ^testing.T) {
    // 16 samples a twelfth of a period exactly, the averages cancel the 12th partial
    FREQ :: 250.0

    // The fundamental and the 12th partial of a wave with both, the 12th half as high
    sweep_partials :: proc(lowpass: bool) -> (partials: [2]ScopePartial) {
        scope := scope_test_init(FREQ)
        defer destroy_scope(&scope)
        scope.lowpass = lowpass

        samples, partial: [SCOPE_TEST_FRAME]f32
        for _ in 0 ..< 30 {
            scope_test_sine(samples[:], FREQ, scope.sample_clock)
            scope_test_sine(partial[:], 12 * FREQ, scope.sample_clock)
            for &sample, index in samples do sample += 0.5 * partial[index]
            if lowpass do lowpass_samples(&scope.lowpass_filter, samples[:])

            clear_scope(&scope)
            sweep_samples(&scope, samples[:])
        }
        scope_partials(&scope, []int{SCOPE_PERIODS, 12 * SCOPE_PERIODS}, partials[:])
        return
    }

    off := sweep_partials(false)
    on := sweep_partials(true)
    testing.expectf(t, off[1].level / off[0].level > 0.2, "off: 12th partial %v", off[1].level / off[0].level)
    testing.expectf(t, on[1].level / on[0].level < 0.02, "on: 12th partial %v", on[1].level / on[0].level)

    // Drawn as much earlier as it's delayed, the fundamental stays where it was
    moved := wrap_phase(on[0].phase - off[0].phase)
    testing.expectf(t, abs(moved) < 0.02, "the fundamental moved %v", moved)
}

@(test)
test_scope_persistence :: proc(t: ^testing.T) {
    FREQ :: 220.0

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.persistence_seconds = 0.05

    // A note, then silence: from above the lit half fades with the persistence instead of going dark
    samples: [SCOPE_TEST_FRAME]f32
    for _ in 0 ..< 30 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        sweep_samples(&scope, samples[:])
    }
    heights, _ := scope_from_above(&scope, .HALF_RECTIFIED)
    _, lit := scope_test_fundamental(heights)
    testing.expectf(t, abs(lit - 0.5) < 0.02, "lit %v", lit)

    for &sample in samples do sample = 0
    for _ in 0 ..< 3 do sweep_samples(&scope, samples[:])

    heights, _ = scope_from_above(&scope, .HALF_RECTIFIED)
    _, faded := scope_test_fundamental(heights)
    expected := 0.5 * math.exp(f64(-0.05 / 0.05))
    testing.expectf(t, abs(faded - expected) < 0.02, "faded %v, expected %v", faded, expected)
}

@(test)
test_scope_newest_sweep :: proc(t: ^testing.T) {
    // E2, two periods are 1165 samples and a frame 800. Without persistence a frame alone would leave a part
    // of the screen dark, the newest sweep is whole once there's one.
    FREQ :: 82.4

    dark_columns :: proc(dwell: []f32) -> (count: int) {
        for time in dwell {
            if time == 0 do count += 1
        }
        return
    }

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    scope_test_sine(samples[:], FREQ, 0)
    audio_capture_write(&scope, samples[:])
    update_scope(&scope)
    heights, dwell := scope_from_above(&scope, .RAW_WAVEFORM)
    testing.expectf(t, dark_columns(dwell) > 100, "first frame: %v dark columns", dark_columns(dwell))

    // The next frame completes it: lit all across, in tune, and exactly one sweep of the samples drawn
    scope_test_sine(samples[:], FREQ, SCOPE_TEST_FRAME)
    audio_capture_write(&scope, samples[:])
    update_scope(&scope)
    heights, dwell = scope_from_above(&scope, .RAW_WAVEFORM)
    testing.expectf(t, dark_columns(dwell) == 0, "second frame: %v dark columns", dark_columns(dwell))

    // The AC coupling leads by a degree or so at a low note
    phase, amp := scope_test_fundamental(heights)
    testing.expectf(t, abs(phase) < 0.05, "phase %v", phase)
    testing.expectf(t, amp > 0.95, "amp %v", amp)

    // Every sample leaves one of light on the screen
    light: f32 = 0
    for cell in scope.screen do light += cell
    sweep := f32(math.ceil(1 / scope.step))
    testing.expectf(t, abs(light - sweep) <= 1, "light %v, a sweep is %v samples", light, sweep)
}

@(test)
test_scope_trace :: proc(t: ^testing.T) {
    // A sine's line reaches SCOPE_FILL's height both ways and spans the screen, its points no further apart
    // across than a cell except where the sweep starts over, once, and as long apart in time
    FREQ :: 250.0

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    for _ in 0 ..< 2 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        audio_capture_write(&scope, samples[:])
        update_scope(&scope)
    }

    points: [dynamic][2]f32
    defer delete(points)
    scope_trace(&scope, &points)
    testing.expectf(t, len(points) >= int(1 / scope.step), "%v points", len(points))

    top, bottom, left, right: f32 = 1, 0, 1, 0
    for point in points {
        top, bottom = min(top, point.y), max(bottom, point.y)
        left, right = min(left, point.x), max(right, point.x)
    }
    testing.expectf(t, abs(top - 0.05) < 0.01 && abs(bottom - 0.95) < 0.01, "top %v, bottom %v", top, bottom)
    testing.expectf(t, left < 0.01 && right > 0.99, "left %v, right %v", left, right)

    wraps, uneven := 0, 0
    first_across := (points[1].x - points[0].x) * f32(scope.columns)
    for index in 1 ..< len(points) {
        across := (points[index].x - points[index - 1].x) * f32(scope.columns)
        if abs(across) > f32(scope.columns) / 2 {
            wraps += 1
        } else if across > 1 || abs(across - first_across) > 0.01 {
            uneven += 1
        }
    }
    testing.expectf(t, wraps == 1 && uneven == 0, "%v wraps, %v steps uneven", wraps, uneven)
}

@(test)
test_scope_average :: proc(t: ^testing.T) {
    // A sine in noise as loud as a third of it: the newest sweep's line is as noisy, the sweeps averaged over
    // 18 periods take out most of it
    FREQ :: 220.0
    AMP :: 0.5
    NOISE :: 0.3 // peak, uniform

    // How far the line is from the sine, the RMS of its points in samples
    off_sine :: proc(scope: ^Scope, points: [][2]f32) -> f64 {
        total: f64 = 0
        for point in points {
            value := (0.5 - f64(point.y)) / (0.5 * SCOPE_FILL) * f64(scope.level)
            sine := AMP * math.sin(math.TAU * SCOPE_PERIODS * f64(point.x))
            total += (value - sine) * (value - sine)
        }
        return math.sqrt(total / f64(len(points)))
    }

    newest := scope_test_init(FREQ)
    defer destroy_scope(&newest)

    averaged := scope_test_init(FREQ)
    defer destroy_scope(&averaged)
    averaged.persistence_seconds = 18 / FREQ
    averaged.average_sweeps = true

    // xorshift, the same noise every run
    state: u32 = 1
    samples: [SCOPE_TEST_FRAME]f32
    for frame in 0 ..< 60 {
        // A pluck once the average has settled, the scale is set from it
        if frame == 40 do autoset_scope(&averaged)

        scope_test_sine(samples[:], FREQ, newest.sample_clock)
        for &sample in samples {
            state ~= state << 13
            state ~= state >> 17
            state ~= state << 5
            sample = AMP * sample + NOISE * (2 * f32(state) / f32(max(u32)) - 1)
        }
        for scope in ([]^Scope{&newest, &averaged}) {
            audio_capture_write(scope, samples[:])
            update_scope(scope)
        }
    }

    points: [dynamic][2]f32
    defer delete(points)
    scope_trace(&newest, &points)
    noisy := off_sine(&newest, points[:])
    scope_trace(&averaged, &points)
    clean := off_sine(&averaged, points[:])
    testing.expectf(t, noisy > 0.1, "newest sweep: %v off the sine", noisy)
    testing.expectf(t, clean < 0.04, "averaged: %v off the sine", clean)

    // Scaled to what's drawn: the newest sweep to the noisy input's peak, the average to its own, the sine's
    // and a little of the noise left
    testing.expectf(t, newest.level > AMP + 0.25, "newest sweep: level %v", newest.level)
    testing.expectf(t, averaged.level > AMP && averaged.level < AMP + 0.1, "averaged: level %v", averaged.level)
}

@(test)
test_scope_average_lowpass :: proc(t: ^testing.T) {
    // An in tune sine through the low-pass, averaged: the line is the sine where it is, scaled to its peak. The
    // low-pass started over with every chunk once and dented it where each one began.
    FREQ :: 250.0

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.persistence_seconds = 18 / FREQ
    scope.average_sweeps = true
    scope.lowpass = true

    // Like after the input opened
    restart_beam(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    for _ in 0 ..< 60 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        audio_capture_write(&scope, samples[:])
        update_scope(&scope)
    }

    points: [dynamic][2]f32
    defer delete(points)
    scope_trace(&scope, &points)

    // In rows, the AC coupling leads by about one
    worst: f64 = 0
    for point in points {
        expected := 0.5 - 0.5 * SCOPE_FILL * math.sin(math.TAU * SCOPE_PERIODS * f64(point.x))
        worst = max(worst, abs(f64(point.y) - expected) * f64(scope.rows))
    }
    testing.expectf(t, worst < 2, "%v rows off the sine", worst)
}

@(test)
test_scope_autoset :: proc(t: ^testing.T) {
    // Half a second of a note and half a second of it 20 dB quieter: the scale is held at the note's and
    // the quieter part shrinks, until a pluck sets it again
    FREQ :: 220.0

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.persistence_seconds = 18 / FREQ
    scope.average_sweeps = true

    play :: proc(scope: ^Scope, amp: f32, frames: int) {
        samples: [SCOPE_TEST_FRAME]f32
        for _ in 0 ..< frames {
            scope_test_sine(samples[:], FREQ, scope.sample_clock)
            for &sample in samples do sample *= amp

            audio_capture_write(scope, samples[:])
            update_scope(scope)
        }
    }

    play(&scope, 1, 30)
    testing.expectf(t, abs(scope.level - 1) < 0.01, "note: level %v", scope.level)

    play(&scope, 0.1, 30)
    testing.expectf(t, abs(scope.level - 1) < 0.01, "quieter: level %v", scope.level)

    autoset_scope(&scope)
    play(&scope, 0.1, 30)
    testing.expectf(t, abs(scope.level - 0.1) < 0.01, "plucked: level %v", scope.level)
}

@(test)
test_scope_uniform_gain :: proc(t: ^testing.T) {
    // Half a second of a note and half a second of it 20 dB quieter, uniform: the quieter part is as tall,
    // with no pluck to set the scale again. Under the noise's floor it stays small.
    FREQ :: 220.0

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.persistence_seconds = 18 / FREQ
    scope.average_sweeps = true
    scope.uniform_gain = true

    play :: proc(scope: ^Scope, amp: f32, frames: int) {
        samples: [SCOPE_TEST_FRAME]f32
        for _ in 0 ..< frames {
            scope_test_sine(samples[:], FREQ, scope.sample_clock)
            for &sample in samples do sample *= amp

            audio_capture_write(scope, samples[:])
            update_scope(scope)
        }
    }

    // How tall the average is on the screen, 1 is full
    height :: proc(scope: ^Scope) -> f32 {
        peak: f32 = 0
        for weight, bin in scope.average_weights[:scope.average_bins] {
            if weight > 0 do peak = max(peak, abs(scope.average_sums[bin] / weight))
        }
        return peak / scope.level
    }

    play(&scope, 1, 30)
    testing.expectf(t, abs(height(&scope) - 1) < 0.02, "note: %v tall", height(&scope))

    play(&scope, 0.1, 30)
    testing.expectf(t, abs(height(&scope) - 1) < 0.02, "quieter: %v tall", height(&scope))

    // A tenth of the floor, SCOPE_MIN_LEVEL here
    play(&scope, 0.0001, 30)
    testing.expectf(t, height(&scope) < 0.2, "under the floor: %v tall", height(&scope))
}

@(test)
test_scope_circle_closes :: proc(t: ^testing.T) {
    // A note 31 cents sharp drifts from one sweep to the next, the circle's line still closes at the top
    // without a step: it bends no more sharply anywhere than an in tune note's does
    FREQ :: 220.0

    // Of the line all the way round, the top where its last point is the first again too
    sharpest_bend :: proc(off_hz: f64) -> f32 {
        bend :: proc(before, point, after: [2]f32) -> f32 {
            delta := after - 2 * point + before
            return math.sqrt(delta.x * delta.x + delta.y * delta.y)
        }

        scope := scope_test_init(FREQ)
        defer destroy_scope(&scope)
        set_scope_sweep(&scope, .CIRCLE)
        scope.persistence_seconds = 18 / FREQ
        scope.average_sweeps = true

        samples: [SCOPE_TEST_FRAME]f32
        for _ in 0 ..< 30 {
            scope_test_sine(samples[:], FREQ + off_hz, scope.sample_clock)
            audio_capture_write(&scope, samples[:])
            update_scope(&scope)
        }

        points: [dynamic][2]f32
        defer delete(points)
        scope_trace(&scope, &points)

        last := len(points) - 1
        sharpest := bend(points[last - 1], points[0], points[1])
        for index in 1 ..< last do sharpest = max(sharpest, bend(points[index - 1], points[index], points[index + 1]))
        return sharpest
    }

    in_tune, detuned := sharpest_bend(0), sharpest_bend(4)
    testing.expectf(t, detuned < 1.2 * in_tune, "detuned bends %v, in tune %v", detuned, in_tune)
}

@(test)
test_scope_average_starts_over_on_a_whole_sweep :: proc(t: ^testing.T) {
    // A note between C3 and C♯3, the strobe's reference flips from one to the other and the average starts
    // over at the new one. Every frame after, the bins all have a sweep or none yet: one started over
    // partway into a sweep left the bins before it empty, drawn at zero, and stepped where it began.
    NOTE :: 134.6
    freqs := [2]f64{130.81, 138.59}

    scope := scope_test_init(freqs[0])
    defer destroy_scope(&scope)
    scope.persistence_seconds = 18 / freqs[0]
    scope.average_sweeps = true
    scope.lowpass = true

    samples: [SCOPE_TEST_FRAME]f32
    for frame in 0 ..< 40 {
        // Flips every 7 frames, a frame's samples aren't a whole number of sweeps of either
        if frame % 7 == 6 do set_scope_freq(&scope, freqs[(frame / 7 + 1) % 2])

        scope_test_sine(samples[:], NOTE, scope.sample_clock)
        audio_capture_write(&scope, samples[:])
        update_scope(&scope)

        empty := 0
        for weight in scope.average_weights[:scope.average_bins] {
            if weight == 0 do empty += 1
        }
        testing.expectf(
            t,
            empty == 0 || empty == scope.average_bins,
            "frame %v: %v of %v bins empty",
            frame,
            empty,
            scope.average_bins,
        )
        if empty > 0 do continue

        // A sine moves by under a twentieth of its peak from one bin to the next, the first bin aside, it
        // takes from both sides of where the sweeps meet
        step, peak: f32
        for bin in 1 ..< scope.average_bins - 1 {
            value := scope.average_sums[bin] / scope.average_weights[bin]
            next := scope.average_sums[bin + 1] / scope.average_weights[bin + 1]
            step = max(step, abs(next - value))
            peak = max(peak, abs(value))
        }
        testing.expectf(t, step < 0.05 * peak, "frame %v: steps %.2f of the peak", frame, step / peak)
    }
}

@(test)
test_scope_circle_closes_on_a_string :: proc(t: ^testing.T) {
    // A plucked string a little sharp, its partials sharper the higher (inharmonic), each decaying at its own
    // rate, in a little noise, through the low-pass: every frame, the circle's line bends at the top, where
    // the sweeps meet, about as sharply as the wave does round it. A kink would bend it hundreds of times
    // as sharply.
    FREQ :: 220.0
    OFF_HZ :: 1.0
    PARTIALS :: 8
    INHARMONICITY :: 1e-4 // a wound string's
    NOISE :: 0.02 // peak, uniform

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    set_scope_sweep(&scope, .CIRCLE)
    scope.persistence_seconds = 18 / FREQ
    scope.average_sweeps = true
    scope.lowpass = true

    points: [dynamic][2]f32
    defer delete(points)

    // xorshift, the same noise every run
    state: u32 = 1
    samples: [SCOPE_TEST_FRAME]f32
    worst: f32 = 0
    for frame in 0 ..< 60 {
        for &sample, i in samples {
            time := f64(scope.sample_clock + i64(i)) / DEFAULT_SAMPLE_RATE
            value: f64 = 0
            for n in 1 ..= PARTIALS {
                partial := f64(n)
                freq := partial * (FREQ + OFF_HZ) * math.sqrt(1 + INHARMONICITY * partial * partial)
                value += math.exp(-time * (0.5 + 0.4 * partial)) / partial * math.sin(math.TAU * freq * time + partial)
            }
            state ~= state << 13
            state ~= state >> 17
            state ~= state << 5
            sample = 0.5 * f32(value) + NOISE * (2 * f32(state) / f32(max(u32)) - 1)
        }
        audio_capture_write(&scope, samples[:])
        update_scope(&scope)

        // Once the average has a few sweeps
        if frame < 10 do continue

        // How far each point is out from the middle, in rows, round the line once, the closing point is the
        // first one again
        scope_trace(&scope, &points)
        count := len(points) - 1
        radii := make([]f32, count)
        defer delete(radii)
        for &radius, index in radii {
            x, y := points[index].x - 0.5, points[index].y - 0.5
            radius = math.sqrt(x * x + y * y) * f32(scope.rows)
        }

        // A kink bends the radius both ways, sharply, at the top within a couple of bins of the join
        near := 2 * trace_dots(&scope)
        at_top, elsewhere: f32
        for index in 0 ..< count {
            bend := abs(radii[(index + 1) % count] - 2 * radii[index] + radii[(index + count - 1) % count])
            if index < near || index >= count - near {
                at_top = max(at_top, bend)
            } else {
                elsewhere = max(elsewhere, bend)
            }
        }
        worst = max(worst, at_top / elsewhere)
    }
    testing.expectf(t, worst < 1.5, "bends %.2f times as sharply at the top", worst)
}

@(test)
test_scope_average_has_no_seam :: proc(t: ^testing.T) {
    // A sine in noise through the low-pass, the noise left in the average is smooth too. Taken as they came,
    // the bins behind the newest sample stepped from the ones ahead of it.
    FREQ :: 220.0
    NOISE :: 0.3 // peak, uniform

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.persistence_seconds = 18 / FREQ
    scope.average_sweeps = true
    scope.lowpass = true

    // xorshift, the same noise every run
    state: u32 = 1
    samples: [SCOPE_TEST_FRAME]f32
    for _ in 0 ..< 60 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        for &sample in samples {
            state ~= state << 13
            state ~= state >> 17
            state ~= state << 5
            sample = 0.5 * sample + NOISE * (2 * f32(state) / f32(max(u32)) - 1)
        }
        audio_capture_write(&scope, samples[:])
        update_scope(&scope)
    }

    points: [dynamic][2]f32
    defer delete(points)
    scope_trace(&scope, &points)

    // How sharply the line bends from one point to the next, in rows, a step bends it both ways
    sharpest: f32 = 0
    for index in 1 ..< len(points) - 1 {
        bend := points[index + 1].y - 2 * points[index].y + points[index - 1].y
        sharpest = max(sharpest, abs(bend) * f32(scope.rows))
    }
    testing.expectf(t, sharpest < 0.15, "bends %v rows", sharpest)
}

@(test)
test_scope_circle_spins_clockwise_when_sharp :: proc(t: ^testing.T) {
    // 8 periods a frame, four turns, a part of the petals drawn twice would pull them its way
    FREQ :: 480.0
    OFF_HZ :: 1.0

    // Which way the petals point out of the ring, twice the angle anticlockwise on the screen from the
    // right. A sine's two petals are half a turn apart, at twice their angle they point the same way.
    // From the newest sweep's line, its points as long apart in time
    petals_angle :: proc(scope: ^Scope) -> f64 {
        points: [dynamic][2]f32
        defer delete(points)
        scope_trace(scope, &points)

        petals: [2]f64
        for point in points {
            x, y := f64(point.x) - 0.5, f64(point.y) - 0.5
            radius := math.sqrt(x * x + y * y)
            angle := math.atan2(-y, x)
            petals += (radius - SCOPE_CIRCLE_REACH * SCOPE_CIRCLE_RING) * [2]f64{math.cos(2 * angle), math.sin(2 * angle)}
        }
        return math.atan2(petals.y, petals.x)
    }

    sweep_frame :: proc(scope: ^Scope, freq_hz: f64) {
        samples: [SCOPE_TEST_FRAME]f32
        scope_test_sine(samples[:], freq_hz, scope.sample_clock)
        audio_capture_write(scope, samples[:])
        update_scope(scope)
    }

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    set_scope_sweep(&scope, .CIRCLE)

    // The level starts from nothing, the first frame's first samples are clipped
    for _ in 0 ..< 2 do sweep_frame(&scope, FREQ)
    still := petals_angle(&scope)
    for frame in 0 ..< 60 {
        sweep_frame(&scope, FREQ)
        angle := petals_angle(&scope)
        testing.expectf(t, abs(wrap_phase(angle - still)) < 0.02, "frame %v: turned %v", frame, angle - still)
    }

    // Sharp, an eighth of a turn clockwise in a quarter of a second, half the quarter period it slipped.
    // Twice that at twice the angle.
    sweep_frame(&scope, FREQ + OFF_HZ)
    start := petals_angle(&scope)
    for _ in 0 ..< 15 do sweep_frame(&scope, FREQ + OFF_HZ)

    turned := wrap_phase(petals_angle(&scope) - start)
    testing.expectf(t, abs(turned + math.PI / 2) < 0.05, "turned %v, expected %v", turned, -math.PI / 2)
}

@(test)
test_scope_gain :: proc(t: ^testing.T) {
    FREQ :: 220.0

    // A second of a loud note and 0.4 s of it 20 dB quieter: the level is down at the quieter note's peak once
    // the loud one left its SCOPE_FILL_MIN_PERIODS and the level glided down over a few SCOPE_FILL_RELEASE_S
    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)

    samples: [SCOPE_TEST_FRAME]f32
    for frame in 0 ..< 84 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        if frame >= 60 do for &sample in samples do sample *= 0.1

        sweep_samples(&scope, samples[:])
    }
    testing.expectf(t, abs(scope.level - 0.1) < 0.01, "level %v", scope.level)
}

@(test)
test_scope_fill_holds_over_the_screen :: proc(t: ^testing.T) {
    FREQ :: 220.0
    BEAT_PERIODS :: 4 // loud for as many periods, then as many 20% quieter

    // A note whose peak beats, under the persistence of 11 periods. Every copy on the screen is drawn at the
    // same size, the level doesn't follow the quieter periods down.
    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.persistence_seconds = 0.05

    samples: [SCOPE_TEST_FRAME]f32
    for frame in 0 ..< 30 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        for &sample, index in samples {
            period := (scope.sample_clock + i64(index)) * i64(FREQ) / DEFAULT_SAMPLE_RATE
            if period / BEAT_PERIODS % 2 == 1 do sample *= 0.8
        }
        sweep_samples(&scope, samples[:])
        if frame > 0 do testing.expectf(t, scope.level > 0.99, "frame %v: level %v", frame, scope.level)
    }
}
