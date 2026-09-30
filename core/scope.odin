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


/* ------------------------------------------------------------------------------------------------

    Scope

    An oscilloscope with its sweep synced to the reference period and a screen that remembers.

    The sweep: a sample's place across the screen is its index on the sample clock times the reference
    frequency, only the fraction. It starts over every couple of reference periods, so an in tune note
    is drawn over itself and stands still, a detuned one drifts sideways by the phase it slips. This is
    the fractional frame counter of the framerate method (app/deprecated/framerate.odin, removed in
    f1912e9), worked out for every sample instead of once per read.

    The screen: cells that keep how long the beam stayed in them and fade, like phosphor. A slow drift
    stays sharp and a fast one smears, which is what the eye does with a real one.

    The views draw what they're given: the screen as it is, or the screen from above (scope_from_above),
    the height of the beam in each column as a brightness. That's the classic strobe, stripes that wash
    out to gray when the beam smears.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:math"
import "core:testing"


SCOPE_PERIODS :: 2 // reference periods across the screen
SCOPE_FILL :: 0.9 // how much of the height a full scale sample takes
SCOPE_CHUNK_SIZE :: 4096
SCOPE_MAX_BEAM_DOTS :: 256 // between two samples

// The level follows the peaks at once and falls back this slowly, the wave is drawn against it
SCOPE_LEVEL_RELEASE_SECONDS :: 1.0
SCOPE_MIN_LEVEL :: 0.001 // -60 dBFS, digital silence isn't scaled up to the full height
SCOPE_NOISE_HEADROOM :: 20 // 26 dB, the level stays this far above the background noise's RMS


// What the screen from above shows of the beam's height
ScopeShape :: enum {
    HALF_RECTIFIED, // the lamp of a strobe, lit by the positive half of the wave
    RAW_WAVEFORM,
}

half_rectify :: proc(value: f32) -> f32 {
    return max(value, 0)
}

raw_waveform :: proc(value: f32) -> f32 {
    return value
}


Scope :: struct {
    using node:          AudioCaptureNode,
    samplerate:          f64,
    freq_hz:             f64,

    // How long the beam stays on the screen, the time constant of its decay. 0 keeps only what came
    // in since the previous frame.
    persistence_seconds: f64,

    // Absolute index of the next sample
    sample_clock:        i64,
    step:                f64, // how far across the screen one sample moves, 0..1

    // How long the beam stayed in each cell, row 0 on top
    screen:              []f32,
    columns:             int,
    rows:                int,
    recent:              [3]f32, // the samples before the newest, the beam is drawn through them
    level:               f32, // peak level of the input
    // The RMS of the background noise, the room's hiss stays low on the screen instead of filling it
    noise_floor:         f32,
    chunk:               []f32,

    // The screen from above, see scope_from_above
    heights:             []f32,
    dwell:               []f32,
}


init_scope :: proc(samplerate: f64, columns, rows: int) -> (self: Scope) {
    init_audio_capture_node(&self, "scope")
    self.samplerate = samplerate
    self.columns = columns
    self.rows = rows
    self.screen = make([]f32, columns * rows)
    self.heights = make([]f32, columns)
    self.dwell = make([]f32, columns)
    self.chunk = make([]f32, SCOPE_CHUNK_SIZE)
    self.level = SCOPE_MIN_LEVEL
    return
}

destroy_scope :: proc(self: ^Scope) {
    destroy_audio_capture_node(self)
    delete(self.screen)
    delete(self.heights)
    delete(self.dwell)
    delete(self.chunk)
}

// Starts with a dark screen at the new reference frequency
set_scope_freq :: proc(self: ^Scope, freq_hz: f64) {
    self.freq_hz = freq_hz
    self.step = freq_hz / (self.samplerate * SCOPE_PERIODS)
    clear_scope(self)
}

clear_scope :: proc(self: ^Scope) {
    for &cell in self.screen do cell = 0
}

// Draws what came in since the previous frame
update_scope :: proc(self: ^Scope) {
    available := int(frames_available_in_ringbuffer(&self.ringbuffer))
    if available == 0 do return

    if self.persistence_seconds <= 0 do clear_scope(self)

    for available > 0 {
        count := min(available, len(self.chunk))
        read_ringbuffer(&self.ringbuffer, self.chunk, u32(count))
        sweep_samples(self, self.chunk[:count])
        available -= count
    }
}

// Draws the samples over what is on the screen, which fades by the persistence
sweep_samples :: proc(self: ^Scope, samples: []f32) {
    self.sample_clock += i64(len(samples))
    if self.step <= 0 || len(samples) == 0 do return

    // Of one sample, the older samples of the same chunk have faded by it too
    decay: f64 = 1
    if self.persistence_seconds > 0 {
        decay = math.exp(-1 / (self.persistence_seconds * self.samplerate))
        fade := f32(math.pow(decay, f64(len(samples))))
        for &cell in self.screen do cell *= fade
    }

    release := f32(math.exp(-1 / (SCOPE_LEVEL_RELEASE_SECONDS * self.samplerate)))
    clock := self.sample_clock - i64(len(samples))
    brightness := math.pow(decay, f64(len(samples) - 1))
    min_level := max(self.noise_floor * SCOPE_NOISE_HEADROOM, SCOPE_MIN_LEVEL)

    for sample, i in samples {
        self.level = max(abs(sample), self.level * release, min_level)
        move_beam(self, f64(clock + i64(i)) * self.step, sample, brightness)
        brightness /= decay
    }
}

// The beam moves on from the sample before the previous one to the previous one, a curve through them
// needs the newest one too (Catmull-Rom). It leaves a dot in every cell on the way, all as long a time
// apart, so it's dimmer where it moves fast. position is the newest sample's.
move_beam :: proc(self: ^Scope, position: f64, sample: f32, brightness: f64) {
    // The smooth curve through four samples, between the two in the middle. progress is 0 at from and 1
    // at to, the samples before and after set the curve's direction there.
    curve_between :: proc(before, from, to, after: f32, progress: f32) -> f32 {
        slope := to - before
        bend := 2 * before - 5 * from + 4 * to - after
        twist := 3 * from - before - 3 * to + after
        return 0.5 * (2 * from + slope * progress + bend * progress * progress + twist * progress * progress * progress)
    }

    before, from, to, after := self.recent[0], self.recent[1], self.recent[2], sample
    self.recent = {from, to, after}

    columns := self.step * f64(self.columns)
    rows := f64(abs(to - from) / self.level) * 0.5 * SCOPE_FILL * f64(self.rows)
    dots := clamp(int(math.ceil(max(columns, rows))), 1, SCOPE_MAX_BEAM_DOTS)

    from_position := position - 2 * self.step
    for dot in 0 ..< dots {
        progress := (f32(dot) + 0.5) / f32(dots)
        value := curve_between(before, from, to, after, progress)
        beam_dot(self, from_position + f64(progress) * self.step, value, brightness / f64(dots))
    }
}

// A dot of the beam. It falls between the cells, the two columns and the two rows around it share it
// by how near they are.
beam_dot :: proc(self: ^Scope, position: f64, value: f32, brightness: f64) {
    // The columns wrap around, the sweep starts over on the left. There's nothing above and below the screen.
    light_cell :: proc(self: ^Scope, column, row: int, brightness: f64) {
        if row < 0 || row >= self.rows do return
        self.screen[row * self.columns + column %% self.columns] += f32(brightness)
    }

    across := position - math.floor(position)
    height := f64(clamp(value / self.level, -1, 1))

    // In cells, from the middle of the first column and of the top row
    x := across * f64(self.columns) - 0.5
    y := (0.5 - 0.5 * SCOPE_FILL * height) * f64(self.rows) - 0.5

    left := int(math.floor(x))
    top := int(math.floor(y))
    right_share := x - f64(left)
    bottom_share := y - f64(top)

    light_cell(self, left, top, brightness * (1 - right_share) * (1 - bottom_share))
    light_cell(self, left + 1, top, brightness * right_share * (1 - bottom_share))
    light_cell(self, left, top + 1, brightness * (1 - right_share) * bottom_share)
    light_cell(self, left + 1, top + 1, brightness * right_share * bottom_share)
}

// The screen from above: for every column the height of the beam, averaged over how long it stayed at
// each height, 1 is the peak level. A steady beam gives its height, a smeared one the middle of the smear.
// dwell is how long the beam stayed in the column at all, 0 for a dark one, which has no height.
scope_from_above :: proc(self: ^Scope, shape: ScopeShape) -> (heights: []f32, dwell: []f32) {
    // The wave's value at the middle of a row, 1 is the peak level
    row_value :: proc(self: ^Scope, row: int) -> f32 {
        return (0.5 - (f32(row) + 0.5) / f32(self.rows)) / (0.5 * SCOPE_FILL)
    }

    for &height in self.heights do height = 0
    for &time in self.dwell do time = 0

    for cell, i in self.screen {
        if cell == 0 do continue
        value := row_value(self, i / self.columns)
        if shape == .HALF_RECTIFIED do value = half_rectify(value)
        else do value = raw_waveform(value)

        column := i % self.columns
        self.heights[column] += cell * value
        self.dwell[column] += cell
    }

    for &height, column in self.heights {
        if self.dwell[column] > 0 do height /= self.dwell[column]
    }
    return self.heights, self.dwell
}


// The phase and amplitude of the reference frequency in the screen from above
scope_test_fundamental :: proc(heights: []f32) -> (phase: f64, amp: f64) {
    sum: complex128
    for height, i in heights {
        angle := math.TAU * SCOPE_PERIODS * (f64(i) + 0.5) / f64(len(heights))
        sum += complex(f64(height), 0) * complex(math.cos(angle), -math.sin(angle))
    }
    // a sine at phase 0 comes out at -90°
    return wrap_phase(math.atan2(imag(sum), real(sum)) + math.PI / 2), 2 * abs(sum) / f64(len(heights))
}

scope_test_sine :: proc(samples: []f32, freq_hz: f64, samplerate: f64, clock: i64) {
    for &sample, i in samples {
        sample = f32(math.sin(math.TAU * freq_hz * f64(clock + i64(i)) / samplerate))
    }
}

SCOPE_TEST_SAMPLERATE :: 48_000
SCOPE_TEST_FRAME :: SCOPE_TEST_SAMPLERATE / 60

// The screen of the scope display type
scope_test_init :: proc(freq_hz: f64) -> Scope {
    scope := init_scope(SCOPE_TEST_SAMPLERATE, 488, 240)
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
        scope_test_sine(samples[:], FREQ, SCOPE_TEST_SAMPLERATE, scope.sample_clock)
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
        scope_test_sine(samples[:], FREQ + OFF_HZ, SCOPE_TEST_SAMPLERATE, scope.sample_clock)
        clear_scope(&scope)
        sweep_samples(&scope, samples[:])
        heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
        phase, _ := scope_test_fundamental(heights)
        middle_s := (f64(scope.sample_clock) - SCOPE_TEST_FRAME / 2) / SCOPE_TEST_SAMPLERATE
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
    scope_test_sine(samples[:], FREQ + 30, SCOPE_TEST_SAMPLERATE, 0)
    sweep_samples(&scope, samples[:])
    heights, _ := scope_from_above(&scope, .RAW_WAVEFORM)
    _, amp := scope_test_fundamental(heights)
    testing.expectf(t, abs(amp - 0.637) < 0.03, "amp %v", amp)

    // A full turn, nothing is left
    set_scope_freq(&scope, FREQ)
    scope_test_sine(samples[:], FREQ + 60, SCOPE_TEST_SAMPLERATE, 0)
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
    scope_test_sine(samples[:], FREQ, SCOPE_TEST_SAMPLERATE, 0)
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
        scope_test_sine(samples[:], FREQ, SCOPE_TEST_SAMPLERATE, scope.sample_clock)
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
        scope_test_sine(samples[:], FREQ, SCOPE_TEST_SAMPLERATE, scope.sample_clock)
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
