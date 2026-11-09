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


package core

import "core:math"

// How bright a strobe track's stripes are, from the samples themselves. Each track's reference is cut into
// spans, a period of the note, as many of the track's own as its partial, two of the note's for a fifth, so
// every partial of the note goes whole periods in one. The track's partial is measured over windows of spans,
// one closing at the end of every span, and the stripes are as bright as the measurements agree, see
// strobe_slat_level. The readout, the note hold and the trace go by it too. It replaced an SNR against a noise
// floor and the noise between the note's partials: the stripes let go of a partial as soon as it shimmers.

// How long the measurements are remembered, in periods of the note, they fade to a third over this many. As
// steady as one span's measurements were over 4, the windows overlap, see SLAT_WINDOW_OVERLAP.
STROBE_SLATS_MEMORY_PERIODS :: #config(STROBE_SLATS_MEMORY_PERIODS, 7.0)

// Whether the partial is still there is told from the measurements of about this many periods of the note. The
// remembered ones agree long after a note stops, the silence after it weighs nothing against them by size, and
// the stripes stayed lit until they faded under STROBE_SLATS_SILENCE_DBFS: a hum half a second, a bass's low E
// a second. A string fading out stays lit as long as before, its last periods are as loud as it still is.
STROBE_SLATS_RECENT_PERIODS :: #config(STROBE_SLATS_RECENT_PERIODS, 1.0)

// Each measurement is a Blackman window over this many spans. One span alone let a 2nd partial 7 cents off into
// the 1× track 40 dB under it, louder than a low string's fundamental can be, and it turned so slowly from span
// to span that it looked steady. Over three, the window's main lobe reaches a note's frequency each way and every
// other partial of the note falls in its nulls.
SLAT_WINDOW_SPANS :: 3

// The measurements overlap, as many as this share as much noise as one, see test_slat_window_overlap
SLAT_WINDOW_OVERLAP :: 1.737

// The stripes are dark where the partial's average is this uncertain, in radians of its phase: the average 2.5
// times the noise in its band, about 8 dB
STROBE_SLATS_NOISE_RAD :: #config(STROBE_SLATS_NOISE_RAD, 0.4)

// What's left of the stripes under STROBE_SLATS_NOISE_RAD is multiplied by this: full where the partial's phase
// is uncertain by 0.16 radians or less, its average about 16 dB over the noise in its band, a fade as wide as
// the SNR fade's was. At 4 it was 2.5 dB wide, a partial near the noise blinked.
STROBE_SLATS_GAIN :: #config(STROBE_SLATS_GAIN, 1.67)

// Under this the measurements are dark, in digital silence they'd keep the last note as they fade
STROBE_SLATS_SILENCE_DBFS :: -80

// The stripes are lit by the slots' level eased toward each frame's over this long, see update_band_levels.
// Decided afresh every frame from a few periods, a note where the noise starts to gray it flips between full
// and gray. 0.1 s lit them later for no calmer look.
STROBE_SLATS_LEVEL_S :: #config(STROBE_SLATS_LEVEL_S, 0.05)

// The most of a track's own periods in a span, an 8× track's in a period of the note
SLAT_MAX_PERIODS :: 8

StrobeSlats :: struct {
    freq_hz:  [MAX_BANDS]f32, // the reference each track's spans were measured at, another starts them over
    periods:  [MAX_BANDS]int, // the track's own periods in a span, see slat_fold_periods
    clock:    i64, // the lock-in's sample clock after the samples so far, a gap starts every track over

    // Per track, the windows still open and the closed ones' measurements, see add_slat_measurement
    open:         [MAX_BANDS]SlatWindows,
    measurements: [MAX_BANDS]SlatMeasurements,
}

// The windows still open. The first closes at the end of the span the latest sample fell in, the others a span
// and two spans later.
SlatWindows :: struct {
    windows: [SLAT_WINDOW_SPANS]SlatWindow,
    turn:    f64, // where in the span the latest sample fell, a smaller one starts the next
}

// The samples so far times the window and a cosine and a sine of the track's own period
SlatWindow :: struct {
    cosine: f64,
    sine:   f64,
    weight: f64, // the window's weights added up
    spans:  f64, // how much of the window the samples covered, whole at SLAT_WINDOW_SPANS
}

// The measurements summed, each fading by the note's periods since, see slat_fade
SlatMeasurements :: struct {
    sum:          complex64, // the partials' peaks and phases, as a cosine and a sine
    weight:       f32, // how many, faded
    size:         f32, // each one's size
    size_squared: f32, // how many measurements the sums are worth by size, size² ÷ this

    // The sizes again, fading over STROBE_SLATS_RECENT_PERIODS, and how many
    recent_size:   f32,
    recent_weight: f32,
}

// The Blackman window at place, 0 to 1 across it
slat_window :: proc(place: f64) -> f64 {
    return slat_window_at(math.cos(math.TAU * place))
}

// The Blackman window from the cosine of how far across it a sample is, a turn across the whole window. Its
// second cosine is the first one's double angle, 2 cos² - 1.
slat_window_at :: #force_inline proc(cosine: f64) -> f64 {
    return 0.34 - 0.5 * cosine + 0.16 * cosine * cosine
}

// A point on the unit circle at angle radians, turned sample by sample instead of a cosine and a sine of each
phasor :: #force_inline proc(angle: f64) -> complex128 {
    return complex(math.cos(angle), math.sin(angle))
}

// How the sums change from one span to the next, the same for every span of a track over a frame, see slat_fade
SlatFade :: struct {
    turn:        complex64, // the turn times the fade, the sum's twiddle
    keep:        f32,
    recent_keep: f32, // over STROBE_SLATS_RECENT_PERIODS
}

// The older measurements fade by the note's periods in a span and turn by as far as the partial turned in it,
// turned radians the way the measurements go: off the track's frequency it goes round steadily, that's the
// drift and not noise. Turned back with a long memory a note 10 cents sharp grayed its 4× track.
slat_fade :: proc(note_periods: f32, turned: f32 = 0) -> SlatFade {
    keep := math.exp(-note_periods / STROBE_SLATS_MEMORY_PERIODS)
    return {
        turn = complex(math.cos(turned) * keep, math.sin(turned) * keep),
        keep = keep,
        recent_keep = math.exp(-note_periods / STROBE_SLATS_RECENT_PERIODS),
    }
}

// A window closed, its partial as a sine's peak and phase, into the sums, the older ones faded and turned
add_slat_measurement :: proc(sums: ^SlatMeasurements, measurement: complex64, fade: SlatFade) {
    size := abs(measurement)
    sums.sum = sums.sum * fade.turn + measurement
    sums.weight = sums.weight * fade.keep + 1
    sums.size = sums.size * fade.keep + size
    sums.size_squared = sums.size_squared * fade.keep * fade.keep + size * size
    sums.recent_size = sums.recent_size * fade.recent_keep + size
    sums.recent_weight = sums.recent_weight * fade.recent_keep + 1
}

// As many of the track's own periods as fit a whole number of the note's, its partial or three for a fifth.
// Every vernier track is on the note.
slat_fold_periods :: proc(band: PhaseBand, mode: StrobeMode) -> int {
    if mode != .HARMONIC do return 1

    for note_periods in 1 ..= 4 {
        periods := band.interval * f32(note_periods)
        if abs(periods - math.round(periods)) < 0.01 do return clamp(int(math.round(periods)), 1, SLAT_MAX_PERIODS)
    }
    return clamp(int(math.round(band.interval)), 1, SLAT_MAX_PERIODS)
}

// The lock-in's new samples into every measured track's windows, after run_phase_detection. Vernier mode's
// faster tracks copy the first one's level, see run_phase_detection.
fill_strobe_slats :: proc(self: ^StrobeSlats, lock_in: ^StrobeLockIn) {
    new_samples := min(lock_in.available, lock_in.buffer_len)
    if new_samples <= 0 do return

    samples := lock_in.sample_buffer[lock_in.buffer_len - new_samples:lock_in.buffer_len]
    first := lock_in.sample_clock - i64(new_samples) // the absolute index of samples[0]

    // A stall, a reset or skipped samples, the spans' phases don't carry on
    if first != self.clock do self^ = {}
    self.clock = lock_in.sample_clock

    for band, index in lock_in.bands {
        retune_slat_track(self, index, band, lock_in.mode)
        if !measures_band(lock_in, index) || !band.in_range do continue

        spans := slat_spans(band, self.periods[index], lock_in, first)
        fill_slat_windows(&self.open[index], &self.measurements[index], samples, spans)
    }
}

// A track measured at another reference, or over another number of its own periods, starts over
retune_slat_track :: proc(self: ^StrobeSlats, index: int, band: PhaseBand, mode: StrobeMode) {
    periods := slat_fold_periods(band, mode)
    if self.freq_hz[index] == band.freq_hz && self.periods[index] == periods do return

    self.open[index], self.measurements[index] = {}, {}
    self.freq_hz[index] = band.freq_hz
    self.periods[index] = periods
}

// One track's spans over a frame's new samples: where the samples fall in them, how the track's angle and the
// windows' turn sample by sample, and how the measurements fade and turn from one span to the next
SlatSpans :: struct {
    periods: int, // the track's own periods in a span, see slat_fold_periods
    step:    f64, // a sample's, in spans
    start:   f64, // where in its span the first new sample falls
    fade:    SlatFade,

    // The track's angle goes whole turns in a span, the windows' a third of one, each window a third further
    // along than the one opened after it
    track_step:     complex128,
    window_step:    complex128,
    window_offsets: [SLAT_WINDOW_SPANS]complex128,
}

// The note's periods in a span, and how far the partial turns in one by the lock-in's phase advance over the
// new samples, as the stripes move: a sine measured against a cosine and a sine of the track's own goes round
// the other way. Not the drift, it follows over tenths of a second, a note stepping 55 cents grayed the stripes
// for a moment.
slat_spans :: proc(band: PhaseBand, periods: int, lock_in: ^StrobeLockIn, first: i64) -> (spans: SlatSpans) {
    spans.periods = periods
    spans.step = f64(band.freq_hz) / f64(lock_in.sample_rate) / f64(periods)
    spans.start = math.mod(f64(first) * spans.step, 1)

    note_periods := f32(periods) * lock_in.base_freq_hz / band.freq_hz
    advance_per_sample := f64(band.phase_diff) / strobe_rescale(band.freq_hz) / f64(max(lock_in.available, 1))
    spans.fade = slat_fade(note_periods, -f32(advance_per_sample / spans.step))

    spans.track_step = phasor(math.TAU * f64(periods) * spans.step)
    spans.window_step = phasor(math.TAU * spans.step / SLAT_WINDOW_SPANS)
    for &window_offset, later in spans.window_offsets {
        window_offset = phasor(math.TAU * f64(SLAT_WINDOW_SPANS - 1 - later) / SLAT_WINDOW_SPANS)
    }
    return
}

// One track's new samples into its open windows. A span ends where the next starts over, the first window
// closes and the next one opens.
fill_slat_windows :: proc(open: ^SlatWindows, sums: ^SlatMeasurements, samples: []f32, spans: SlatSpans) {
    turns := slat_turns_at(spans.start, spans)

    for sample, offset in samples {
        turn := spans.start + f64(offset) * spans.step
        place := turn - math.floor(turn)
        if place < open.turn {
            close_slat_window(open, sums, spans.fade)
            turns = slat_turns_at(place, spans)
        }
        open.turn = place

        add_to_slat_windows(open, sample, turns, spans)
        turns.track *= spans.track_step
        turns.window *= spans.window_step
    }
}

// The track's angle and the windows' at a place in the span, set exactly where a span starts and turned sample
// by sample in between, see phasor
SlatTurns :: struct {
    track:  complex128,
    window: complex128,
}

slat_turns_at :: proc(place: f64, spans: SlatSpans) -> SlatTurns {
    return {
        track = phasor(math.TAU * f64(spans.periods) * place),
        window = phasor(math.TAU * place / SLAT_WINDOW_SPANS),
    }
}

// The first window closes, measured if it was whole, not one cut by a reset, and the next one opens
close_slat_window :: proc(open: ^SlatWindows, sums: ^SlatMeasurements, fade: SlatFade) {
    closing := open.windows[0]
    if closing.spans > SLAT_WINDOW_SPANS - 0.1 {
        measurement := complex(f32(2 * closing.cosine / closing.weight), f32(2 * closing.sine / closing.weight))
        add_slat_measurement(sums, measurement, fade)
    }
    copy(open.windows[:], open.windows[1:])
    open.windows[SLAT_WINDOW_SPANS - 1] = {}
}

// A sample into each open window at its own place, the first one's last span. Every sample of every track,
// inlined.
add_to_slat_windows :: #force_inline proc(open: ^SlatWindows, sample: f32, turns: SlatTurns, spans: SlatSpans) {
    cosine, sine := f64(sample) * real(turns.track), f64(sample) * imag(turns.track)
    for &window, later in open.windows {
        window_weight := slat_window_at(real(turns.window * spans.window_offsets[later]))
        window.cosine += window_weight * cosine
        window.sine += window_weight * sine
        window.weight += window_weight
        window.spans += spans.step
    }
}

// Every measured track's level from its slots after fill_strobe_slats, and how lit its stripes are, the level
// eased over the new samples. Dark all the way in the end, a dark strobe's glow is drawn again as it was.
update_band_levels :: proc(self: ^StrobeLockIn) {
    elapsed_s := f32(self.available) / self.sample_rate
    ease := 1 - math.exp(-elapsed_s / STROBE_SLATS_LEVEL_S)

    for &band, index in self.bands {
        if !measures_band(self, index) do continue

        band.slat_level = strobe_slat_level(&self.slats, index) if band.in_range else 0
        band.visibility += ease * (band.slat_level - band.visibility)
        if band.slat_level == 0 && band.visibility < 0.001 do band.visibility = 0
    }
}

// How bright one track's stripes are, 0 gray to 1 full: how sure the partial's phase is over the measurements.
// Each window measures the partial, the note's other partials fall in its nulls. Noise near the track's own
// frequency scatters the measurements' directions, and their average is as uncertain as that scatter over how
// many measurements it holds, in radians near enough. By direction, each measurement as much as its size: an
// attack's first windows only partly hold the note and grow into it, they agree and aren't scatter. Gray at
// STROBE_SLATS_NOISE_RAD, as much of the way as STROBE_SLATS_GAIN allows. All gray before two measurements' worth
// came in, in silence and once the last periods went silent, see STROBE_SLATS_RECENT_PERIODS.
strobe_slat_level :: proc(self: ^StrobeSlats, band_index: int) -> f32 {
    sums := self.measurements[band_index]
    if sums.weight <= 0 || sums.size_squared <= 0 do return 0

    // Weighed by size, an attack's small first measurements count for less
    count := sums.size * sums.size / sums.size_squared
    if count < 2 * SLAT_WINDOW_OVERLAP do return 0

    length := abs(sums.sum)
    height := length / sums.weight
    if height <= 0 || 20 * math.log10(height) < STROBE_SLATS_SILENCE_DBFS do return 0

    recent := sums.recent_size / sums.recent_weight
    if recent <= 0 || 20 * math.log10(recent) < STROBE_SLATS_SILENCE_DBFS do return 0

    // How far their directions agree, 1 all one way, and their scatter around it. Noise moves a measurement's size
    // as much as its direction, the direction alone scatters half as much as the measurement did: doubled, a
    // steady partial in noise is as sure as before. Neighbours share noise, the scatter is smaller than one
    // measurement's by SLAT_WINDOW_OVERLAP of count, and the average holds count / SLAT_WINDOW_OVERLAP
    // measurements' worth. With no overlap it's the scatter over count - 1.
    agreement := length / sums.size
    spread := 2 * max(1 - agreement * agreement, 0)
    uncertainty := math.sqrt(spread * SLAT_WINDOW_OVERLAP / (count - SLAT_WINDOW_OVERLAP)) / agreement
    return min(STROBE_SLATS_GAIN * max(1 - uncertainty / STROBE_SLATS_NOISE_RAD, 0), 1)
}
