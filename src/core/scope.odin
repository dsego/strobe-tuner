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
    in the cells shows their steps. Another note starts the average over from the samples it was named from,
    a pluck from its first sweep, the sweeps after it come in on top.

    The scope view draws the line, scope_trace. The lamp and its tracks read the screen from above
    (scope_from_above), the height of the beam in each column as a brightness. That's the classic strobe,
    stripes that wash out to gray when the beam smears.

    The input as it comes, a highpass would shift the fundamental against the harmonics, tilt the flat
    top of a square wave and bend a sawtooth. Only the DC is taken out, like the AC coupling of an
    oscilloscope.

    The low-pass of the scope view and the lamp: two running averages, each over a twelfth of the reference
    period, take out the fine wiggles of the high partials and the hiss and keep the first few partials.
    Every partial is delayed the same, the shape stays, and the beam is drawn as much earlier, so the picture
    doesn't move when it's turned on. It cancels the 12th partial and its multiples exactly, the 3rd keeps
    81% and the 6th 41%. The lamp's tracks take the wave as it comes, their upper partials would fade.

    Circle: the sweep goes round instead of across, the same two reference periods a turn, anticlockwise
    from the top, the wave out from a ring halfway at its zero, its crests to the outside and its troughs
    in to the middle. A sine draws two lobes that meet in the middle, every partial bumps and dips them.
    It's the line over time bent round, narrower the nearer the middle. An in tune note stands still, a
    detuned one spins by half the phase it slips, clockwise when sharp like the wheel. It's square,
    as wide as the screen is high, the crests reach out past the square to the screen's sides.

    The circle's afterglow: the line as it was drawn SCOPE_AFTERGLOW_PERIODS ago, and as long before that,
    behind the newest. Apart in periods, not in seconds, they're turned apart by the cents the note is off
    and as far on every note. A note in tune and steady draws them all on one line, one detuned turns them
    apart evenly, one that wavers unevenly, and anything that doesn't repeat, the noise, partials slipping
    against the fundamental, two strings beating, splits them. Averaged, each is the average as it was, the
    newest line is the average of many sweeps before it and lags behind as far, a single sweep kept would
    lie on it. Without persistence each is the newest sweep's samples as far back in the history.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:math"
import "core:slice"


SCOPE_PERIODS :: 2 // reference periods across the screen, and round the circle
SCOPE_FILL :: 0.9 // how much of the height a full scale sample takes
SCOPE_CHUNK_SIZE :: 4096
SCOPE_MAX_BEAM_DOTS :: 256 // between two samples
SCOPE_MAX_FADE_GAIN :: 1e15 // divided back into the cells at this, far under an f32's range, see sweep_samples
SCOPE_SWEEP_MAX_SAMPLES :: 24576 // two periods of a 16 Hz note at 192 kHz
// The average's bins, for a sweep and the circle's overlap past it with room over
SCOPE_TRACE_MAX_SAMPLES :: 2 * SCOPE_SWEEP_MAX_SAMPLES
SCOPE_CURVE_SAMPLES :: 3 // the beam's curve to a sample runs through this many before it, see move_beam

// The input's peak is held over at least this many periods, Medium's: scaled to one sweep's own peak the
// picture would shake as the partials beat against each other, see follow_screen_peak
SCOPE_PEAK_MIN_PERIODS :: 18
// and glides down to a lower peak over this, a step would jump the picture, see follow_level
SCOPE_PEAK_RELEASE_S :: #config(SCOPE_PEAK_RELEASE_S, 0.06)

// The screen is as high as the input is loud, on a dB scale: a peak this loud fills it, see SCOPE_FILL, and
// one SCOPE_LOUDNESS_RANGE_DB quieter draws flat. A hum shows about half as high as a note sung out, and a
// fading note shrinks as it fades, see loudness_level.
SCOPE_LOUD_DBFS :: #config(SCOPE_LOUD_DBFS, -6)
SCOPE_LOUDNESS_RANGE_DB :: #config(SCOPE_LOUDNESS_RANGE_DB, 48)
// Quieter still, the screen keeps this much of its height, the level never divides by nothing
SCOPE_MIN_HEIGHT :: 0.01

// A note louder than the level has caught up with runs off the screen up to this many times the full height,
// further off it isn't seen anyway
SCOPE_MAX_OVERSHOOT :: 2

// The input's peak is kept as the peaks of this many blocks of the screen's window
SCOPE_PEAK_BLOCKS :: 16

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
}

// The circle's ring at the wave's zero, from its middle to its outside. Halfway, a full scale sample reaches
// the outside and its trough the middle, the wave dips in to it and never through to the other side, where
// every period's would cross and light it up. Silence is a circle.
SCOPE_CIRCLE_RING :: 0.5
// The radius of a full scale sample, of the square's side. Past its edge, the ring at rest fills the
// screen's width more and the crests reach out to its sides.
SCOPE_CIRCLE_REACH :: 0.7
// Round the circle the line runs on past its start by this much of a sweep, the wave as it went on, its end over
// its start. In tune they lie on each other, detuned the end runs on beside it, as far apart as the note slips
// in a sweep. Ended where it started, the line stepped there. The display fades both ends where they overlap.
SCOPE_CIRCLE_OVERLAP :: #config(SCOPE_CIRCLE_OVERLAP, 0.1)
#assert(SCOPE_CIRCLE_OVERLAP >= 0 && SCOPE_CIRCLE_OVERLAP <= 0.5)

// The circle's afterglow, see the top of the file: this many sweeps behind the newest line, SCOPE_AFTERGLOW_PERIODS
// apart. Each is turned from the one after it by about 1.7° a cent at 16. The circle looks the same half a turn
// on, two periods a turn, so a quarter turn apart they'd lean either way: at 16 that's 53 cents, past the tracks'
// 50, more periods turn them further for a cent and lean the wrong way sooner.
SCOPE_AFTERGLOW_SWEEPS :: 3
SCOPE_AFTERGLOW_PERIODS :: #config(SCOPE_AFTERGLOW_PERIODS, 16)
#assert(SCOPE_AFTERGLOW_PERIODS % SCOPE_PERIODS == 0)
// The sweeps kept for it, the newest and the ones as far back as the oldest
SCOPE_SWEEPS_KEPT :: SCOPE_AFTERGLOW_SWEEPS * SCOPE_AFTERGLOW_PERIODS / SCOPE_PERIODS + 1
// The samples kept, a sweep and the circle's overlap past it with room over, and as many sweeps before it as
// the afterglow reaches back
SCOPE_HISTORY_MAX_SAMPLES :: (SCOPE_SWEEPS_KEPT + 1) * SCOPE_SWEEP_MAX_SAMPLES

// A sweep this much louder than the average is a pluck, the average starts over with it like at another note,
// see fold_into_average. Faded in, a pluck over the last one's tail drew as much smaller as the tail had faded
// and grew over 0.1 to 0.2 s. Weighed by how loud they are, the sweeps after a note ended hardly counted, the
// dead note's shape stayed and grew as the screen's level fell. E.g. -define:SCOPE_PLUCK_DB=n
SCOPE_PLUCK_DB :: #config(SCOPE_PLUCK_DB, 6)

// The input as it came kept for backfill_history, the pitch detection's window at 192 kHz, see PITCH_WINDOW_S
SCOPE_RAW_MAX_SAMPLES :: 16384

// Two running averages one after the other, see the top of the file
ScopeLowpass :: struct {
    length:  int, // of each average, in samples
    primed:  bool, // the averages hold the input, otherwise they start over filled with the next sample
    oldest:  int, // where in the history the sample leaving the averages is
    history: [2][SCOPE_LOWPASS_MAX_LENGTH]f32,
    sums:    [2]f64,
}

// A sweep that's over, kept for the circle's afterglow, see keep_sweep
ScopeKeptSweep :: struct {
    sweep: i64, // which, see first_clock_in_sweep
    level: f32, // the screen's once it was over
}


Scope :: struct {
    using node:          AudioCaptureNode,
    freq_hz:             f64,
    sweep:               ScopeSweep,
    lowpass:             bool, // the scope view's or the lamp's, see the top of the file
    lowpass_filter:      ScopeLowpass,

    // How long the beam stays on the screen, the time constant of its decay. 0 keeps the newest sweep
    // only, drawn over again every frame, see redraw_newest_sweep.
    persistence_s: f64,

    // Absolute index of the next sample
    sample_clock:        i64,
    step:                f64, // how far across the screen one sample moves, 0..1

    // How long the beam stayed in each cell, row 0 on top, scaled up by fade_gain, see sweep_samples
    screen:              []f32,
    fade_gain:           f64,
    // The newest samples as they're drawn, a ring, for the newest sweep without persistence and the trace, and
    // the afterglow's sweeps before it
    history:             []f32,
    history_next:        int, // where the next sample goes
    history_count:       int, // how many are kept, up to the ring's length
    // The newest samples before the low-pass, a ring, see backfill_history
    raw_history:         []f32,
    raw_next:            int,
    raw_count:           int,
    backfilled:          int, // the samples before the next ones the average starts with, see backfill_history
    // The sweeps averaged over the persistence for the trace, nothing is drawn on the screen, see
    // average_samples. A bin as wide as a sample moves, the sum of the samples there and of their weights,
    // scaled up by average_gain like the screen's cells by fade_gain.
    average_sweeps:      bool,
    average_sums:        []f32,
    average_weights:     []f32,
    average_bins:        int,
    average_gain:        f64,
    averaged_clock:      i64, // the samples before it are in the average, see average_samples
    restart_average:     bool, // it starts over with the samples that come in next
    averaged_sweep:      i64, // the one the newest of them is in
    average_power:       f64, // the sweeps' mean square, averaged like them, 0 before one is in, see SCOPE_PLUCK_DB

    // The newest sweeps that are over, a ring for the circle's afterglow, kept_newest the newest of kept_count.
    // Averaged, each one's average, average_bins_used values from the slot's place, see keep_sweep.
    kept_sweeps:         [SCOPE_SWEEPS_KEPT]ScopeKeptSweep,
    kept_averages:       [dynamic]f32,
    kept_newest:         int,
    kept_count:          int,
    kept_averaged:       bool, // they were kept with their average, they start over when it changes
    kept_from:           i64, // the history is of the note from this clock on, as it's drawn, see clear_scope

    columns:             int,
    rows:                int,
    recent:              [3]f32, // the samples before the newest, the beam is drawn through them
    beam_restart:        bool, // recent is from before a gap, the beam starts over on the next sample
    level:               f32, // what the screen's height is scaled to, see follow_level
    peak:                f32, // the input's, held over the screen's window
    peak_release:        f32, // what the peak glides down by a sample

    // The peak's blocks, see follow_screen_peak
    block_peaks:         [SCOPE_PEAK_BLOCKS]f32,
    screen_peaks:        [2]f32, // of the blocks, the highest and the highest but one
    block_peak:          f32, // of the newest block as far as it came in
    block_samples:       int, // of the newest block, it's done at block_length
    block_length:        int,
    next_block:          int,
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
    self.history = make([]f32, SCOPE_HISTORY_MAX_SAMPLES)
    self.raw_history = make([]f32, SCOPE_RAW_MAX_SAMPLES)
    self.average_sums = make([]f32, SCOPE_TRACE_MAX_SAMPLES)
    self.average_weights = make([]f32, SCOPE_TRACE_MAX_SAMPLES)
    self.level = loudness_level(0)
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
    delete(self.raw_history)
    delete(self.average_sums)
    delete(self.average_weights)
    delete(self.kept_averages)

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
    resize(&self.kept_averages, SCOPE_SWEEPS_KEPT * average_bins_used(self))

    clear_scope(self)
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
    self.level, self.peak = loudness_level(0), 0
    self.block_peaks, self.screen_peaks, self.block_peak = {}, {}, 0
}

// The screen and the average, and the afterglow's sweeps: the history from here on is of the new note, from
// the samples backfilled on
clear_scope :: proc(self: ^Scope) {
    clear_screen(self)
    clear_average(self)
    self.restart_average = true
    backfill_history(self)
    self.kept_from = self.sample_clock - lowpass_delay(self) - i64(self.backfilled)
}

// The average's bins and the afterglow's sweeps kept, they start over with the next sweep in
clear_average :: proc(self: ^Scope) {
    used := average_bins_used(self)
    slice.zero(self.average_sums[:used])
    slice.zero(self.average_weights[:used])
    self.average_gain = 1
    self.average_power = 0
    self.averaged_sweep = min(i64) // the next one is new
    self.kept_count = 0
}

// The newest samples kept go through the low-pass again at the reference now, from the input as it came, and
// the average starts with them: the note had been playing while it was named. A low note's first sweep
// doesn't wait for new samples, E2's came a frame late and B0's four. As many as the first whole sweep needs,
// from where one starts and with its overlap, after the low-pass has filled, and no more than the pitch
// detection's window: a note is named within about 50 ms of the window holding it, further back is the note
// before. Kept as they went through at the reference before, they'd be placed by that one's delay and the
// sweep they were in stepped where they end. The history older than them was the note before too.
backfill_history :: proc(self: ^Scope) {
    settle := 2 * self.lowpass_filter.length if self.lowpass else 0
    needed := settle + int(math.ceil((1 + scope_trace_sweeps(self)) / self.step)) if self.step > 0 else 0
    count := min(self.raw_count, needed, int(PITCH_WINDOW_S * f64(self.sample_rate)), len(self.raw_history))
    self.backfilled = count
    self.history_count = count
    if count == 0 do return

    for offset in 0 ..< count {
        raw := self.raw_history[(self.raw_next - count + offset + len(self.raw_history)) % len(self.raw_history)]
        self.history[(self.history_next - count + offset + len(self.history)) % len(self.history)] = raw
    }

    // Started over like at the input's next sample, and the next ones carry on from these
    self.lowpass_filter.primed = false
    if !self.lowpass do return

    start := (self.history_next - count + len(self.history)) % len(self.history)
    before_end := min(count, len(self.history) - start)
    lowpass_samples(&self.lowpass_filter, self.history[start:][:before_end])
    lowpass_samples(&self.lowpass_filter, self.history[:count - before_end])
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
    self.raw_count = 0
}

// Starts with a dark screen, the old picture would linger under the new one, and a sweep as long as the new
// one's
set_scope_sweep :: proc(self: ^Scope, sweep: ScopeSweep) {
    self.sweep = sweep
    set_scope_freq(self, self.freq_hz)
}

// How many columns of the screen the beam draws in, the circle's are square
scope_width :: proc(self: ^Scope) -> int {
    return self.columns if self.sweep == .TIME else min(self.rows, self.columns)
}

// Draws what came in since the previous frame over the fading screen, or without persistence keeps it and
// draws the newest sweep over a cleared one
update_scope :: proc(self: ^Scope) {
    self.skipping = false

    // The afterglow's sweeps were kept with their average or without, they start over when it's turned on or off
    averaged := self.average_sweeps && self.persistence_s > 0
    if averaged != self.kept_averaged {
        self.kept_averaged = averaged
        self.kept_count = 0
    }

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
        keep_raw_samples(self, self.chunk[:count])

        // Starts over with the beam, and when it's turned on
        if self.beam_restart || !self.lowpass do self.lowpass_filter.primed = false
        if self.lowpass do lowpass_samples(&self.lowpass_filter, self.chunk[:count])

        if self.persistence_s <= 0 {
            record_samples(self, self.chunk[:count])
        } else if self.average_sweeps {
            average_samples(self, self.chunk[:count])
        } else {
            sweep_samples(self, self.chunk[:count])
        }
        available -= count
    }

    if self.persistence_s <= 0 do redraw_newest_sweep(self)
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
    clock, ok := begin_samples(self, samples)
    if !ok do return

    // Of one sample
    decay: f64 = 1
    if self.persistence_s > 0 do decay = math.exp(-1 / (self.persistence_s * f64(self.sample_rate)))

    for sample, index in samples {
        follow_level(self, sample)
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
// Whole sweeps only, the samples are kept until the sweep they're in is over, round the circle and its overlap
// past the end too. Taken as they came, the bins behind the newest sample had this sweep's and the ones ahead
// of it only the sweep before's, the line stepped there, and the step walked to another place every frame.
average_samples :: proc(self: ^Scope, samples: []f32) {
    clock, ok := begin_samples(self, samples)
    if !ok do return

    // There's no beam to start over, only the low-pass did. Left on, it started over with every chunk and
    // the line twitched.
    self.beam_restart = false

    // By the input's loudness like the lamp's, the average's peak is under the input's, it leaves the noise out
    for sample in samples do follow_level(self, sample)
    keep_samples(self, samples)

    newest := clock + i64(len(samples)) - 1
    first, unfinished := sweeps_to_average(self, clock, newest)
    fold_into_average(self, newest, first, unfinished)
}

// The sweeps to add, from first up to the one that isn't over, see fold_into_average. Round the circle a sweep
// is over once its overlap past the end has come in, over time once it ends. From the oldest sample kept, and
// from where a sweep starts too: where the average left off is partway into a sweep after the reference
// changed, and so is the oldest sample kept after a gap. Started there, the bins before it stayed empty and the
// ones after it had a part of a sweep more, the line stepped there.
sweeps_to_average :: proc(self: ^Scope, clock, newest: i64) -> (first, unfinished: i64) {
    // Started over, from the samples backfilled before these once the low-pass has filled again, it started
    // over with them, see backfill_history
    if self.restart_average {
        self.restart_average = false
        settle := 2 * i64(self.lowpass_filter.length) if self.lowpass else 0
        self.averaged_clock = clock - i64(self.backfilled) + settle
    }

    overlap := scope_trace_sweeps(self) - 1
    unfinished = i64(math.floor(f64(newest) * self.step - overlap))
    from := max(self.averaged_clock, newest - i64(self.history_count) + 1)
    first = i64(math.floor(f64(from) * self.step))
    if first_clock_in_sweep(self, f64(first)) < from do first += 1

    self.averaged_clock = max(self.averaged_clock, first_clock_in_sweep(self, f64(unfinished)))
    return
}

// The kept samples of the sweeps from first up to unfinished into the average, each into the two bins around
// its place across the sweep, a sweep at a time, and each sweep kept for the afterglow once it's in. Round the
// circle the samples at the start of the next sweep go in once more as its overlap, see SCOPE_CIRCLE_OVERLAP:
// into the bins after its end, by its weight. The sweep's end runs on into them, the last bin's samples into
// the bin past it, not round to the first bin.
fold_into_average :: proc(self: ^Scope, newest, first, unfinished: i64) {
    // Of one sweep. All of a sweep's samples weigh the same: faded by the sample, its end weighed more than
    // its start.
    decay := math.exp(-1 / (self.step * self.persistence_s * f64(self.sample_rate)))

    overlap := scope_trace_sweeps(self) - 1
    pluck := math.pow(10, f64(SCOPE_PLUCK_DB) / 10)
    for sweep in first ..< unfinished {
        start := first_clock_in_sweep(self, f64(sweep))
        next := first_clock_in_sweep(self, f64(sweep + 1))

        // A pluck, see SCOPE_PLUCK_DB
        power := sweep_power(self, newest, start, next)
        if self.average_power > 0 && power > pluck * self.average_power do clear_average(self)
        self.average_power = power if self.average_power == 0 else decay * self.average_power + (1 - decay) * power

        if sweep != self.averaged_sweep {
            self.averaged_sweep = sweep
            self.average_gain /= decay
        }

        // Divided back in as soon as it's too large, see sweep_samples
        if self.average_gain > SCOPE_MAX_FADE_GAIN {
            scale := f32(1 / self.average_gain)
            used := average_bins_used(self)
            for &sum in self.average_sums[:used] do sum *= scale
            for &weight in self.average_weights[:used] do weight *= scale
            self.average_gain = 1
        }

        for sample_clock in start ..< next {
            across := f64(sample_clock) * self.step - f64(sweep)
            add_to_average(self, across, kept_sample(self, newest, sample_clock), self.average_gain)
        }

        // The first bin from both sides like the others, from the sample before the sweep's start too. From
        // one side, it had a sample of some sweeps and only a sliver of others', the sweeps it took weren't its
        // neighbours', and a detuned note stepped there.
        before := start - 1
        if before > newest - i64(self.history_count) {
            into_first := 1 + (f64(before) * self.step - f64(sweep)) * f64(self.average_bins)
            add_to_average_bin(self, 0, kept_sample(self, newest, before), f32(self.average_gain * into_first))
        }

        // The overlap, the next sweep's start once more past this one's end
        overlap_end := first_clock_in_sweep(self, f64(sweep + 1) + overlap)
        for sample_clock in next ..< overlap_end {
            across := f64(sample_clock) * self.step - f64(sweep + 1)
            add_to_average(self, 1 + across, kept_sample(self, newest, sample_clock), self.average_gain)
        }

        keep_sweep(self, sweep)
        average_values(self, kept_average(self, self.kept_newest))
    }
}

// The mean square of the kept samples from start to before next
sweep_power :: proc(self: ^Scope, newest, start, next: i64) -> f64 {
    total: f64 = 0
    for sample_clock in start ..< next {
        sample := f64(kept_sample(self, newest, sample_clock))
        total += sample * sample
    }
    return total / f64(max(next - start, 1))
}

// A sample into the two bins around its place along the line, in sweeps, by how near it is to each
add_to_average :: proc(self: ^Scope, along: f64, sample: f32, gain: f64) {
    bin := along * f64(self.average_bins)
    left := int(bin)
    right_share := f32(bin - f64(left))
    add_to_average_bin(self, left, sample, f32(gain) * (1 - right_share))
    add_to_average_bin(self, left + 1, sample, f32(gain) * right_share)
}

// How many of the average's bins hold the line: a sweep's, round the circle its overlap, and the bin past the
// end the last samples go into
average_bins_used :: proc(self: ^Scope) -> int {
    return int(scope_trace_sweeps(self) * f64(self.average_bins)) + 2
}

// How many sweeps the line runs, round the circle on past where it started, see SCOPE_CIRCLE_OVERLAP
scope_trace_sweeps :: proc(self: ^Scope) -> f64 {
    return 1 + SCOPE_CIRCLE_OVERLAP if self.sweep == .CIRCLE else 1
}

// The clock of the first sample in a sweep
first_clock_in_sweep :: proc(self: ^Scope, sweep: f64) -> i64 {
    return i64(math.ceil(sweep / self.step))
}

// The sample kept at a clock, the newest one's is newest
kept_sample :: proc(self: ^Scope, newest, sample_clock: i64) -> f32 {
    before_newest := int(newest - sample_clock)
    return self.history[(self.history_next - 1 - before_newest + 2 * len(self.history)) % len(self.history)]
}

add_to_average_bin :: proc(self: ^Scope, bin: int, sample, weight: f32) {
    self.average_sums[bin] += sample * weight
    self.average_weights[bin] += weight
}

// The average in each bin, the sum over the weight, 0 in one that has nothing yet
average_values :: proc(self: ^Scope, values: []f32) {
    for &value, bin in values {
        weight := self.average_weights[bin]
        value = self.average_sums[bin] / weight if weight > 0 else 0
    }
}

// A sweep that's over into the afterglow's ring with the level now, over the oldest. Averaged, its average goes
// into the slot's values after it.
keep_sweep :: proc(self: ^Scope, sweep: i64) {
    self.kept_newest = (self.kept_newest + 1) % SCOPE_SWEEPS_KEPT
    self.kept_count = min(self.kept_count + 1, SCOPE_SWEEPS_KEPT)
    self.kept_sweeps[self.kept_newest] = {sweep, self.level}
}

// The average kept in a slot of the afterglow's ring
kept_average :: proc(self: ^Scope, slot: int) -> []f32 {
    used := average_bins_used(self)
    return self.kept_averages[slot * used:][:used]
}

// The slot of the afterglow's ring a sweep is kept in, false where it isn't kept
kept_slot :: proc(self: ^Scope, sweep: i64) -> (slot: int, ok: bool) {
    if self.kept_count == 0 do return

    back := self.kept_sweeps[self.kept_newest].sweep - sweep
    if back < 0 || back >= i64(self.kept_count) do return

    slot = (self.kept_newest - int(back) + SCOPE_SWEEPS_KEPT) % SCOPE_SWEEPS_KEPT
    return slot, self.kept_sweeps[slot].sweep == sweep
}

// Keeps the samples for redraw_newest_sweep instead of drawing them, with the level followed the same, and
// the sweeps over since the last ones kept for the afterglow, with the level now. Right after it started over
// from the first that's of the new note, and no more than the ring holds.
record_samples :: proc(self: ^Scope, samples: []f32) {
    clock, ok := begin_samples(self, samples)
    if !ok do return

    for sample in samples do follow_level(self, sample)

    keep_samples(self, samples)

    over := i64(math.floor(f64(clock + i64(len(samples))) * self.step)) - 1
    first := i64(math.ceil(f64(self.kept_from) * self.step))
    if self.kept_count > 0 do first = self.kept_sweeps[self.kept_newest].sweep + 1
    for sweep in max(first, over - SCOPE_SWEEPS_KEPT + 1) ..= over do keep_sweep(self, sweep)
}

// The input before the low-pass for backfill_history, every chunk however the scope draws it
keep_raw_samples :: proc(self: ^Scope, samples: []f32) {
    for sample in samples {
        self.raw_history[self.raw_next] = sample
        self.raw_next = (self.raw_next + 1) % len(self.raw_history)
    }
    self.raw_count = min(self.raw_count + len(samples), len(self.raw_history))
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
// the sweep starts over on the left, the x jumps back where it does. Round the circle it runs on past where
// it started, see SCOPE_CIRCLE_OVERLAP.
scope_trace :: proc(self: ^Scope, points: ^[dynamic][2]f32) {
    clear(points)

    // The average as the newest sweep in it left it, none yet before one is in
    if self.average_sweeps && self.persistence_s > 0 {
        values: []f32
        if self.kept_count > 0 do values = kept_average(self, self.kept_newest)
        trace_average(self, values, self.level, points)
        return
    }

    start, count, clock, ok := newest_sweep(self)
    if !ok do return

    trace_samples(self, start, count, clock, self.level, points)
}

// The circle's afterglow, see the top of the file: the line as it was drawn sweeps times SCOPE_AFTERGLOW_PERIODS
// ago, at the level it was drawn at, like scope_trace. None where that's from before the note or isn't kept.
scope_afterglow_trace :: proc(self: ^Scope, sweeps: int, points: ^[dynamic][2]f32) {
    clear(points)
    if self.kept_count == 0 || self.step <= 0 do return

    back := i64(sweeps * SCOPE_AFTERGLOW_PERIODS / SCOPE_PERIODS)
    if self.average_sweeps && self.persistence_s > 0 {
        slot, ok := kept_slot(self, self.kept_sweeps[self.kept_newest].sweep - back)
        if !ok do return

        trace_average(self, kept_average(self, slot), self.kept_sweeps[slot].level, points)
        return
    }

    // The newest sweep's samples as many sweeps back, at the level once the sweep the last of them is in was over
    count := int(math.ceil(scope_trace_sweeps(self) / self.step)) + SCOPE_CURVE_SAMPLES
    shift := int(math.round(f64(back) / self.step))
    if count + shift > self.history_count do return

    clock := self.sample_clock - i64(count + shift) - lowpass_delay(self)
    if clock < self.kept_from do return

    slot, ok := kept_slot(self, i64(math.floor(f64(clock + i64(count) - 1) * self.step)))
    if !ok do return

    start := (self.history_next - count - shift + len(self.history)) % len(self.history)
    trace_samples(self, start, count, clock, self.kept_sweeps[slot].level, points)
}

// A line through count samples from start in the history, through the three before them for its curve, the
// first one's clock as it's drawn, scaled to level
trace_samples :: proc(self: ^Scope, start, count: int, clock: i64, level: f32, points: ^[dynamic][2]f32) {
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
            point := sweep_point(self, from_position + f64(progress) * self.step, value, level)
            append(points, [2]f32{f32(point.x), f32(point.y)})
        }
    }
}

// The average in each bin, round the sweep once from its start, where the sweeps it took meet, scaled to level.
// Over time that's the screen's edge, the line ends there. Round the circle it runs on past the start through
// the overlap's bins, see SCOPE_CIRCLE_OVERLAP. Without values it's flat, none of the bins has anything yet.
trace_average :: proc(self: ^Scope, values: []f32, level: f32, points: ^[dynamic][2]f32) {
    average :: proc(values: []f32, bin: int) -> f32 {
        return values[bin] if bin < len(values) else 0
    }

    // The line ends at last, the bins don't wrap round to the sweep's other end, the one past an end carries
    // the two before it on (a straight line). Wrapped, the last piece ran on to the start's height and drew
    // the step between them at the end.
    beside :: proc(values: []f32, bin, last: int) -> f32 {
        if bin < 0 do return 2 * average(values, 0) - average(values, 1)
        if bin > last do return 2 * average(values, last) - average(values, last - 1)
        return average(values, bin)
    }

    if self.step <= 0 do return

    // Over time the sweep's last bin, round the circle the overlap's but one, the last has its samples from
    // one side only
    bins := self.average_bins
    last := bins - 1 if self.sweep == .TIME else int(scope_trace_sweeps(self) * f64(bins)) - 1

    dots := trace_dots(self)
    for bin in 0 ..< last {
        before, from := beside(values, bin - 1, last), average(values, bin)
        to, after := beside(values, bin + 1, last), beside(values, bin + 2, last)
        for dot in 0 ..< dots {
            progress := f32(dot) / f32(dots)
            value := catmull_rom(before, from, to, after, progress)
            point := sweep_point(self, (f64(bin) + f64(progress)) / f64(bins), value, level)
            append(points, [2]f32{f32(point.x), f32(point.y)})
        }
    }

    point := sweep_point(self, f64(last) / f64(bins), average(values, last), level)
    append(points, [2]f32{f32(point.x), f32(point.y)})
}

// The newest sweep's samples in the history, round the circle with its overlap: where they start in the ring,
// how many with the curve's samples before them, and the first one's clock as it's drawn. False while there's
// less than a curve.
newest_sweep :: proc(self: ^Scope) -> (start, count: int, clock: i64, ok: bool) {
    if self.step <= 0 do return

    count = min(int(math.ceil(scope_trace_sweeps(self) / self.step)) + SCOPE_CURVE_SAMPLES, self.history_count)
    if count <= SCOPE_CURVE_SAMPLES do return

    start = (self.history_next - count + len(self.history)) % len(self.history)
    clock = self.sample_clock - i64(count) - lowpass_delay(self)
    return start, count, clock, true
}

// The low-pass's output is the input this many samples before
lowpass_delay :: proc(self: ^Scope) -> i64 {
    return i64(self.lowpass_filter.length - 1) if self.lowpass else 0
}

history_sample :: proc(self: ^Scope, start, offset: int) -> f32 {
    return self.history[(start + offset) % len(self.history)]
}

// The bookkeeping of a chunk of samples ahead of the beam: the clock runs on, and the window the input's peak
// is held over. Returns the clock of the first sample as it's drawn, and false for nothing to draw.
begin_samples :: proc(self: ^Scope, samples: []f32) -> (clock: i64, ok: bool) {
    self.sample_clock += i64(len(samples))
    if self.step <= 0 || len(samples) == 0 do return

    // What the screen shows: the persistence, and at least SCOPE_PEAK_MIN_PERIODS
    window := max(SCOPE_PEAK_MIN_PERIODS / SCOPE_PERIODS / self.step, self.persistence_s * f64(self.sample_rate))
    self.block_length = max(int(math.round(window / SCOPE_PEAK_BLOCKS)), 1)
    self.peak_release = f32(math.exp(-1 / (SCOPE_PEAK_RELEASE_S * f64(self.sample_rate))))

    clock = self.sample_clock - i64(len(samples)) - lowpass_delay(self)
    return clock, true
}

// The level the screen's height is scaled to, by the input's peak with the newest sample, see loudness_level.
// The peak is up at once, the wave would clip, and glides down, a step would jump the picture.
follow_level :: proc(self: ^Scope, sample: f32) {
    self.peak = max(follow_screen_peak(self, abs(sample)), self.peak * self.peak_release)
    self.level = loudness_level(self.peak)
}

// The level a peak is drawn at: SCOPE_LOUD_DBFS and louder fills the screen, every dB quieter is a step
// lower, down to flat SCOPE_LOUDNESS_RANGE_DB under it. One gain for the whole screen, the wave keeps its
// shape and only its size follows how loud it is.
loudness_level :: proc(peak: f32) -> f32 {
    audible := max(peak, 1e-6)
    height := 1 - (SCOPE_LOUD_DBFS - 20 * math.log10(audible)) / SCOPE_LOUDNESS_RANGE_DB
    return audible / clamp(height, SCOPE_MIN_HEIGHT, 1)
}

// The crest height a note sustains over the screen, the input's peak, with the newest sample. A note's peak
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

// How far the sweep moves the beam across from one sample to the next, in cells, at its fastest: the circle
// moves it fastest on its outside
sweep_cells :: proc(self: ^Scope) -> f64 {
    width := f64(scope_width(self))
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
    point := sweep_point(self, position, value, self.level)
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

// Where on the screen the beam is at a sample's position with its value scaled to level, as fractions of the
// screen's width and height from its top left corner
sweep_point :: proc(self: ^Scope, position: f64, value, level: f32) -> [2]f64 {
    across := position - math.floor(position)

    // The averaged scope's line runs off the screen, a note louder than the level has caught up with or the
    // circle's crests up and down, see SCOPE_MAX_OVERSHOOT. The lamp's cells keep a crest over the level in the top row.
    reach: f32 = SCOPE_MAX_OVERSHOOT if self.average_sweeps else 1
    height := f64(clamp(value / level, -reach, reach))

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
