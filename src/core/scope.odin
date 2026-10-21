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

    The low-pass of the scope view: two running averages, each over a twelfth of the reference period,
    take out the fine wiggles of the high partials and the hiss and keep the first few partials. Every
    partial is delayed the same, the shape stays, and the beam is drawn as much earlier, so the picture
    doesn't move when it's turned on. It cancels the 12th partial and its multiples exactly, the 3rd keeps
    81% and the 6th 41%. The lamp and its tracks take the wave as it comes.

    X-Y: the reference drives the beam across instead of the sweep, a cosine at its frequency. With the
    wave up and down that's a Lissajous figure, the way pitch was compared on an oscilloscope. An in tune
    note draws a still ellipse, a detuned one rolls it open and shut by the phase it slips, a line, a
    circle, a line the other way. The figure is square, as wide as the screen is high, on its left.

    Circle: the sweep goes round instead of across, the same two reference periods a turn, anticlockwise
    from the top, the wave out from a small ring at its zero and through the middle to the other side. A
    sine draws four petals, every partial more. An in tune note stands still, a detuned one spins by half
    the phase it slips, clockwise when sharp like the wheel. Square like X-Y.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:math"
import "core:slice"


SCOPE_PERIODS :: 2 // reference periods across the screen
SCOPE_FILL :: 0.9 // how much of the height a full scale sample takes
SCOPE_CHUNK_SIZE :: 4096
SCOPE_MAX_BEAM_DOTS :: 256 // between two samples
SCOPE_MAX_FADE_GAIN :: 1e15 // divided back into the cells at this, far under an f32's range, see sweep_samples

// Auto's level is the peak of the last sweep, kept as the peaks of this many blocks of it
SCOPE_SWEEP_BLOCKS :: 16
SCOPE_MIN_LEVEL :: 0.001 // -60 dBFS, digital silence isn't scaled up to the full height
// 26 dB, the level stays this far above the background noise's RMS while there's no note, and lets go of it
// as a note comes out of the noise, see sweep_samples
SCOPE_NOISE_HEADROOM :: 20

// The corner of the AC coupling, the flat top of an A4 square wave sags under 2%, a low E's under 10%
SCOPE_AC_COUPLING_HZ :: 2

// The low-pass's averages are over the reference period over this, the first partial it cancels
SCOPE_LOWPASS_HARMONIC :: #config(SCOPE_LOWPASS_HARMONIC, 12)
SCOPE_LOWPASS_MAX_LENGTH :: 1024 // samples, a twelfth of the period of a 16 Hz note at 192 kHz


// What the screen from above shows of the beam's height
ScopeShape :: enum {
    HALF_RECTIFIED, // the lamp of a strobe, lit by the positive half of the wave
    RAW_WAVEFORM,
    SPLIT, // two lamps, the positive half's over the negative half's, alike on a symmetric wave
}

// What moves the beam across the screen
ScopeSweep :: enum {
    TIME, // two reference periods across, the wave over time
    CIRCLE, // round, a reference period a turn
    XY, // the reference's cosine, a Lissajous figure
}

// The circle's ring at the wave's zero, from its middle to its outside. A full scale sample reaches the
// outside, its trough goes through the middle and as far out on the other side less the ring twice. Small,
// silence is a circle and a note petals through the middle instead of bumps on the ring.
SCOPE_CIRCLE_RING :: 0.2

// How the screen's height follows the input's level
ScopeGain :: enum {
    FILL, // the peak of the last sweep, every note fills the screen until it fades into the noise
    DECAY, // the loudest peak since the reference changed, a fading note shrinks and shows its decay
}

// Two running averages one after the other, see the top of the file
ScopeLowpass :: struct {
    length:  int, // of each average, in samples
    primed:  bool, // the averages hold the input, otherwise they start over filled with the next sample
    oldest:  int, // where in the history the sample leaving the averages is
    history: [2][SCOPE_LOWPASS_MAX_LENGTH]f32,
    sums:    [2]f64,
}


Scope :: struct {
    using node:          AudioCaptureNode,
    freq_hz:             f64,
    sweep:               ScopeSweep,
    gain:                ScopeGain,
    lowpass:             bool, // the scope view's, see the top of the file
    lowpass_filter:      ScopeLowpass,

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
    beam_restart:        bool, // recent is from before a gap, the beam starts over on the next sample
    level:               f32, // peak level of the input

    // Auto's, see follow_sweep_peak
    block_peaks:         [SCOPE_SWEEP_BLOCKS]f32,
    sweep_peak:          f32, // of the blocks
    block_peak:          f32, // of the newest block as far as it came in
    block_samples:       int, // of the newest block, it's done at block_length
    block_length:        int,
    next_block:          int,
    // The RMS of the background noise, the room's hiss stays low on the screen instead of filling it, and
    // how far the input is over it
    noise_floor:         f32,
    snr_db:              f32,
    chunk:               []f32,
    coupling:            [2]f32, // the previous input and output of the AC coupling
    skipping:            bool, // nothing shows the screen, see skip_scope

    // The screen from above, see scope_from_above
    heights:             []f32,
    depths:              []f32,
    dwell:               []f32,

    // Its bins, see scope_partials
    partial_dfts:        []SingleFreqDFT,
    noise_dfts:          [SCOPE_NOISE_BINS]SingleFreqDFT,
}


init_scope :: proc(columns, rows: int, sample_rate: f32 = DEFAULT_SAMPLE_RATE) -> (self: Scope) {
    init_audio_capture_node(&self, sample_rate)
    self.columns = columns
    self.rows = rows
    self.screen = make([]f32, columns * rows)
    self.heights = make([]f32, columns)
    self.depths = make([]f32, columns)
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
    delete(self.depths)
    delete(self.dwell)
    delete(self.chunk)

    for &dft in self.partial_dfts do destroy_dft(&dft)

    delete(self.partial_dfts)
    for &dft in self.noise_dfts do destroy_dft(&dft)
}

// Starts with a dark screen at the new reference frequency. A held level lets go, it's another note.
set_scope_freq :: proc(self: ^Scope, freq_hz: f64) {
    self.freq_hz = freq_hz
    self.step = freq_hz / (f64(self.sample_rate) * SCOPE_PERIODS)

    sweep := 1 / self.step if freq_hz > 0 else 1
    self.block_length = max(int(math.round(sweep / SCOPE_SWEEP_BLOCKS)), 1)

    length := f64(self.sample_rate) / (freq_hz * SCOPE_LOWPASS_HARMONIC) if freq_hz > 0 else 1
    self.lowpass_filter.length = clamp(int(math.round(length)), 1, SCOPE_LOWPASS_MAX_LENGTH)
    self.lowpass_filter.primed = false

    clear_scope(self)
    if self.gain == .DECAY do self.level = SCOPE_MIN_LEVEL
}

// The input opened at another rate, the beam moves across by its samples. It starts over on a dark screen,
// like after a stall.
set_scope_sample_rate :: proc(self: ^Scope, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    self.coupling = {}
    self.beam_restart = true
    set_scope_freq(self, self.freq_hz)
}

// Another input, nothing of the previous one's stays: its picture, its level and the AC coupling's state
reset_scope :: proc(self: ^Scope) {
    clear_scope(self)
    self.coupling = {}
    self.level = 0
    self.block_peaks, self.sweep_peak, self.block_peak = {}, 0, 0
    self.beam_restart = true
}

clear_scope :: proc(self: ^Scope) {
    slice.zero(self.screen)
    self.fade_gain = 1
}

// Starts with a dark screen, the old figure would linger under the new one
set_scope_sweep :: proc(self: ^Scope, sweep: ScopeSweep) {
    self.sweep = sweep
    clear_scope(self)
}

// How many columns of the screen the beam draws in, X-Y and the circle are square
scope_width :: proc(self: ^Scope) -> int {
    return self.columns if self.sweep == .TIME else min(self.rows, self.columns)
}

// Draws what came in since the previous frame
update_scope :: proc(self: ^Scope) {
    self.skipping = false
    if lost := audio_capture_skip_stale(self); lost > 0 {
        // A stall, the beam starts over on the audio after it
        self.sample_clock += lost
        self.coupling = {}
        self.beam_restart = true
        clear_scope(self)
        return
    }

    available := ringbuffer_available(&self.ringbuffer)
    if available == 0 do return

    if self.persistence_seconds <= 0 do clear_scope(self)

    // A one pole highpass, the output follows the changes of the input and lets the steady part go
    pole := f32(math.exp(-math.TAU * SCOPE_AC_COUPLING_HZ / f64(self.sample_rate)))

    for available > 0 {
        count := min(available, len(self.chunk))
        read_ringbuffer(&self.ringbuffer, self.chunk[:count])
        for &sample in self.chunk[:count] {
            input := sample
            sample = input - self.coupling[0] + pole * self.coupling[1]
            self.coupling = {input, sample}
        }

        // Starts over with the beam, and when it's turned on
        if self.beam_restart || !self.lowpass do self.lowpass_filter.primed = false
        if self.lowpass do lowpass_samples(&self.lowpass_filter, self.chunk[:count])

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
    if !self.skipping {
        clear_scope(self)
        self.coupling = {}
        self.beam_restart = true
    }
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
    if self.persistence_seconds > 0 do decay = math.exp(-1 / (self.persistence_seconds * f64(self.sample_rate)))

    // The low-pass's output is the input this many samples before
    clock := self.sample_clock - i64(len(samples))
    if self.lowpass do clock -= i64(self.lowpass_filter.length - 1)

    // Over the noise by the headroom while there's no note, the room's hiss stays small. A note lets go of it
    // as it comes out of the noise, the beam fades in over the same SNR, and a fading note fills the screen
    // until it fades into the noise.
    fade := STROBE_FADE_SNR_DB
    headroom := math.pow(f32(SCOPE_NOISE_HEADROOM), 1 - math.smoothstep(fade[0], fade[1], self.snr_db))
    min_level := max(self.noise_floor * headroom, SCOPE_MIN_LEVEL)

    for sample, index in samples {
        if self.gain == .DECAY {
            self.level = max(abs(sample), self.level, min_level)
        } else {
            self.level = max(follow_sweep_peak(self, abs(sample)), min_level)
        }
        self.fade_gain /= decay

        // Divided back in as soon as it's too large, a chunk long against a short persistence would outgrow
        // the cells before its end
        if self.fade_gain > SCOPE_MAX_FADE_GAIN {
            scale := f32(1 / self.fade_gain)
            for &cell in self.screen do cell *= scale
            self.fade_gain = 1
        }
        move_beam(self, f64(clock + i64(index)) * self.step, sample, self.fade_gain)
    }
}

// The peak of the last sweep, two periods, with the newest sample. A peak decaying back would sag between the
// wave's crests and stretch the rest of the period, this one is the same all through a sweep and lets an
// attack go a sweep later. Kept in blocks, the window is a sweep and up to a block more.
follow_sweep_peak :: proc(self: ^Scope, magnitude: f32) -> f32 {
    self.block_peak = max(self.block_peak, magnitude)
    self.block_samples += 1
    if self.block_samples >= self.block_length {
        self.block_peaks[self.next_block] = self.block_peak
        self.next_block = (self.next_block + 1) % SCOPE_SWEEP_BLOCKS
        self.sweep_peak = slice.max(self.block_peaks[:])
        self.block_peak, self.block_samples = 0, 0
    }
    return max(self.sweep_peak, self.block_peak)
}

// The samples through the low-pass, in place. A running average adds the newest sample to its sum and
// takes the oldest out, as cheap over a long period as over a short one.
lowpass_samples :: proc(self: ^ScopeLowpass, samples: []f32) {
    if self.length <= 1 do return

    for &sample in samples {
        // Filled with the wave where it is, not with a streak up from zero
        if !self.primed {
            for stage in 0 ..< 2 {
                slice.fill(self.history[stage][:self.length], sample)
                self.sums[stage] = f64(sample) * f64(self.length)
            }
            self.oldest = 0
            self.primed = true
        }

        for stage in 0 ..< 2 {
            self.sums[stage] += f64(sample) - f64(self.history[stage][self.oldest])
            self.history[stage][self.oldest] = sample
            sample = f32(self.sums[stage] / f64(self.length))
        }
        self.oldest = (self.oldest + 1) % self.length
    }
}

// The smooth curve through four points between the two in the middle (Catmull-Rom), of values or of
// positions. progress is 0 at from and 1 at to, the points before and after set the curve's direction there.
catmull_rom :: proc(before, from, to, after: $T, progress: f32) -> T {
    slope := to - before
    bend := 2 * before - 5 * from + 4 * to - after
    twist := 3 * from - before - 3 * to + after
    return 0.5 * (2 * from + slope * progress + bend * progress * progress + twist * progress * progress * progress)
}

// The beam moves on from the sample before the previous one to the previous one, a curve through them
// needs the newest one too. It leaves a dot in every cell on the way, all as long a time apart, so it's
// dimmer where it moves fast. position is the newest sample's.
move_beam :: proc(self: ^Scope, position: f64, sample: f32, brightness: f64) {
    // After a gap the beam starts where the wave is, not with a streak from where it was
    if self.beam_restart {
        self.recent = sample
        self.beam_restart = false
    }

    before, from, to, after := self.recent[0], self.recent[1], self.recent[2], sample
    self.recent = {from, to, after}

    columns := self.step * f64(self.columns)

    // The cosine moves the beam fastest through the middle, and the circle on its outside
    radius := 0.5 * SCOPE_FILL * f64(scope_width(self))
    if self.sweep == .XY do columns = math.TAU * SCOPE_PERIODS * self.step * radius
    if self.sweep == .CIRCLE do columns = math.TAU * self.step * radius

    rows := f64(abs(to - from) / self.level) * 0.5 * SCOPE_FILL * f64(self.rows)
    dots := clamp(int(math.ceil(max(columns, rows))), 1, SCOPE_MAX_BEAM_DOTS)

    from_position := position - 2 * self.step
    for dot in 0 ..< dots {
        progress := (f32(dot) + 0.5) / f32(dots)
        value := catmull_rom(before, from, to, after, progress)
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

    // Round from the top, anticlockwise with the screen's rows running down. A radius under zero is on the
    // other side of the middle.
    if self.sweep == .CIRCLE {
        angle := math.TAU * position
        radius := 0.5 * SCOPE_FILL * (SCOPE_CIRCLE_RING + (1 - SCOPE_CIRCLE_RING) * height)
        x = (0.5 - radius * math.sin(angle)) * f64(scope_width(self)) - 0.5
        y = (0.5 - radius * math.cos(angle)) * f64(self.rows) - 0.5
    }

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
// depths are the negative half's the same way, 1 is the trough, for the split lamp.
scope_from_above :: proc(self: ^Scope, shape: ScopeShape) -> (heights: []f32, dwell: []f32) {
    // The wave's value at the middle of a row, 1 is the peak level
    row_value :: proc(self: ^Scope, row: int) -> f32 {
        return (0.5 - (f32(row) + 0.5) / f32(self.rows)) / (0.5 * SCOPE_FILL)
    }

    slice.zero(self.heights)
    slice.zero(self.depths)
    slice.zero(self.dwell)

    // Row by row, the row's value once for all of its cells
    for row in 0 ..< self.rows {
        value := row_value(self, row)
        depth := max(-value, 0)
        if shape != .RAW_WAVEFORM do value = max(value, 0)

        for cell, column in self.screen[row * self.columns:][:self.columns] {
            if cell == 0 do continue

            self.heights[column] += cell * value
            self.depths[column] += cell * depth
            self.dwell[column] += cell
        }
    }

    for column in 0 ..< self.columns {
        if self.dwell[column] == 0 do continue

        self.heights[column] /= self.dwell[column]
        self.depths[column] /= self.dwell[column]
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
