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

    Phase comparator

    Lock-in amplifier: runs a single bin DFT over the newest samples and demodulates it against a
    reference oscillator running at the target frequency on an absolute sample clock. In tune, the
    resulting phase stands still; a detuned signal makes it rotate at the frequency difference.
    The strobe turns by that phase as measured. The cents of each track are its rate, a least squares
    line fitted through it for a steady readout.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:slice"
import "core:testing"
import "core:time"


MIN_STROBE_FREQ_HZ :: 16.0
MAX_BANDS :: 5 // the strobe's tracks, the config holds as many
// The sample buffer, the window for the lowest note at a quarter of a semitone fits in it, 262 144 samples
// at 48 kHz
MAX_WINDOW_S :: 5.5

// A band goes up to 90% of Nyquist (21.6 kHz at 48 kHz), above it the audio can't hold the frequency and
// the input filters roll off before that anyway
MAX_BAND_NORM_FREQ :: 0.45

// The strobe phase of each band is rescaled to this frequency so that every note spins at the same
// rate per cent of detuning
STROBE_REFERENCE_HZ :: 656.5

// The cents of each track are the slope of a least squares line through the phase, older measurements
// weighted down with a time constant, readout_fit_s, this by default. Its weight on the rate of each moment
// peaks that long ago and is twice that on average, steady but a turned peg shows that much later than on
// the stripes.
READOUT_FIT_S :: 0.15

// The drift averages the chunks' phase advances this long, about the window of the old narrow bands a
// semitone wide. A voice's waver evens out like it did in their window, the stripes fade by how far off the
// note is and not by how much it wavers.
DRIFT_SMOOTH_S :: 0.3

// The readout's average starts over on each pluck, the previous note's rate doesn't carry over. It follows
// the attack like the stripes do, a plucked string glides down from sharp.
ONSET_RATIO :: 1.5 // amp jump over the slow envelope that counts as a new pluck (~3.5 dB)
ONSET_ENVELOPE_TIME_S :: 0.3


StrobeMode :: enum {
    HARMONIC, // a track per partial
    VERNIER, // every track on the fundamental, each one turning faster than the one under it
}


PhaseBand :: struct {
    freq_hz:      f32,
    interval:     f32, // of the base note, 1 for the fundamental, 1.5 for the fifth, 2 for the octave
    offset_cents: f32, // harmonic mode, the track stands still this far off the exact partial, eg a stretched octave
    speed_scale:  f32, // harmonic mode, on top of the track's speed, 1 leaves it as is
    in_range:     bool, // below MAX_BAND_NORM_FREQ, a high partial of a high note may not be
    note:         Note,
    norm_freq:    f32,
    dft:          SingleFreqDFT,
    time_stretch: f32, // samples in a period of the base note, the strobe shader's time scale
    phase:        f32, // measured lock-in phase, relative to the reference oscillator
    amp:          f32,
    phase_diff:   f32, // strobe phase advance since the previous frame (normalized to STROBE_REFERENCE_HZ)
    err_cents:    f32, // of the averaged rate
    drift_hz:     f32, // the chunks' phase advances as a frequency off the track's, smoothed, see DRIFT_SMOOTH_S
    drift_cents:  f32, // and how far off that is, unsigned
    scaled_phase: f32, // the strobe's phase, phase_diff times the speed added up
    speed:        f32, // under 1 the strobe turns slower, over 1 faster
    snr_db:       f32,
    noise_floor:  NoiseFloor,

    // Lock-in reference oscillator frequency, radians per sample
    ref_omega:    f64,

    // The readout, the phase's rate vs the reference (rad/sample) fitted since the last pluck
    has_phase:    bool, // phase holds the previous frame's measurement, off until the first after a reset
    rate:         f64,
    rate_time_s:  f32, // fitted this long
    fit:          RateFit,

    // Onset detection
    envelope:     f32,
    onset:        bool, // a new pluck in this frame
}

// The weighted sums of the least squares line through the phase since the last pluck. The newest
// measurement sits at time 0 and phase 0, the older ones at negative times, so the sums stay small.
RateFit :: struct {
    weight:     f64,
    time:       f64, // samples
    time_sq:    f64,
    phase:      f64, // rad, unwrapped
    time_phase: f64,
}


PhaseComparator :: struct {
    using node:       AudioCaptureNode,
    base_freq_hz:     f32,
    speed_multiplier: f32, // vernier mode, each track turns this much faster than the one under it
    sample_buffer:    []f32,
    bands:            [dynamic]PhaseBand,
    mode:             StrobeMode,
    band_cents:       int, // the width of each track's band, DFT_RESOLUTION_CENTS, set_phase_comparator_freq retunes it
    readout_fit_s:    f32, // the time constant of the readout's fit, READOUT_FIT_S, longer is steadier and later
    available:        int, // the new samples of the latest run_phase_detection

    // Absolute index of the sample just past the end of the newest window, i.e. the lock-in clock
    sample_clock:     i64,

    // Number of valid samples in sample_buffer, the newest sample sits at sample_buffer[buffer_len - 1]
    buffer_len:       int,
}


init_phase_comparator :: proc(
    base_freq_hz: f32,
    strobe_intervals: []f32,
    mode: StrobeMode,
    sample_rate: f32 = DEFAULT_SAMPLE_RATE,
) -> ^PhaseComparator {
    self := new(PhaseComparator)
    init_audio_capture_node(self, "phase-tracker", sample_rate)
    self.sample_buffer = make([]f32, sample_buffer_size(sample_rate))
    self.mode = mode
    self.base_freq_hz = base_freq_hz
    self.band_cents = DFT_RESOLUTION_CENTS
    self.readout_fit_s = READOUT_FIT_S

    for interval in strobe_intervals {
        if interval >= 1.0 do append_phase_band(self, interval)
    }
    return self
}


destroy_phase_comparator :: proc(self: ^PhaseComparator) {
    destroy_audio_capture_node(self)
    delete(self.sample_buffer)
    for &band in self.bands do destroy_phase_band(&band)

    delete(self.bands)
    free(self)
}

destroy_phase_band :: proc(band: ^PhaseBand) {
    destroy_dft(&band.dft)
}

// The longest window and a frame's new samples, see MAX_WINDOW_S and MAX_FRAME_S
sample_buffer_size :: proc(sample_rate: f32) -> int {
    return int(math.ceil((MAX_WINDOW_S + MAX_FRAME_S) * sample_rate))
}

// The input opened at another rate. Everything starts over like for another input, see
// reset_phase_comparator, and set_phase_comparator_freq has to size the windows for it before the next run.
set_phase_comparator_sample_rate :: proc(self: ^PhaseComparator, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    delete(self.sample_buffer)
    self.sample_buffer = make([]f32, sample_buffer_size(sample_rate))
    self.buffer_len = 0
    reset_phase_comparator(self)
}

// Vernier mode measures the first band only, the others show it at other speeds
measures_band :: proc(self: ^PhaseComparator, band_index: int) -> bool {
    return self.mode == .HARMONIC || band_index == 0
}

// A new band on top, set_phase_comparator_freq tunes it
append_phase_band :: proc(self: ^PhaseComparator, interval: f32) {
    assert(len(self.bands) < MAX_BANDS, "more tracks than MAX_BANDS")
    band := PhaseBand{}
    band.interval = interval
    band.speed_scale = 1
    band.noise_floor = init_noise_floor()
    append(&self.bands, band)
}

// Like init_phase_comparator, a band per interval of 1 or more, the rest are padding. Adds or removes bands
// on top to match. Kept in vernier mode too, for switching back to harmonic mode.
// The partial, target offset and speed of each track, the offsets and speeds line up with the intervals.
// Takes effect with the next set_phase_comparator_freq.
set_phase_comparator_tracks :: proc(
    self: ^PhaseComparator,
    strobe_intervals: []f32,
    offsets_cents: []f32,
    speeds: []f32,
) {
    count := 0
    for interval in strobe_intervals {
        if interval >= 1.0 do count += 1
    }
    for len(self.bands) > count {
        band := pop(&self.bands)
        destroy_phase_band(&band)
    }
    for len(self.bands) < count do append_phase_band(self, 1)

    band_index := 0
    for interval, slot in strobe_intervals {
        if interval < 1.0 do continue

        band := &self.bands[band_index]
        band.interval = interval
        band.offset_cents = offsets_cents[slot]

        // a missing speed would freeze the track
        band.speed_scale = speeds[slot] if speeds[slot] > 0 else 1
        band_index += 1
    }
}

// Harmonic mode turns each track by its partial and its own speed, vernier mode each one faster than the one
// under it
set_phase_comparator_speed :: proc(self: ^PhaseComparator, base_speed: f32) {
    speed := base_speed
    for &band in self.bands {
        switch self.mode {
        case .HARMONIC:
            band.speed = base_speed * band.interval * band.speed_scale
        case .VERNIER:
            band.speed = speed
            speed *= self.speed_multiplier
        }
    }
}


// The window size of a band, a semitone wide. The comb keeps the other partials out, the readout's fit
// steadies the cents, a narrower band only buys less noise for more lag.
DFT_RESOLUTION_CENTS :: 100

// The phase is measured this many times a period of the strobe's note through the new samples. Between two
// the phase moves by less than half a turn for a sound up to HOPS_PER_PERIOD / 2 times the note's frequency
// off, an octave down or up on any track. A strong note far off still leaks into a track, its drift has to
// read how far, see hears_note.
HOPS_PER_PERIOD :: 4

// The new samples a frame walks through on top of the longest window, more and its oldest are skipped. 4096
// samples at 48 kHz.
MAX_FRAME_S :: 0.085

// Retunes every band to base_freq_hz, the tracks restart. The ring buffer stays, the samples are still valid
// and the stream stays contiguous, and so do the noise floors, the background doesn't change with the note.
set_phase_comparator_freq :: proc(
    self: ^PhaseComparator,
    base_freq_hz: f32,
    pitch_standard: f32,
    base_speed: f32,
    speed_multiplier: f32,
    mode: StrobeMode,
) {
    if base_freq_hz <= MIN_STROBE_FREQ_HZ {
        fmt.printfln("%.1f Hz is too low for the strobe, the lowest is %.1f Hz", base_freq_hz, MIN_STROBE_FREQ_HZ)
        return
    }

    self.base_freq_hz = base_freq_hz
    self.mode = mode
    self.speed_multiplier = speed_multiplier

    // Every track gets the fundamental's window. Sized in cents of its own partial an upper track's window would
    // be shorter, its band wider in Hz for a weaker partial, and it shimmers. Built once, the tracks only turn it
    // to their own frequency.
    comb_samples := comb_periods(self.bands[:], mode) * self.sample_rate / base_freq_hz
    gamma_size := dft_window_size(base_freq_hz, self.sample_rate, self.band_cents)
    window := gamma_comb_window(gamma_size, comb_samples)

    for &band, band_index in self.bands {
        band.time_stretch = self.sample_rate / base_freq_hz
        restart_band(&band)

        switch self.mode {
        case .HARMONIC:
            // Named after the exact partial, a big offset would otherwise land on the next note
            band.note = freq_to_note(band.interval * base_freq_hz, pitch_standard)
            band.freq_hz = freq_at_cents(band.interval * base_freq_hz, band.offset_cents)
        case .VERNIER:
            band.freq_hz = base_freq_hz
            band.note = freq_to_note(band.freq_hz, pitch_standard)
        }
        band.norm_freq = band.freq_hz / self.sample_rate
        band.in_range = band.norm_freq < MAX_BAND_NORM_FREQ
        band.ref_omega = math.TAU * f64(band.freq_hz) / f64(self.sample_rate)

        if measures_band(self, band_index) do set_dft_freq(&band.dft, band.norm_freq, window)
    }

    set_phase_comparator_speed(self, base_speed)
}

// The comb's box spans enough periods of the note that every track's partials land on its nulls,
// two for a fifth (3/2): with a chord the root's partials and the fifth's are all multiples of half the root
comb_periods :: proc(bands: []PhaseBand, mode: StrobeMode) -> f32 {
    if mode != .HARMONIC do return 1

    search: for periods: f32 = 1; periods < 4; periods += 1 {
        for band in bands {
            multiple := band.interval * periods
            if abs(multiple - math.round(multiple)) > 0.01 do continue search
        }
        return periods
    }
    return 4
}

// The measurements start over, for another note or another input
restart_band :: proc(band: ^PhaseBand) {
    band.phase = 0
    band.has_phase = false
    band.rate = 0
    band.rate_time_s = 0
    band.fit = {}
    band.drift_hz = 0
    band.drift_cents = 0
    band.envelope = 0
    band.onset = false
}

// Another input's signal is unrelated to the previous one's, everything starts over like at launch: the
// windows on silence, so the noise floors wait for the new input to fill them before they learn it
reset_phase_comparator :: proc(self: ^PhaseComparator) {
    slice.zero(self.sample_buffer)
    self.sample_clock = 0
    for &band in self.bands {
        restart_band(&band)
        reset_noise_floor(&band.noise_floor)
    }
}

// Handle the jump from 2π to 0 or 0 to 2π (both rotation directions), wraps to -π..π
wrap_phase :: proc(phase: f64) -> f64 {
    return phase - math.TAU * math.round(phase / math.TAU)
}


// Measures the new samples, nothing changes without any. is_tonal is a clear pitch from the pitch detection,
// the bands' noise floors don't learn it as the background.
run_phase_detection :: proc(self: ^PhaseComparator, is_tonal := false) {
    // The window every track shares, see set_phase_comparator_freq, and a frame's new samples before it for
    // the hops. The newest samples come in without delay.
    window_size := self.bands[0].dft.window_size
    resize_sample_buffer(self, window_size + int(MAX_FRAME_S * self.sample_rate))
    read, elapsed := audio_capture_read(self, self.sample_buffer[:self.buffer_len])
    if read == 0 && elapsed > 0 {
        // A stall, the buffer is silent and the tracks start over on the audio after it. The clock too, the
        // noise floors don't learn the silence while the window fills again.
        self.sample_clock = 0
        for &band in self.bands do restart_band(&band)

        return
    }
    if read == 0 do return

    self.available = int(elapsed)
    self.sample_clock += elapsed

    // The tracks that measure, all at once. Not one that a retune too low for the strobe left on another
    // window, see set_phase_comparator_freq.
    measured: [MAX_BANDS]^PhaseBand
    measured_count := 0
    for &band, band_index in self.bands {
        if measures_band(self, band_index) && band.in_range && band.dft.window_size == window_size {
            measured[measured_count] = &band
            measured_count += 1
        }
    }
    determine_band_phases(self, measured[:measured_count])
    for band in measured[:measured_count] do update_band_noise_floor(self, band, is_tonal)

    for &band, band_index in self.bands {
        if !measures_band(self, band_index) {
            // Vernier mode, the first track's measurement at another speed
            base_band := self.bands[0]
            band.amp, band.envelope, band.onset = base_band.amp, base_band.envelope, base_band.onset
            band.phase_diff, band.rate, band.err_cents = base_band.phase_diff, base_band.rate, base_band.err_cents
            band.drift_hz, band.drift_cents = base_band.drift_hz, base_band.drift_cents
            band.noise_floor, band.snr_db = base_band.noise_floor, base_band.snr_db
            band.scaled_phase -= band.phase_diff * band.speed
        } else if !band.in_range {
            // Nothing to measure up there, quiet so the track stays dark
            band.amp = 0
            band.snr_db = 0
            band.phase_diff = 0
        }
    }
}


// Samples for a frequency resolution of cents_resolution. A fixed window has the same resolution in Hz
// everywhere, a higher note needs fewer samples for as many cents.
dft_window_size :: proc(freq_hz: f32, samplerate: f32, cents_resolution: int) -> int {
    ratio := libc.exp2(f32(cents_resolution) / 1200.0)
    freq_resolution := freq_hz * (ratio - 1.0)
    return int(math.ceil(samplerate / freq_resolution))
}


@(test)
test_dft_window_size :: proc(t: ^testing.T) {
    testing.expect_value(t, dft_window_size(110.0, 48_000, 100), 7339)
    testing.expect_value(t, dft_window_size(440.0, 48_000, 100), 1835)
    testing.expect_value(t, dft_window_size(4186.0, 48_000, 100), 193)
}


@(test)
test_track_offset_and_speed :: proc(t: ^testing.T) {
    intervals := []f32{1, 2, 3}
    self := init_phase_comparator(110, intervals, .HARMONIC)
    defer destroy_phase_comparator(self)

    // A wide octave, a slower twelfth
    set_phase_comparator_tracks(self, intervals, {0, 30, 0}, {1, 1, 0.5})
    set_phase_comparator_freq(self, 110, 440, 0.01, 2, .HARMONIC)

    testing.expect(t, abs(self.bands[1].freq_hz - 220 * math.pow(f32(2), 30.0 / 1200)) < 0.001)
    testing.expect_value(t, self.bands[1].note.name, 'A')
    testing.expect_value(t, self.bands[1].note.octave, 3)
    testing.expect(t, abs(self.bands[2].speed - 0.01 * 3 * 0.5) < 1e-6)

    testing.expect(t, self.bands[2].in_range)

    // 8× of C8 is past what 48 kHz can hold
    set_phase_comparator_tracks(self, {1, 2, 8}, {0, 0, 0}, {1, 1, 1})
    set_phase_comparator_freq(self, 4186, 440, 0.01, 2, .HARMONIC)
    testing.expect(t, self.bands[1].in_range)
    testing.expect(t, !self.bands[2].in_range)

    // A missing speed leaves the track at its normal speed
    set_phase_comparator_tracks(self, intervals, {0, 0, 0}, {1, 1, 0})
    set_phase_comparator_speed(self, 0.01)
    testing.expect(t, abs(self.bands[2].speed - 0.01 * 3) < 1e-6)

    // Tracks added and removed on top
    set_phase_comparator_tracks(self, {1, 2, 3, 4, 5}, {0, 0, 0, 0, 0}, {1, 1, 1, 1, 1})
    set_phase_comparator_freq(self, 110, 440, 0.01, 2, .HARMONIC)
    testing.expect_value(t, len(self.bands), 5)
    testing.expect(t, abs(self.bands[4].freq_hz - 550) < 0.001)
    testing.expect(t, self.bands[4].dft.window_size > 0)

    set_phase_comparator_tracks(self, {1, 2, 0, 0, 0}, {0, 0, 0, 0, 0}, {1, 1, 1, 1, 1})
    testing.expect_value(t, len(self.bands), 2)
    testing.expect_value(t, self.bands[1].interval, 2)
}


// Keep the newest samples aligned to the end of the buffer when the window size changes, so the buffer
// always holds one contiguous stretch of audio ending at sample_clock.
resize_sample_buffer :: proc(self: ^PhaseComparator, size: int) {
    if size == self.buffer_len do return

    if size < self.buffer_len {
        copy(self.sample_buffer[:size], self.sample_buffer[self.buffer_len - size:self.buffer_len])
    } else {
        copy(self.sample_buffer[size - self.buffer_len:size], self.sample_buffer[:self.buffer_len])

        // Older audio is unknown, fill with silence
        slice.zero(self.sample_buffer[:size - self.buffer_len])
    }
    self.buffer_len = size
}


// A single bin DFT over the newest samples for each of the tracks, demodulated against its reference
// oscillator. The tracks share the window, so they share the hops too, and each hop's DFTs run together.
//
// The strobe turns by the measured phase, the shortest way from the previous frame's, nothing else carries
// over between frames. Once a frame a track more than half the frame rate off would alias, 30 Hz at 60 fps, a
// high note's partial is that far off within a semitone, and a low note an octave off leaks in that far. So
// the phase is measured a hop apart through the new samples, see HOPS_PER_PERIOD, each step the shortest way
// and the frame's advance their sum. The newest window last, its DFT is the track's amplitude. No advance on
// the first frame after a reset, the phase before it is arbitrary.
determine_band_phases :: proc(self: ^PhaseComparator, bands: []^PhaseBand) {
    if len(bands) == 0 do return

    // Lock-in / heterodyne: the DFT twiddles restart at 0 for every window, so rotate the result by
    // the reference oscillator phase at the window start (absolute sample index).
    // A signal exactly at the reference frequency then yields a constant phase.
    lock_in_phase :: proc(band: ^PhaseBand, window_start: i64) -> f32 {
        ref_phase := math.mod(f64(window_start) * band.ref_omega, math.TAU)
        lock_in := complex128(band.dft.dft) * complex(math.cos(ref_phase), -math.sin(ref_phase))
        return f32(cmplx.phase(lock_in))
    }

    window_size := bands[0].dft.window_size
    span := min(self.available, self.buffer_len - window_size)
    hop_size := self.sample_rate / (HOPS_PER_PERIOD * self.base_freq_hz)

    had_phase: [MAX_BANDS]bool
    dfts: [MAX_BANDS]^SingleFreqDFT
    for band, index in bands {
        had_phase[index] = band.has_phase
        dfts[index] = &band.dft
    }

    // The tracks start over together, after a reset there's nothing to hop from
    hops := max(int(math.ceil(f32(span) / hop_size)), 1) if bands[0].has_phase else 1

    phase_advances: [MAX_BANDS]f64
    for hop in 1 ..= hops {
        // Up to the newest samples, i.e. the end of the buffer
        window_end := self.buffer_len - span + span * hop / hops
        run_single_dfts(dfts[:len(bands)], self.sample_buffer[window_end - window_size:window_end])

        window_start := self.sample_clock - i64(self.buffer_len - window_end) - i64(window_size)
        for band, index in bands {
            hop_phase := lock_in_phase(band, window_start)
            if had_phase[index] do phase_advances[index] += wrap_phase(f64(hop_phase - band.phase))
            band.phase = hop_phase
        }
    }

    for band, index in bands {
        band.amp = abs(band.dft.dft)
        band.has_phase = true
        advance_band(self, band, phase_advances[index], had_phase[index])
    }
}

// The track's onset, rate, drift and the strobe's turn from the frame's phase advance
advance_band :: proc(self: ^PhaseComparator, band: ^PhaseBand, phase_advance: f64, had_phase: bool) {
    update_onset(self, band)

    // Rescaled so all notes spin at the same rate per cent
    band.phase_diff = f32(phase_advance * strobe_rescale(band.freq_hz))

    step := f64(self.available)
    sample_rate := f64(self.sample_rate)
    if had_phase {
        decay := math.exp(-step / (f64(self.readout_fit_s) * sample_rate))
        shift_fit(&band.fit, step, phase_advance, decay)

        // How far off the track is lately, the advances averaged with their sign, a waver on the note evens out
        // like it did in a narrow band's window. Noise's random advances even out too, the SNR fades its
        // stripes. An octave flat is as far as it goes, noise on a low track can advance by more than its
        // frequency.
        drift_hz := f32(phase_advance / step * sample_rate / math.TAU)
        alpha := f32(1 - math.exp(-step / (DRIFT_SMOOTH_S * sample_rate)))
        band.drift_hz += alpha * (drift_hz - band.drift_hz)
        band.drift_cents = abs(cents_deviation(max(band.freq_hz + band.drift_hz, 0.5 * band.freq_hz), band.freq_hz))
    }

    // The readout fits the rate while the stripes fully show, a fading note keeps the last of it, the dimming
    // stripes drift with the noise. Each measurement is weighted by its samples, a stalled frame counts for as
    // long as it took, and by the partial's power against its envelope. Where two components beat, the phase
    // swings fast through the dips; weighted by power the rate settles on their mean pitch by energy instead
    // of following the swings. Against the envelope, not the absolute power: a decaying note's newest
    // moments are its weakest, and they still count as much. A single one has no slope yet, the rate is its
    // advance.
    if had_phase && band.snr_db >= READOUT_MIN_SNR_DB {
        if band.rate_time_s == 0 do band.fit = {}

        band.rate_time_s += f32(self.available) / self.sample_rate

        // The new measurement at time 0 and phase 0 only adds its weight
        level := f64(band.amp / band.envelope) if band.envelope > 0 else 1
        band.fit.weight += step * level * level
        slope, has_slope := fit_slope(band.fit)
        band.rate = slope if has_slope else phase_advance / step
    }
    // An octave flat is as far as it goes, like the drift: noise on a low track can fit a rate past its own
    // frequency, and a negative frequency has no cents
    freq_diff_hz := f32(band.rate * sample_rate / math.TAU)
    band.err_cents = cents_deviation(max(band.freq_hz + freq_diff_hz, 0.5 * band.freq_hz), band.freq_hz)

    // The strobe turns by the phase times the track's speed
    band.scaled_phase -= band.phase_diff * band.speed

    // The fit's measurements move back by step samples and down by the phase advance, so the new one
    // comes in at 0, and the older ones weigh less by decay
    shift_fit :: proc(fit: ^RateFit, step, phase_advance, decay: f64) {
        fit.time_phase += step * phase_advance * fit.weight - step * fit.phase - phase_advance * fit.time
        fit.time_sq += step * step * fit.weight - 2 * step * fit.time
        fit.time -= step * fit.weight
        fit.phase -= phase_advance * fit.weight
        fit^ = {fit.weight * decay, fit.time * decay, fit.time_sq * decay, fit.phase * decay, fit.time_phase * decay}
    }

    // The least squares slope in rad per sample, none while the measurements have no spread in time
    fit_slope :: proc(fit: RateFit) -> (slope: f64, ok: bool) {
        time_variance := fit.weight * fit.time_sq - fit.time * fit.time
        if time_variance <= 0 do return 0, false

        return (fit.weight * fit.time_phase - fit.time * fit.phase) / time_variance, true
    }
}

// A phase advance at freq_hz times this turns the strobe as fast per cent as every other note
strobe_rescale :: proc(freq_hz: f32) -> f64 {
    return STROBE_REFERENCE_HZ / f64(freq_hz)
}

// Without audio the strobe stops going on after this long
STROBE_AHEAD_MAX_S :: 0.03

// How fast the strobe turns at the readout's rate, radians of the track a second, the way scaled_phase goes
strobe_phase_rate :: proc(self: ^PhaseComparator, band: PhaseBand) -> f32 {
    radians_per_s := band.rate * f64(self.sample_rate) * strobe_rescale(band.freq_hz)
    return -f32(radians_per_s) * band.speed
}

// How far the strobe turned since its newest sample came in, at the readout's rate. The audio comes in chunks
// that don't line up with the display's frames, 10 ms ones on a Mac at 120 Hz: a frame in six gets none and
// the others a chunk and a bit, a steady drift drawn as measured steps and stalls. Drawn this far ahead it
// moves evenly, and the next measurement takes over where it is.
strobe_phase_ahead :: proc(self: ^PhaseComparator, band: PhaseBand) -> f32 {
    age := min(time.duration_seconds(time.tick_since(self.newest_tick)), STROBE_AHEAD_MAX_S)
    return strobe_phase_rate(self, band) * f32(age)
}


// Detect a new pluck (sudden amplitude jump), the readout's average starts over. The envelope jumps along,
// while the attack rises through the window each jump starts it over again.
update_onset :: proc(self: ^PhaseComparator, band: ^PhaseBand) {
    is_loud := band.snr_db > NOISE_FLOOR_SNR_DB_THRESHOLD
    band.onset = is_loud && band.amp > ONSET_RATIO * band.envelope
    if band.onset {
        band.rate_time_s = 0
        band.envelope = band.amp
        return
    }

    alpha := 1.0 - math.exp(-f32(self.available) / (ONSET_ENVELOPE_TIME_S * self.sample_rate))
    band.envelope += alpha * (band.amp - band.envelope)
}


// The stripes fade in between these SNRs, below it's the background noise (it stays under ~10 dB)
STROBE_FADE_SNR_DB :: [2]f32{8, 16}

// The readout follows a track this loud, where its stripes are fully there
READOUT_MIN_SNR_DB :: STROBE_FADE_SNR_DB[1]
READOUT_WEAK_FUNDAMENTAL_DB :: 20 // this far under the loudest partial the fundamental gives way to it
// The track's own reading this far off its partial, as far as the tracks were measured to read, see
// sandbox/accuracy and sandbox/recordings. Further out the readout has none.
READOUT_RANGE_CENTS :: 50
READOUT_SETTLE_S :: 0.05 // the track's fit since the pluck before the readout follows it

// The track the readout follows, the fundamental. A weak or missing fundamental gives way to the loudest
// partial. The partials read a few cents apart, so once its track is ready the readout stays on it and
// keeps its last reading as it fades, until a pluck or another note starts the tracks over. Only a partial
// still ringing this far over it takes the readout on, e.g. a low string's fundamental dies down first.
// Only an octave track reads out, the note is named after the partial it measures, see readout_octaves.
// -1 for none.
//
// ready once its track has fitted a little since the pluck, until then the readout is the pitch detection's.
strobe_readout_track :: proc(self: ^PhaseComparator, current: int) -> (track: int, ready: bool) {
    settled :: proc(band: PhaseBand) -> bool {
        return band.rate_time_s >= READOUT_SETTLE_S
    }

    // Vernier mode measures the first track, the others show it at other speeds
    count := 1 if self.mode == .VERNIER else len(self.bands)

    loudest, fundamental := readout_candidates(self)
    plucked := strobe_plucked(self)

    // Held, unless a pluck brings another track to pick or the held one fades under a ringing partial
    held := current >= 0 && current < count && settled(self.bands[current])
    if held && !plucked {
        faded := loudest >= 0 && self.bands[loudest].snr_db - self.bands[current].snr_db >= READOUT_WEAK_FUNDAMENTAL_DB
        if !faded do return current, true

        return loudest, settled(self.bands[loudest])
    }

    if loudest < 0 do return -1, false

    track = loudest
    if fundamental >= 0 && self.bands[loudest].snr_db - self.bands[fundamental].snr_db < READOUT_WEAK_FUNDAMENTAL_DB {
        track = fundamental
    }
    return track, settled(self.bands[track])
}

// The loudest track the readout can follow and the fundamental's, -1 for none
readout_candidates :: proc(self: ^PhaseComparator) -> (loudest, fundamental: int) {
    loudest, fundamental = -1, -1

    // Vernier mode measures the first track, the others show it at other speeds
    count := 1 if self.mode == .VERNIER else len(self.bands)
    for band, index in self.bands[:count] {
        if !is_octave_track(band) || !hears_note(band) || band.snr_db < READOUT_MIN_SNR_DB do continue
        if loudest < 0 || band.snr_db > self.bands[loudest].snr_db do loudest = index
        if band.interval == 1 do fundamental = index
    }
    return
}

// A pluck lifts the loudest partial, a faint one's level wobbling isn't one
strobe_plucked :: proc(self: ^PhaseComparator) -> bool {
    loudest, _ := readout_candidates(self)
    return loudest >= 0 && self.bands[loudest].onset
}

// The fundamental's or an octave's track, the others' partials are another note, e.g. a fifth
is_octave_track :: proc(band: PhaseBand) -> bool {
    octaves := math.log2(band.interval)
    return band.interval > 0 && abs(octaves - math.round(octaves)) < 0.01
}

// The octaves the readout's track is over the tuner's note, the note it measures is named that much higher.
// From the track's frequency, a strobe kept an octave off the note has its octave track on the note.
readout_octaves :: proc(band: PhaseBand, note_freq_hz: f32) -> int {
    return int(math.round(math.log2(band.freq_hz / note_freq_hz)))
}

@(test)
test_readout_track :: proc(t: ^testing.T) {
    self := init_phase_comparator(123.47, {1, 2, 4}, .HARMONIC)
    defer destroy_phase_comparator(self)

    set_phase_comparator_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)

    // Every track settled on the note, the fundamental under the 2nd harmonic but not by much
    snrs := [?]f32{90, 95, 30}
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        band.snr_db = snrs[index]
    }
    track, ready := strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)
    testing.expect(t, ready)

    // A faint partial's level wobbling isn't a pluck
    self.bands[2].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    self.bands[2].onset = false

    // The fundamental dies down under the 2nd harmonic still ringing, the readout goes on with that one, a
    // B3 for the B2
    self.bands[0].snr_db = 70
    track, ready = strobe_readout_track(self, track)
    testing.expect_value(t, track, 1)
    testing.expect(t, ready)
    testing.expect_value(t, readout_octaves(self.bands[track], 123.47), 1)

    // A pluck on the loudest track picks again, the fundamental back up
    self.bands[0].snr_db = 92
    self.bands[1].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)

    // A twelfth isn't an octave, it never reads out however loud
    set_phase_comparator_tracks(self, {1, 3}, {0, 0}, {1, 1})
    set_phase_comparator_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        band.snr_db = 50 if index == 0 else 90
    }
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)
}

// A track hears its note while it drifts less than a semitone, as wide as its window by default. Further
// out it's another note leaking in.
hears_note :: proc(band: PhaseBand) -> bool {
    return band.in_range && band.drift_cents <= DFT_RESOLUTION_CENTS
}

// Whether any track's stripes are at least half faded in, the note is still ringing. The background noise
// stays under it.
strobe_shows_note :: proc(self: ^PhaseComparator) -> bool {
    fade := STROBE_FADE_SNR_DB
    for band in self.bands {
        if hears_note(band) && band.snr_db >= 0.5 * (fade[0] + fade[1]) do return true
    }
    return false
}

// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_band_noise_floor :: proc(self: ^PhaseComparator, band: ^PhaseBand, is_tonal: bool) {
    dt := f32(self.available) / self.sample_rate

    // The window starts out on the silence the sample buffer is filled with
    window_full := self.sample_clock >= i64(band.dft.window_size)
    band.snr_db = update_noise_floor(&band.noise_floor, band.amp, dt, window_full, is_tonal)
}


@(test)
test_phase_detection_lock_in :: proc(t: ^testing.T) {
    FRAME :: 400 // samples per display frame at 120 FPS
    target_hz: f32 = 261.63

    run :: proc(target_hz: f32, detune_cents: f32, sample_rate: f32) -> (err_cents: [2]f32, phase_diff: f32) {
        intervals := []f32{1, 2}
        pc := init_phase_comparator(target_hz, intervals, .HARMONIC, sample_rate)
        defer destroy_phase_comparator(pc)
        set_phase_comparator_freq(pc, target_hz, 440, 0.025, 2, .HARMONIC)

        freq := f64(freq_at_cents(target_hz, detune_cents))
        chunk: [FRAME]f32
        clock := 0
        for _ in 0 ..< 2 * int(sample_rate) / FRAME {
            for &sample in chunk {
                phase := math.TAU * freq * f64(clock) / f64(sample_rate)
                sample = f32(0.1 * math.sin(phase) + 0.05 * math.sin(2 * phase))
                clock += 1
            }
            audio_capture_write(pc, chunk[:])
            // A clear pitch like the pitch detection's, the noise floors don't learn the tone
            run_phase_detection(pc, is_tonal = true)
        }
        return {pc.bands[0].err_cents, pc.bands[1].err_cents}, pc.bands[0].phase_diff
    }

    // At the input's own rate, 44.1 kHz isn't resampled to 48
    for sample_rate in ([]f32{44_100, 48_000}) {
        // In tune: the strobe stands still
        err, diff := run(target_hz, 0, sample_rate)
        testing.expectf(t, abs(err[0]) < 0.05 && abs(err[1]) < 0.05, "in tune at %v Hz, got %v cents", sample_rate, err)
        testing.expectf(t, abs(diff) < 1e-4, "in tune at %v Hz, got phase advance %v", sample_rate, diff)

        // Sharp: both bands report the detuning, the strobe phase advances
        err, diff = run(target_hz, 3, sample_rate)
        testing.expectf(t, abs(err[0] - 3) < 0.1 && abs(err[1] - 3) < 0.1, "+3 cents at %v Hz, got %v cents", sample_rate, err)
        testing.expect(t, diff > 0)

        // Flat
        err, diff = run(target_hz, -7, sample_rate)
        testing.expectf(t, abs(err[0] + 7) < 0.1 && abs(err[1] + 7) < 0.1, "-7 cents at %v Hz, got %v cents", sample_rate, err)
        testing.expect(t, diff < 0)
    }
}


// A voice down a semitone and back up, the strobe retuned to each note a moment after it changes like the
// tuner does. Each track hears the note as well when it comes back as before it left.
@(test)
test_note_away_and_back :: proc(t: ^testing.T) {
    FRAME :: 800
    RETUNE_AFTER :: 9 // frames, about what the tuner takes to confirm a note
    a3, g_sharp3: f32 = 220, 207.65

    intervals := []f32{1, 2, 4}
    pc := init_phase_comparator(a3, intervals, .HARMONIC)
    defer destroy_phase_comparator(pc)
    set_phase_comparator_freq(pc, a3, 440, 0.025, 2, .HARMONIC)

    // The partials of a hum over a little noise, the background for the noise floors to learn first. The
    // voice slides from one note to the next over glide frames, not a clear pitch on the way.
    Voice :: struct {
        chunk: [FRAME]f32,
        phase: f64,
        freq:  f32,
        noise: u32,
    }
    play :: proc(pc: ^PhaseComparator, voice: ^Voice, to: f32, frames: int, glide := 0, retune := -1) {
        from := voice.freq
        for frame in 0 ..< frames {
            voice.freq = to if frame >= glide else from + (to - from) * f32(frame) / f32(glide)
            for &sample in voice.chunk {
                voice.noise = voice.noise * 1664525 + 1013904223
                sample = 0.1 * (f32(voice.noise) / f32(max(u32)) - 0.5)
                voice.phase += math.TAU * f64(voice.freq) / DEFAULT_SAMPLE_RATE
                phase := voice.phase
                if voice.freq > 0 do sample += f32(0.1 * math.sin(phase) + 0.03 * math.sin(2 * phase) + 0.01 * math.sin(4 * phase))
            }
            if frame == retune do set_phase_comparator_freq(pc, to, 440, 0.025, 2, .HARMONIC)
            audio_capture_write(pc, voice.chunk[:])
            run_phase_detection(pc, is_tonal = voice.freq > 0 && frame >= glide)
        }
    }

    SECOND :: DEFAULT_SAMPLE_RATE / FRAME
    GLIDE :: SECOND / 2
    voice := Voice{noise = 1}
    play(pc, &voice, 0, 3 * SECOND)
    play(pc, &voice, a3, 2 * SECOND)
    before: [3]f32
    for band, index in pc.bands do before[index] = band.snr_db

    play(pc, &voice, g_sharp3, 2 * SECOND, GLIDE, GLIDE + RETUNE_AFTER)
    away: [3]f32
    for band, index in pc.bands do away[index] = band.snr_db

    play(pc, &voice, a3, 2 * SECOND, GLIDE, GLIDE + RETUNE_AFTER)
    for band, index in pc.bands {
        testing.expectf(
            t,
            band.snr_db > before[index] - 3,
            "%v× %.1f dB back on the note, %.1f before, %.1f a semitone down",
            band.interval,
            band.snr_db,
            before[index],
            away[index],
        )
    }
}

// How fast the wheel turns for a steady detuning, against what the lock-in phase should give:
// TAU * STROBE_REFERENCE_HZ * (2^(cents / 1200) - 1) * speed, in radians of the wheel per second.
@(test)
test_strobe_turn_rate :: proc(t: ^testing.T) {
    FRAME :: 800 // samples per display frame at 60 FPS
    BASE_SPEED :: 0.0125

    // Radians of the wheel per second, over the last of 3 seconds
    run :: proc(target_hz: f32, detune_cents: f32, speed_scale: f32) -> f32 {
        intervals := []f32{1}
        pc := init_phase_comparator(target_hz, intervals, .HARMONIC)
        defer destroy_phase_comparator(pc)
        set_phase_comparator_tracks(pc, intervals, {0}, {speed_scale})
        set_phase_comparator_freq(pc, target_hz, 440, BASE_SPEED, 2, .HARMONIC)

        freq := f64(freq_at_cents(target_hz, detune_cents))
        chunk: [FRAME]f32
        clock := 0
        frames_per_s := DEFAULT_SAMPLE_RATE / FRAME
        start: f32
        for frame in 0 ..< 3 * frames_per_s {
            if frame == 2 * frames_per_s do start = pc.bands[0].scaled_phase

            for &sample in chunk {
                sample = f32(0.1 * math.sin(math.TAU * freq * f64(clock) / DEFAULT_SAMPLE_RATE))
                clock += 1
            }
            audio_capture_write(pc, chunk[:])
            run_phase_detection(pc, false)
        }
        return start - pc.bands[0].scaled_phase
    }

    // Up to the edge of the note. Further out the string is outside the band's window (25 cents a bin) and
    // its phase has nothing to follow.
    for target_hz in ([]f32{82.41, 329.63}) {
        for speed_scale in ([]f32{0.25, 1}) {
            for cents in ([]f32{1, 5, 10, 25, 50, -50}) {
                rate := run(target_hz, cents, speed_scale)
                drift_hz := freq_at_cents(STROBE_REFERENCE_HZ, cents) - STROBE_REFERENCE_HZ
                ideal := math.TAU * drift_hz * BASE_SPEED * speed_scale
                testing.expectf(
                    t,
                    abs(rate - ideal) < 0.02 * abs(ideal),
                    "%v Hz at %v cents and speed %v, got %v rad/s, expected %v",
                    target_hz,
                    cents,
                    speed_scale,
                    rate,
                    ideal,
                )
            }
        }
    }
}
