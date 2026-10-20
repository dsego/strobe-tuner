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

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.noise_floor = NOISE / math.SQRT_TWO

    // Longer than the level takes to fall back after a note, as small as it is over the noise
    samples: [SCOPE_TEST_FRAME]f32
    for _ in 0 ..< 120 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        for &sample in samples do sample *= NOISE

        clear_scope(&scope)
        sweep_samples(&scope, samples[:])
    }
    heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
    _, amp := scope_test_fundamental(heights)
    expected := math.SQRT_TWO / SCOPE_NOISE_HEADROOM
    testing.expectf(t, abs(amp - expected) < 0.02, "amp %v, expected %v", amp, expected)
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
test_scope_xy_in_tune_stands_still :: proc(t: ^testing.T) {
    FREQ :: 440.0
    OFF_HZ :: 1.0

    // How far the beam is from the circle a sine draws against the reference's cosine, in cells,
    // averaged over how long it stayed
    off_circle :: proc(scope: ^Scope) -> f64 {
        width := scope_width(scope)
        radius := 0.5 * SCOPE_FILL * f64(width)
        total, dwell: f64
        for cell, i in scope.screen {
            if cell == 0 do continue

            x := f64(i % scope.columns) + 0.5 - 0.5 * f64(width)
            y := f64(i / scope.columns) + 0.5 - 0.5 * f64(scope.rows)
            total += f64(cell) * abs(math.sqrt(x * x + y * y) - radius)
            dwell += f64(cell)
        }
        return total / dwell
    }

    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    set_scope_sweep(&scope, .XY)

    samples: [SCOPE_TEST_FRAME]f32
    for frame in 0 ..< 60 {
        scope_test_sine(samples[:], FREQ, scope.sample_clock)
        clear_scope(&scope)
        sweep_samples(&scope, samples[:])
        distance := off_circle(&scope)
        testing.expectf(t, distance < 1, "frame %v: %v cells off the circle", frame, distance)
    }

    // A quarter of a turn later the circle has rolled shut into a line
    set_scope_sweep(&scope, .XY)
    for _ in 0 ..< 15 {
        scope_test_sine(samples[:], FREQ + OFF_HZ, scope.sample_clock)
        clear_scope(&scope)
        sweep_samples(&scope, samples[:])
    }
    distance := off_circle(&scope)
    testing.expectf(t, distance > 20, "%v cells off the circle", distance)
}

@(test)
test_scope_gain :: proc(t: ^testing.T) {
    FREQ :: 220.0

    // The level after a second of a loud note and two seconds of it 20 dB quieter
    level_after_decay :: proc(gain: ScopeGain) -> f32 {
        scope := scope_test_init(FREQ)
        defer destroy_scope(&scope)
        scope.gain = gain

        samples: [SCOPE_TEST_FRAME]f32
        for frame in 0 ..< 180 {
            scope_test_sine(samples[:], FREQ, scope.sample_clock)
            if frame >= 60 do for &sample in samples do sample *= 0.1

            sweep_samples(&scope, samples[:])
        }
        return scope.level
    }

    // Auto follows the quieter note down to its peak, hold keeps the loud one's
    auto := level_after_decay(.AUTO)
    testing.expectf(t, auto < 0.15, "auto: level %v", auto)
    held := level_after_decay(.HOLD)
    testing.expectf(t, held > 0.99, "hold: level %v", held)

    // Another note lets the held level go
    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.gain = .HOLD
    samples: [SCOPE_TEST_FRAME]f32
    scope_test_sine(samples[:], FREQ, scope.sample_clock)
    sweep_samples(&scope, samples[:])
    set_scope_freq(&scope, 2 * FREQ)
    testing.expectf(t, scope.level == SCOPE_MIN_LEVEL, "after another note: level %v", scope.level)
}
