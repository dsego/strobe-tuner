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
    stays sharp and a fast one smears, which is what the eye does with a real one. Without persistence
    the screen is the newest sweep, drawn over again every frame from the samples kept back to a sweep
    ago, whole at every note. The same sweep is also there as a line through the samples, scope_trace,
    for a solid beam drawn as such instead of through the cells, which would light up the middle of the
    circle where the sweep goes round slowly. With persistence the scope view averages the sweeps over it
    instead of fading them, an oscilloscope's averaging with the reference for its trigger, and the line is
    the average: the noise cancels out, faded on the screen it showed as a bundle of strands. A still line
    in the cells shows their steps.

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
    from the top, the wave out from a ring halfway at its zero, its crests to the outside and its troughs
    in to the middle. A sine draws two lobes that meet in the middle, every partial bumps and dips them.
    It's the line over time bent round, narrower the nearer the middle. An in tune note stands still, a
    detuned one spins by half the phase it slips, clockwise when sharp like the wheel. Square like X-Y,
    the crests reach out past the square to the screen's sides.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:math"
import "core:slice"


SCOPE_PERIODS :: 2 // reference periods across the screen
SCOPE_FILL :: 0.9 // how much of the height a full scale sample takes
SCOPE_CHUNK_SIZE :: 4096
SCOPE_MAX_BEAM_DOTS :: 256 // between two samples
SCOPE_MAX_FADE_GAIN :: 1e15 // divided back into the cells at this, far under an f32's range, see sweep_samples
SCOPE_SWEEP_MAX_SAMPLES :: 24576 // kept for the newest sweep, two periods of a 16 Hz note at 192 kHz
SCOPE_CURVE_SAMPLES :: 3 // the beam's curve to a sample runs through this many before it, see move_beam

// Fill's peak is held over at least this many periods, Medium's: scaled to one sweep's own peak the picture
// would shake as the partials beat against each other, see follow_screen_peak
SCOPE_FILL_MIN_PERIODS :: 18
// and its level glides down to a lower peak over this, a step would jump the picture, see follow_level
SCOPE_FILL_RELEASE_S :: #config(SCOPE_FILL_RELEASE_S, 0.06)

// The averaged scope's scale is set over this many periods after a note starts and then held, see
// autoset_scope
SCOPE_AUTOSET_PERIODS :: #config(SCOPE_AUTOSET_PERIODS, 18)
// A note louder than the scale was set to runs off the screen up to this many times the full height, further
// off it isn't seen anyway
SCOPE_MAX_OVERSHOOT :: 2

// Fill's level is the peak of what the screen shows, kept as the peaks of this many blocks of it
SCOPE_PEAK_BLOCKS :: 16
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
    CIRCLE, // round, two reference periods a turn
    XY, // the reference's cosine, a Lissajous figure
}

// The circle's ring at the wave's zero, from its middle to its outside. Halfway, a full scale sample reaches
// the outside and its trough the middle, the wave dips in to it and never through to the other side, where
// every period's would cross and light it up. Silence is a circle.
SCOPE_CIRCLE_RING :: 0.5
// The radius of a full scale sample, of the square's side. Past its edge, the ring at rest fills the
// screen's width more and the crests reach out to its sides.
SCOPE_CIRCLE_REACH :: 0.7

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
    lowpass:             bool, // the scope view's, see the top of the file
    lowpass_filter:      ScopeLowpass,

    // How long the beam stays on the screen, the time constant of its decay. 0 keeps the newest sweep
    // only, drawn over again every frame, see redraw_newest_sweep.
    persistence_seconds: f64,

    // Absolute index of the next sample
    sample_clock:        i64,
    step:                f64, // how far across the screen one sample moves, 0..1

    // How long the beam stayed in each cell, row 0 on top, scaled up by fade_gain, see sweep_samples
    screen:              []f32,
    fade_gain:           f64,
    // The newest samples as they're drawn, a ring, for the newest sweep without persistence and the trace
    history:             []f32,
    history_next:        int, // where the next sample goes
    history_count:       int, // how many are kept, up to the ring's length
    // The sweeps averaged over the persistence for the trace, nothing is drawn on the screen, see
    // average_samples. A bin as wide as a sample moves, the sum of the samples there and of their weights,
    // scaled up by average_gain like the screen's cells by fade_gain.
    average_sweeps:      bool,
    average_sums:        []f32,
    average_weights:     []f32,
    average_bins:        int,
    average_gain:        f64,
    averaged_clock:      i64, // the samples before it are in the average, see average_samples
    averaged_sweep:      i64, // the one the newest of them is in
    autoset_samples:     i64, // left until the averaged scope's scale is held, see autoset_scope
    columns:             int,
    rows:                int,
    recent:              [3]f32, // the samples before the newest, the beam is drawn through them
    beam_restart:        bool, // recent is from before a gap, the beam starts over on the next sample
    level:               f32, // peak level of the input
    fill_release:        f32, // what Fill's level glides down by a sample, see follow_level

    // Fill's, see follow_screen_peak
    block_peaks:         [SCOPE_PEAK_BLOCKS]f32,
    screen_peaks:        [2]f32, // of the blocks, the highest and the highest but one
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
    self.history = make([]f32, SCOPE_SWEEP_MAX_SAMPLES)
    self.average_sums = make([]f32, SCOPE_SWEEP_MAX_SAMPLES)
    self.average_weights = make([]f32, SCOPE_SWEEP_MAX_SAMPLES)
    self.level = SCOPE_MIN_LEVEL
    self.fade_gain = 1
    self.average_gain = 1

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
    delete(self.history)
    delete(self.average_sums)
    delete(self.average_weights)

    for &dft in self.partial_dfts do destroy_dft(&dft)

    delete(self.partial_dfts)
    for &dft in self.noise_dfts do destroy_dft(&dft)
}

// Starts with a dark screen at the new reference frequency
set_scope_freq :: proc(self: ^Scope, freq_hz: f64) {
    self.freq_hz = freq_hz
    self.step = freq_hz / (f64(self.sample_rate) * SCOPE_PERIODS)

    length := f64(self.sample_rate) / (freq_hz * SCOPE_LOWPASS_HARMONIC) if freq_hz > 0 else 1
    self.lowpass_filter.length = clamp(int(math.round(length)), 1, SCOPE_LOWPASS_MAX_LENGTH)
    self.lowpass_filter.primed = false

    self.average_bins = clamp(int(1 / self.step) if self.step > 0 else 1, SCOPE_CURVE_SAMPLES + 1, SCOPE_SWEEP_MAX_SAMPLES)

    clear_scope(self)
    autoset_scope(self)
}

// A note started, a pluck or another note: the averaged scope's scale follows the average's peak for
// SCOPE_AUTOSET_PERIODS and is then held like an oscilloscope's after its Autoset, until the next one. The
// note decays on the screen and shrinks into the noise, nothing scales its weak tail up. The click of the
// pluck is short and doesn't repeat, by the window's end the average has let go of it.
autoset_scope :: proc(self: ^Scope) {
    if self.freq_hz <= 0 do return

    self.autoset_samples = i64(SCOPE_AUTOSET_PERIODS / self.freq_hz * f64(self.sample_rate))
}

// The input opened at another rate, the beam moves across by its samples. It starts over on a dark screen,
// like after a stall.
set_scope_sample_rate :: proc(self: ^Scope, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    restart_beam(self)
    set_scope_freq(self, self.freq_hz)
}

// Another input, nothing of the previous one's stays: its picture, its level and the AC coupling's state
reset_scope :: proc(self: ^Scope) {
    clear_scope(self)
    restart_beam(self)
    self.level = 0
    self.block_peaks, self.screen_peaks, self.block_peak = {}, {}, 0
}

// The screen and the average
clear_scope :: proc(self: ^Scope) {
    clear_screen(self)
    slice.zero(self.average_sums[:self.average_bins])
    slice.zero(self.average_weights[:self.average_bins])
    self.average_gain = 1
}

clear_screen :: proc(self: ^Scope) {
    slice.zero(self.screen)
    self.fade_gain = 1
}

// After a gap in the audio: the beam and the AC coupling start over on the next sample, and the newest
// sweep is only what comes after it
restart_beam :: proc(self: ^Scope) {
    self.coupling = {}
    self.beam_restart = true
    self.history_count = 0
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

// Draws what came in since the previous frame over the fading screen, or without persistence keeps it and
// draws the newest sweep over a cleared one
update_scope :: proc(self: ^Scope) {
    self.skipping = false
    if lost := audio_capture_skip_stale(self); lost > 0 {
        // A stall, the beam starts over on the audio after it
        self.sample_clock += lost
        restart_beam(self)
        clear_scope(self)
        return
    }

    available := ringbuffer_available(&self.ringbuffer)
    if available == 0 do return

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

        if self.persistence_seconds <= 0 {
            record_samples(self, self.chunk[:count])
        } else if self.average_sweeps {
            average_samples(self, self.chunk[:count])
        } else {
            sweep_samples(self, self.chunk[:count])
        }
        available -= count
    }

    if self.persistence_seconds <= 0 do redraw_newest_sweep(self)
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
        restart_beam(self)
    }
    self.skipping = true
}

// Draws the samples over what is on the screen, which fades by the persistence. Instead of fading every cell
// for every sample, the new light is scaled up as much as the old would have faded since: fade_gain grows
// by 1 / decay a sample and the cells hold their light times it. The screen's readers take ratios of cells,
// where it cancels out. Before it outgrows the cells it's divided back into them.
sweep_samples :: proc(self: ^Scope, samples: []f32) {
    clock, min_level, ok := begin_samples(self, samples)
    if !ok do return

    // Of one sample
    decay: f64 = 1
    if self.persistence_seconds > 0 do decay = math.exp(-1 / (self.persistence_seconds * f64(self.sample_rate)))

    for sample, index in samples {
        follow_level(self, sample, min_level)
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

// Adds the samples to the sweeps' average, like an oscilloscope's averaging, the reference is its trigger.
// Each goes into the two bins around its place across the sweep by how near it is, like the beam's dots
// into the cells. The noise and anything else that doesn't repeat with the reference cancels out, the wave
// adds up, a detuned one drifts while it's averaged and smears like the strobe's stripes. The bins fade by
// the persistence the way the screen does, the newest sample weighs average_gain, and the average is the
// sum over the weight, so a bin shows what it has from the first sample on.
// Whole sweeps only, the samples are kept until the sweep they're in is over. Taken as they came, the bins
// behind the newest sample had this sweep's and the ones ahead of it only the sweep before's, the line
// stepped there, and the step walked to another place every frame.
average_samples :: proc(self: ^Scope, samples: []f32) {
    add_to_bin :: proc(self: ^Scope, bin: int, sample, weight: f32) {
        self.average_sums[bin] += sample * weight
        self.average_weights[bin] += weight
    }

    clock, min_level, ok := begin_samples(self, samples)
    if !ok do return

    // There's no beam to start over, only the low-pass did. Left on, it started over with every chunk and
    // the line twitched.
    self.beam_restart = false

    keep_samples(self, samples)

    // Up to where the sweep the newest sample is in started, from the oldest sample kept
    newest := clock + i64(len(samples)) - 1
    sweep_start := i64(math.ceil(math.floor(f64(newest) * self.step) / self.step))
    from := max(self.averaged_clock, newest - i64(self.history_count) + 1)
    self.averaged_clock = max(self.averaged_clock, sweep_start)

    // Of one sweep. All of a sweep's samples weigh the same: faded by the sample, its end weighed more than
    // its start, and the first bin, which takes from both, was bent toward the end.
    decay := math.exp(-1 / (self.step * self.persistence_seconds * f64(self.sample_rate)))

    bins := self.average_bins
    for sample_clock in from ..< sweep_start {
        before_newest := int(newest - sample_clock)
        sample := self.history[(self.history_next - 1 - before_newest + 2 * len(self.history)) % len(self.history)]

        position := f64(sample_clock) * self.step
        sweep := i64(math.floor(position))
        if sweep != self.averaged_sweep {
            self.averaged_sweep = sweep
            self.average_gain /= decay
        }

        // Divided back in as soon as it's too large, see sweep_samples
        if self.average_gain > SCOPE_MAX_FADE_GAIN {
            scale := f32(1 / self.average_gain)
            for &sum in self.average_sums[:bins] do sum *= scale
            for &weight in self.average_weights[:bins] do weight *= scale
            self.average_gain = 1
        }

        bin := (position - math.floor(position)) * f64(bins)
        left := int(bin)
        right_share := f32(bin - f64(left))
        add_to_bin(self, left % bins, sample, f32(self.average_gain) * (1 - right_share))
        add_to_bin(self, (left + 1) % bins, sample, f32(self.average_gain) * right_share)
    }

    // While it's set, scaled to the average's own peak as it is, what's drawn: the input's held the click
    // of a pluck and the noise the average leaves out, and the wave dipped under it. The average changes
    // smoothly, the scale with it. Then held, never under the noise's floor.
    if self.autoset_samples > 0 {
        peak: f32 = 0
        for weight, bin in self.average_weights[:bins] {
            if weight > 0 do peak = max(peak, abs(self.average_sums[bin] / weight))
        }
        self.level = peak
        self.autoset_samples -= i64(len(samples))
    }
    self.level = max(self.level, min_level)
}

// Keeps the samples for redraw_newest_sweep instead of drawing them, with the level followed the same
record_samples :: proc(self: ^Scope, samples: []f32) {
    _, min_level, ok := begin_samples(self, samples)
    if !ok do return

    for sample in samples do follow_level(self, sample, min_level)

    keep_samples(self, samples)
}

keep_samples :: proc(self: ^Scope, samples: []f32) {
    for sample in samples {
        self.history[self.history_next] = sample
        self.history_next = (self.history_next + 1) % len(self.history)
        self.history_count = min(self.history_count + 1, len(self.history))
    }
}

// The newest sweep over a cleared screen, the beam drawn from a sweep ago to the newest sample kept, through
// the three before them for its curve. The screen is always one whole sweep at the level as it is now: at a
// low note a frame's samples alone are less than a sweep and would leave a dark gap walking across, at a
// high note they're several sweeps over each other.
redraw_newest_sweep :: proc(self: ^Scope) {
    clear_screen(self)
    start, count, clock, ok := newest_sweep(self)
    if !ok do return

    self.recent = {history_sample(self, start, 0), history_sample(self, start, 1), history_sample(self, start, 2)}
    self.beam_restart = false
    for offset in SCOPE_CURVE_SAMPLES ..< count {
        move_beam(self, f64(clock + i64(offset)) * self.step, history_sample(self, start, offset), 1)
    }
}

// The newest sweep as a line, or the sweeps' average: the points the beam goes through, as fractions of the
// screen's width and height from its top left corner, in time order. As long apart in time, the distance
// from one to the next is how fast the beam moves there, and no further apart across than a cell. Over time
// the sweep starts over on the left, the x jumps back where it does.
scope_trace :: proc(self: ^Scope, points: ^[dynamic][2]f32) {
    clear(points)
    if self.average_sweeps && self.persistence_seconds > 0 {
        trace_average(self, points)
        return
    }

    start, count, clock, ok := newest_sweep(self)
    if !ok do return

    dots := trace_dots(self)
    for offset in SCOPE_CURVE_SAMPLES ..< count {
        before := history_sample(self, start, offset - 3)
        from := history_sample(self, start, offset - 2)
        to := history_sample(self, start, offset - 1)
        after := history_sample(self, start, offset)
        from_position := f64(clock + i64(offset - 2)) * self.step
        for dot in 0 ..< dots {
            progress := f32(dot) / f32(dots)
            value := catmull_rom(before, from, to, after, progress)
            point := sweep_point(self, from_position + f64(progress) * self.step, value)
            append(points, [2]f32{f32(point.x), f32(point.y)})
        }
    }
}

// The average round the sweep once from its start, where the sweeps it took meet. Over time that's the
// screen's edge, the line ends there.
trace_average :: proc(self: ^Scope, points: ^[dynamic][2]f32) {
    // The circle and the figure close on themselves. The sweep's end runs on into the next one's start, not
    // into its own: a note that changes from one sweep to the next, detuned, wobbling or fading, leaves a gap
    // as wide as it changed, and arrives at another slope. Over the sweep's last quarter the line bends
    // smoothly into its start instead (a Hermite blend of both), there's no step or corner at the top.
    Seam :: struct {
        gap:   f32, // from where the end was heading to the start
        slope: f32, // the start's slope over the end's, a bin
        bins:  int, // the blend's, up to the end
    }

    in_bin :: proc(self: ^Scope, bin: int) -> f32 {
        weight := self.average_weights[bin]
        return self.average_sums[bin] / weight if weight > 0 else 0
    }

    // Round the sweep, the bins wrap around, the seam blended in. The first bin takes from both sides of the
    // seam, the samples just before the sweep's end lead into the next one's start, it's carried on back
    // from the three after it instead (a parabola).
    average :: proc(self: ^Scope, offset: int, seam: Seam) -> f32 {
        bin := offset % self.average_bins
        if bin == 0 do return 3 * in_bin(self, 1) - 3 * in_bin(self, 2) + in_bin(self, 3)

        value := in_bin(self, bin)
        into := bin - (self.average_bins - seam.bins)
        if into <= 0 do return value

        blend := f32(into) / f32(seam.bins)
        rise := blend * blend * (3 - 2 * blend)
        turn := blend * blend * (blend - 1)
        return value + seam.gap * rise + seam.slope * f32(seam.bins) * turn
    }

    if self.step <= 0 do return

    bins := self.average_bins

    // Both sides at the join, through the three bins next to it (a parabola), the end's carried on to it
    seam := Seam{}
    if self.sweep != .TIME {
        start := [3]f32{average(self, 0, seam), average(self, 1, seam), average(self, 2, seam)}
        end := [3]f32{average(self, bins - 1, seam), average(self, bins - 2, seam), average(self, bins - 3, seam)}
        end_value := 3 * end[0] - 3 * end[1] + end[2]
        end_slope := (5 * end[0] - 8 * end[1] + 3 * end[2]) / 2
        start_slope := (-3 * start[0] + 4 * start[1] - start[2]) / 2
        seam = {gap = start[0] - end_value, slope = start_slope - end_slope, bins = bins / 4}
    }

    dots := trace_dots(self)
    for bin in 0 ..< bins {
        before := average(self, bin + bins - 1, seam)
        from, to, after := average(self, bin, seam), average(self, bin + 1, seam), average(self, bin + 2, seam)
        for dot in 0 ..< dots {
            progress := f32(dot) / f32(dots)
            value := catmull_rom(before, from, to, after, progress)
            point := sweep_point(self, (f64(bin) + f64(progress)) / f64(bins), value)
            append(points, [2]f32{f32(point.x), f32(point.y)})
        }
    }

    // Back to where it started, the circle and the figure close
    if self.sweep != .TIME {
        point := sweep_point(self, 1, average(self, 0, seam))
        append(points, [2]f32{f32(point.x), f32(point.y)})
    }
}

// The newest sweep's samples in the history: where they start in the ring, how many with the curve's
// samples before them, and the first one's clock as it's drawn. False while there's less than a curve.
newest_sweep :: proc(self: ^Scope) -> (start, count: int, clock: i64, ok: bool) {
    if self.step <= 0 do return

    count = min(int(math.ceil(1 / self.step)) + SCOPE_CURVE_SAMPLES, self.history_count)
    if count <= SCOPE_CURVE_SAMPLES do return

    start = (self.history_next - count + len(self.history)) % len(self.history)

    // The low-pass's output is the input this many samples before
    clock = self.sample_clock - i64(count)
    if self.lowpass do clock -= i64(self.lowpass_filter.length - 1)
    return start, count, clock, true
}

history_sample :: proc(self: ^Scope, start, offset: int) -> f32 {
    return self.history[(start + offset) % len(self.history)]
}

// The bookkeeping of a chunk of samples ahead of the beam: the clock runs on, Fill's window and the level's
// floor. Returns the clock of the first sample as it's drawn, and false for nothing to draw.
begin_samples :: proc(self: ^Scope, samples: []f32) -> (clock: i64, min_level: f32, ok: bool) {
    self.sample_clock += i64(len(samples))
    if self.step <= 0 || len(samples) == 0 do return

    // Fill's window, what the screen shows: the persistence, and at least SCOPE_FILL_MIN_PERIODS
    window := max(SCOPE_FILL_MIN_PERIODS / SCOPE_PERIODS / self.step, self.persistence_seconds * f64(self.sample_rate))
    self.block_length = max(int(math.round(window / SCOPE_PEAK_BLOCKS)), 1)
    self.fill_release = f32(math.exp(-1 / (SCOPE_FILL_RELEASE_S * f64(self.sample_rate))))

    // The low-pass's output is the input this many samples before
    clock = self.sample_clock - i64(len(samples))
    if self.lowpass do clock -= i64(self.lowpass_filter.length - 1)

    // Over the noise by the headroom while there's no note, the room's hiss stays small. A note lets go of it
    // as it comes out of the noise, the beam fades in over the same SNR, and a fading note fills the screen
    // until it fades into the noise.
    fade := STROBE_FADE_SNR_DB
    headroom := math.pow(f32(SCOPE_NOISE_HEADROOM), 1 - math.smoothstep(fade[0], fade[1], self.snr_db))
    min_level = max(self.noise_floor * headroom, SCOPE_MIN_LEVEL)
    return clock, min_level, true
}

// The level the screen's height is scaled to, every note fills the screen until it fades into the noise,
// with the newest sample and never under the floor. It's up at once, the wave would clip, and glides down
// to a lower peak, a step would jump the picture.
follow_level :: proc(self: ^Scope, sample, min_level: f32) {
    self.level = max(follow_screen_peak(self, abs(sample)), self.level * self.fill_release, min_level)
}

// The crest height a note sustains over the screen, Fill's envelope, with the newest sample. A note's peak
// isn't the same from period to period, its partials slide against each other and a string beats, scaled
// to each sweep's own the copies on the screen would be drawn at different sizes and vibrate. A peak
// decaying back would sag between the wave's crests and stretch the rest of the period. So the peaks are
// held in blocks over the window, block_length * SCOPE_PEAK_BLOCKS, and the level is the highest block's
// but one, the newest block counting as far as it came in: a single crest that stands out or a burst of
// noise can't jump the picture, an attack is followed from the first crest after it has filled a block.
follow_screen_peak :: proc(self: ^Scope, magnitude: f32) -> f32 {
    self.block_peak = max(self.block_peak, magnitude)
    self.block_samples += 1
    if self.block_samples >= self.block_length {
        self.block_peaks[self.next_block] = self.block_peak
        self.next_block = (self.next_block + 1) % SCOPE_PEAK_BLOCKS
        self.screen_peaks = two_highest(self.block_peaks[:])
        self.block_peak, self.block_samples = 0, 0
    }
    return max(self.screen_peaks[1], min(self.screen_peaks[0], self.block_peak))
}

// The largest of the values and the one after it
two_highest :: proc(values: []f32) -> (highest: [2]f32) {
    for value in values {
        if value > highest[0] {
            highest = {value, highest[0]}
        } else if value > highest[1] {
            highest[1] = value
        }
    }
    return
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

    dots := beam_dots(self, from, to)
    from_position := position - 2 * self.step
    for dot in 0 ..< dots {
        progress := (f32(dot) + 0.5) / f32(dots)
        value := catmull_rom(before, from, to, after, progress)
        beam_dot(self, from_position + f64(progress) * self.step, value, brightness / f64(dots))
    }
}

// How many dots the beam leaves on its way from one sample to the next, one a cell on the longer of its
// ways across and up
beam_dots :: proc(self: ^Scope, from, to: f32) -> int {
    rows := f64(abs(to - from) / self.level) * 0.5 * SCOPE_FILL * f64(self.rows)
    return clamp(int(math.ceil(max(sweep_cells(self), rows))), 1, SCOPE_MAX_BEAM_DOTS)
}

// How many points the trace has from one sample to the next, as many everywhere, one a cell across. Up
// the curve between two samples is near enough straight.
trace_dots :: proc(self: ^Scope) -> int {
    return clamp(int(math.ceil(sweep_cells(self))), 1, SCOPE_MAX_BEAM_DOTS)
}

// How far the sweep moves the beam across from one sample to the next, in cells, at its fastest: the cosine
// moves it fastest through the middle, and the circle on its outside
sweep_cells :: proc(self: ^Scope) -> f64 {
    width := f64(scope_width(self))
    if self.sweep == .XY do return math.TAU * SCOPE_PERIODS * self.step * 0.5 * SCOPE_FILL * width
    if self.sweep == .CIRCLE do return math.TAU * self.step * SCOPE_CIRCLE_REACH * width
    return self.step * f64(self.columns)
}

// A dot of the beam. It falls between the cells, the two columns and the two rows around it share it
// by how near they are.
beam_dot :: proc(self: ^Scope, position: f64, value: f32, brightness: f64) {
    // The columns wrap around, the sweep starts over on the left. There's nothing above and below the screen.
    light_cell :: proc(self: ^Scope, column, row: int, brightness: f64) {
        if row < 0 || row >= self.rows do return

        self.screen[row * self.columns + column %% self.columns] += f32(brightness)
    }

    // In cells, from the middle of the first column and of the top row
    point := sweep_point(self, position, value)
    x := point.x * f64(scope_width(self)) - 0.5
    y := point.y * f64(self.rows) - 0.5

    left := int(math.floor(x))
    top := int(math.floor(y))
    right_share := x - f64(left)
    bottom_share := y - f64(top)

    light_cell(self, left, top, brightness * (1 - right_share) * (1 - bottom_share))
    light_cell(self, left + 1, top, brightness * right_share * (1 - bottom_share))
    light_cell(self, left, top + 1, brightness * (1 - right_share) * bottom_share)
    light_cell(self, left + 1, top + 1, brightness * right_share * bottom_share)
}

// Where on the screen the beam is at a sample's position with its value, as fractions of the screen's
// width and height from its top left corner
sweep_point :: proc(self: ^Scope, position: f64, value: f32) -> [2]f64 {
    across := position - math.floor(position)

    // The reference at the sample, a cosine with the same reach as the wave
    if self.sweep == .XY do across = 0.5 + 0.5 * SCOPE_FILL * math.cos(math.TAU * SCOPE_PERIODS * position)

    // The averaged scope's line runs off the screen, a note grown louder than its scale or the circle's crests
    // up and down, see SCOPE_MAX_OVERSHOOT. The lamp's cells keep a crest over the level in the top row.
    reach: f32 = SCOPE_MAX_OVERSHOOT if self.average_sweeps else 1
    height := f64(clamp(value / self.level, -reach, reach))

    // Round from the top, anticlockwise with the screen's rows running down. The troughs stop in the middle,
    // the crests go out past the square to the sides.
    if self.sweep == .CIRCLE {
        angle := math.TAU * position
        radius := SCOPE_CIRCLE_REACH * (SCOPE_CIRCLE_RING + (1 - SCOPE_CIRCLE_RING) * max(height, -1))
        return {0.5 - radius * math.sin(angle), 0.5 - radius * math.cos(angle)}
    }
    return {across, 0.5 - 0.5 * SCOPE_FILL * height}
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
