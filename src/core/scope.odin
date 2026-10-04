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
    is drawn over itself and stands still, a detuned one drifts sideways by the phase it slips.

    The screen: cells that keep how long the beam stayed in them and fade, like phosphor. A slow drift
    stays sharp and a fast one smears, which is what the eye does with a real one.

    The views draw what they're given: the screen as it is, or the screen from above (scope_from_above),
    the height of the beam in each column as a brightness. That's the classic strobe, stripes that wash
    out to gray when the beam smears.

    The input as it comes, a highpass would shift the fundamental against the harmonics, tilt the flat
    top of a square wave and bend a sawtooth. Only the DC is taken out, like the AC coupling of an
    oscilloscope.

    X-Y: the reference drives the beam across instead of the sweep, a cosine at its frequency. With the
    wave up and down that's a Lissajous figure, the way pitch was compared on an oscilloscope. An in tune
    note draws a still ellipse, a detuned one rolls it open and shut by the phase it slips, a line, a
    circle, a line the other way. The figure is square, as wide as the screen is high, on its left.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:math"
import "core:testing"


SCOPE_PERIODS :: 2 // reference periods across the screen
SCOPE_FILL :: 0.9 // how much of the height a full scale sample takes
SCOPE_CHUNK_SIZE :: 4096
SCOPE_MAX_BEAM_DOTS :: 256 // between two samples
SCOPE_MAX_FADE_GAIN :: 1e15 // divided back into the cells at this, far under an f32's range, see sweep_samples

// The level follows the peaks at once and falls back this slowly, the wave is drawn against it
SCOPE_LEVEL_RELEASE_SECONDS :: 1.0
SCOPE_MIN_LEVEL :: 0.001 // -60 dBFS, digital silence isn't scaled up to the full height
SCOPE_NOISE_HEADROOM :: 20 // 26 dB, the level stays this far above the background noise's RMS

// The corner of the AC coupling, the flat top of an A4 square wave sags under 2%, a low E's under 10%
SCOPE_AC_COUPLING_HZ :: 2


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

// What moves the beam across the screen
ScopeSweep :: enum {
    TIME, // two reference periods across, the wave over time
    XY, // the reference's cosine, a Lissajous figure
}

// How the screen's height follows the input's level
ScopeGain :: enum {
    AUTO, // the peak, falling back over SCOPE_LEVEL_RELEASE_SECONDS, a fading note still fills the screen
    HOLD, // the loudest peak since the reference changed, a fading note shrinks and shows its decay
}


Scope :: struct {
    using node:          AudioCaptureNode,
    freq_hz:             f64,
    sweep:               ScopeSweep,
    gain:                ScopeGain,

    // How long the beam stays on the screen, the time constant of its decay. 0 keeps only what came
    // in since the previous frame.
    persistence_seconds: f64,

    // Absolute index of the next sample
    sample_clock:        i64,
    step:                f64, // how far across the screen one sample moves, 0..1

    // How long the beam stayed in each cell, row 0 on top, scaled up by fade_gain, see sweep_samples
    screen:              []f32,
    fade_gain:           f64,
    columns:             int,
    rows:                int,
    recent:              [3]f32, // the samples before the newest, the beam is drawn through them
    level:               f32, // peak level of the input
    // The RMS of the background noise, the room's hiss stays low on the screen instead of filling it
    noise_floor:         f32,
    chunk:               []f32,
    coupling:            [2]f32, // the previous input and output of the AC coupling
    skipping:            bool, // nothing shows the screen, see skip_scope

    // The screen from above, see scope_from_above
    heights:             []f32,
    dwell:               []f32,

    // Its bins, see scope_partials
    partial_dfts:        []SingleFreqDFT,
    noise_dfts:          [SCOPE_NOISE_BINS]SingleFreqDFT,
}


init_scope :: proc(columns, rows: int) -> (self: Scope) {
    init_audio_capture_node(&self, "scope")
    self.columns = columns
    self.rows = rows
    self.screen = make([]f32, columns * rows)
    self.heights = make([]f32, columns)
    self.dwell = make([]f32, columns)
    self.chunk = make([]f32, SCOPE_CHUNK_SIZE)
    self.level = SCOPE_MIN_LEVEL
    self.fade_gain = 1

    for &dft, index in self.noise_dfts {
        set_dft_freq(&dft, f32(2 * index + 1) / f32(columns), flat_window(columns))
    }
    return
}

destroy_scope :: proc(self: ^Scope) {
    destroy_audio_capture_node(self)
    delete(self.screen)
    delete(self.heights)
    delete(self.dwell)
    delete(self.chunk)

    for &dft in self.partial_dfts do destroy_dft(&dft)

    delete(self.partial_dfts)
    for &dft in self.noise_dfts do destroy_dft(&dft)
}

// Starts with a dark screen at the new reference frequency. A held level lets go, it's another note.
set_scope_freq :: proc(self: ^Scope, freq_hz: f64) {
    self.freq_hz = freq_hz
    self.step = freq_hz / (SAMPLERATE * SCOPE_PERIODS)
    clear_scope(self)
    if self.gain == .HOLD do self.level = SCOPE_MIN_LEVEL
}

clear_scope :: proc(self: ^Scope) {
    for &cell in self.screen do cell = 0
    self.fade_gain = 1
}

// Starts with a dark screen, the old figure would linger under the new one
set_scope_sweep :: proc(self: ^Scope, sweep: ScopeSweep) {
    self.sweep = sweep
    clear_scope(self)
}

// How many columns of the screen the beam draws in, X-Y is square
scope_width :: proc(self: ^Scope) -> int {
    return min(self.rows, self.columns) if self.sweep == .XY else self.columns
}

// Draws what came in since the previous frame
update_scope :: proc(self: ^Scope) {
    self.skipping = false
    if lost := audio_capture_skip_stale(self); lost > 0 {
        // A stall, the beam starts over on the audio after it
        self.sample_clock += lost
        self.coupling = {}
        clear_scope(self)
        return
    }

    available := int(ringbuffer_available(&self.ringbuffer))
    if available == 0 do return

    if self.persistence_seconds <= 0 do clear_scope(self)

    // A one pole highpass, the output follows the changes of the input and lets the steady part go
    pole := f32(math.exp(f64(-math.TAU * SCOPE_AC_COUPLING_HZ / SAMPLERATE)))

    for available > 0 {
        count := min(available, len(self.chunk))
        read_ringbuffer(&self.ringbuffer, self.chunk[:count])
        for &sample in self.chunk[:count] {
            input := sample
            sample = input - self.coupling[0] + pole * self.coupling[1]
            self.coupling = {input, sample}
        }
        sweep_samples(self, self.chunk[:count])
        available -= count
    }
}

// Instead of update_scope while nothing shows the screen, drawing the beam costs more than the strobe's
// measurements. What came in is dropped, the clock runs on and the screen goes dark, it starts over when
// it shows again.
skip_scope :: proc(self: ^Scope) {
    self.sample_clock += audio_capture_skip_stale(self)
    available := ringbuffer_available(&self.ringbuffer)
    skip_ringbuffer(&self.ringbuffer, available)
    self.sample_clock += i64(available)
    if !self.skipping do clear_scope(self)

    self.skipping = true
}

// Draws the samples over what is on the screen, which fades by the persistence. Instead of fading every cell
// for every sample, the new light is scaled up as much as the old would have faded since: fade_gain grows
// by 1 / decay a sample and the cells hold their light times it. The screen's readers take ratios of cells,
// where it cancels out. Before it outgrows the cells it's divided back into them.
sweep_samples :: proc(self: ^Scope, samples: []f32) {
    self.sample_clock += i64(len(samples))
    if self.step <= 0 || len(samples) == 0 do return

    // Of one sample
    decay: f64 = 1
    if self.persistence_seconds > 0 do decay = math.exp(-1 / (self.persistence_seconds * SAMPLERATE))

    release: f32 = 1 if self.gain == .HOLD else f32(math.exp(f64(-1 / (SCOPE_LEVEL_RELEASE_SECONDS * SAMPLERATE))))
    clock := self.sample_clock - i64(len(samples))
    min_level := max(self.noise_floor * SCOPE_NOISE_HEADROOM, SCOPE_MIN_LEVEL)

    for sample, i in samples {
        self.level = max(abs(sample), self.level * release, min_level)
        self.fade_gain /= decay
        move_beam(self, f64(clock + i64(i)) * self.step, sample, self.fade_gain)
    }

    if self.fade_gain > SCOPE_MAX_FADE_GAIN {
        scale := f32(1 / self.fade_gain)
        for &cell in self.screen do cell *= scale
        self.fade_gain = 1
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

    // The cosine moves the beam fastest through the middle
    if self.sweep == .XY do columns = math.TAU * SCOPE_PERIODS * self.step * 0.5 * SCOPE_FILL * f64(scope_width(self))

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

    // The reference at the sample, a cosine with the same reach as the wave
    if self.sweep == .XY do across = 0.5 + 0.5 * SCOPE_FILL * math.cos(math.TAU * SCOPE_PERIODS * position)

    height := f64(clamp(value / self.level, -1, 1))

    // In cells, from the middle of the first column and of the top row
    x := across * f64(scope_width(self)) - 0.5
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


// Partials on the screen, each a DFT bin of the wave from above, the sine with as many periods across
// the screen, SCOPE_PERIODS times the partial. And the noise in the bins halfway between the harmonics of
// the reference, nothing locked to it lands there.
ScopePartial :: struct {
    phase: f64, // radians of the partial, the screen's left edge is 0
    level: f64, // 1 is the peak level
}

SCOPE_NOISE_BINS :: 32 // of the halfway bins, from the bottom

scope_partials :: proc(self: ^Scope, periods: []int, partials: []ScopePartial) -> (noise: f64) {
    // Retuned when the periods asked for change
    if len(self.partial_dfts) != len(periods) {
        for &dft in self.partial_dfts do destroy_dft(&dft)

        delete(self.partial_dfts)
        self.partial_dfts = make([]SingleFreqDFT, len(periods))
    }
    for &dft, index in self.partial_dfts {
        norm_freq := f32(periods[index]) / f32(self.columns)
        if dft.norm_freq != norm_freq do set_dft_freq(&dft, norm_freq, flat_window(self.columns))
    }

    // The wave as it is, half rectified it would have harmonics of its own
    heights, _ := scope_from_above(self, .RAW_WAVEFORM)

    for &partial, index in partials {
        bin := scope_bin(&self.partial_dfts[index], heights)
        partial = {math.atan2(imag(bin), real(bin)), abs(bin)}
    }

    power: f64 = 0
    for &dft in self.noise_dfts {
        bin := scope_bin(&dft, heights)
        power += real(bin) * real(bin) + imag(bin) * imag(bin)
    }
    return math.sqrt(power / SCOPE_NOISE_BINS)
}

// A bin of the screen from above, a sine's peak level and its phase at the screen's left edge. A dark
// column counts as zero, it's a part of the sweep the beam hasn't been to. The DFT counts a column from
// its left edge, its height is the middle of it, half a column later.
scope_bin :: proc(dft: ^SingleFreqDFT, heights: []f32) -> complex128 {
    half_column := math.PI * f64(dft.norm_freq)
    return 2 * complex128(run_single_dft(dft, heights)) * complex(math.cos(half_column), -math.sin(half_column))
}


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
        sample = f32(math.sin(math.TAU * freq_hz * f64(clock + i64(i)) / SAMPLERATE))
    }
}

SCOPE_TEST_FRAME :: SAMPLERATE / 60

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
        middle_s := (f64(scope.sample_clock) - SCOPE_TEST_FRAME / 2) / SAMPLERATE
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
