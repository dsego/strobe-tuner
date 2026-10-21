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
test_scope_circle_spins_clockwise_when_sharp :: proc(t: ^testing.T) {
    // 8 periods a frame, four turns, a part of the petals drawn twice would pull them its way
    FREQ :: 480.0
    OFF_HZ :: 1.0

    // Which way the petals point out of the ring, twice the angle anticlockwise on the screen from the
    // right. A sine's two petals are half a turn apart, at twice their angle they point the same way.
    petals_angle :: proc(scope: ^Scope) -> f64 {
        width := scope_width(scope)
        ring := 0.5 * SCOPE_FILL * SCOPE_CIRCLE_RING * f64(width)
        petals: [2]f64
        for cell, i in scope.screen {
            if cell == 0 do continue

            x := f64(i % scope.columns) + 0.5 - 0.5 * f64(width)
            y := f64(i / scope.columns) + 0.5 - 0.5 * f64(scope.rows)
            radius := math.sqrt(x * x + y * y)
            angle := math.atan2(-y, x)
            petals += f64(cell) * (radius - ring) * [2]f64{math.cos(2 * angle), math.sin(2 * angle)}
        }
        return math.atan2(petals.y, petals.x)
    }

    sweep_frame :: proc(scope: ^Scope, freq_hz: f64) {
        samples: [SCOPE_TEST_FRAME]f32
        scope_test_sine(samples[:], freq_hz, scope.sample_clock)
        clear_scope(scope)
        sweep_samples(scope, samples[:])
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

    // The level after a second of a loud note and three frames, 11 periods, of it 20 dB quieter
    level_after_decay :: proc(gain: ScopeGain) -> f32 {
        scope := scope_test_init(FREQ)
        defer destroy_scope(&scope)
        scope.gain = gain

        samples: [SCOPE_TEST_FRAME]f32
        for frame in 0 ..< 63 {
            scope_test_sine(samples[:], FREQ, scope.sample_clock)
            if frame >= 60 do for &sample in samples do sample *= 0.1

            sweep_samples(&scope, samples[:])
        }
        return scope.level
    }

    // Fill is at the quieter note's peak a sweep later, decay keeps the loud one's
    filled := level_after_decay(.FILL)
    testing.expectf(t, abs(filled - 0.1) < 0.002, "fill: level %v", filled)
    decayed := level_after_decay(.DECAY)
    testing.expectf(t, decayed > 0.99, "decay: level %v", decayed)

    // Another note lets the loudest peak go
    scope := scope_test_init(FREQ)
    defer destroy_scope(&scope)
    scope.gain = .DECAY
    samples: [SCOPE_TEST_FRAME]f32
    scope_test_sine(samples[:], FREQ, scope.sample_clock)
    sweep_samples(&scope, samples[:])
    set_scope_freq(&scope, 2 * FREQ)
    testing.expectf(t, scope.level == SCOPE_MIN_LEVEL, "after another note: level %v", scope.level)
}
