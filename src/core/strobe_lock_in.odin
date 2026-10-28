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

    Strobe lock-in

    Lock-in amplifier: runs a single bin DFT over the newest samples and demodulates it against a
    reference oscillator running at the target frequency on an absolute sample clock. In tune, the
    resulting phase stands still; a detuned signal makes it rotate at the frequency difference.
    The strobe turns by that phase as measured. The cents of each track are its rate, a least squares
    line fitted through it for a steady readout.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:slice"
import "core:time"


MIN_STROBE_FREQ_HZ :: 16.0
MAX_BANDS :: 5 // the strobe's tracks, the config holds as many

// Tracks not drawn for longer, another display showed or the app was in the background, start their
// persistence and motion blur over: what they held is from before. The lamp's start over too.
STROBE_STALE_S :: 0.25
// The sample buffer, the window for the lowest note at a quarter of a semitone fits in it, 264 000 samples
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
    scaled_phase: f32, // the strobe's phase, phase_diff times the speed added up, see turn_strobe
    speed:        f32, // under 1 the strobe turns slower, over 1 faster
    snr_db:       f32,
    envelope_snr_db: f32, // the SNR with the level at its envelope, what the stripes fade by, see update_band_noise_floor
    noise_floor:  NoiseFloor,
    // the noise between the note's partials as the track would read it, 0 unmeasured, and the readings it's
    // the median of, see measure_noise_between_partials
    noise_between: f32,
    noise_history: NoiseHistory,

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


StrobeLockIn :: struct {
    using node:       AudioCaptureNode,
    base_freq_hz:     f32,
    speed_multiplier: f32, // vernier mode, each track turns this much faster than the one under it
    sample_buffer:    []f32,
    bands:            [dynamic]PhaseBand,
    mode:             StrobeMode,
    band_cents:       int, // the width of each track's band, DFT_RESOLUTION_CENTS, set_strobe_lock_in_freq retunes it
    readout_fit_s:    f32, // the time constant of the readout's fit, READOUT_FIT_S, longer is steadier and later
    available:        int, // the new samples of the latest run_phase_detection
    window_noise_gain: f32, // of the window every track shares, see window_noise_gain
    noise_spectrum:   WindowedSpectrum, // the noise between the note's partials is measured on, see measure_noise_between_partials

    // Absolute index of the sample just past the end of the newest window, i.e. the lock-in clock
    sample_clock:     i64,

    // Number of valid samples in sample_buffer, the newest sample sits at sample_buffer[buffer_len - 1]
    buffer_len:       int,
}


init_strobe_lock_in :: proc(
    base_freq_hz: f32,
    strobe_intervals: []f32,
    mode: StrobeMode,
    sample_rate: f32 = DEFAULT_SAMPLE_RATE,
) -> ^StrobeLockIn {
    self := new(StrobeLockIn)
    init_audio_capture_node(self, sample_rate)
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


destroy_strobe_lock_in :: proc(self: ^StrobeLockIn) {
    destroy_audio_capture_node(self)
    delete(self.sample_buffer)
    destroy_windowed_spectrum(&self.noise_spectrum)
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
// reset_strobe_lock_in, and set_strobe_lock_in_freq has to size the windows for it before the next run.
set_strobe_lock_in_sample_rate :: proc(self: ^StrobeLockIn, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    delete(self.sample_buffer)
    self.sample_buffer = make([]f32, sample_buffer_size(sample_rate))
    self.buffer_len = 0
    reset_strobe_lock_in(self)
}

// Vernier mode measures the first band only, the others show it at other speeds
measures_band :: proc(self: ^StrobeLockIn, band_index: int) -> bool {
    return self.mode == .HARMONIC || band_index == 0
}

// A new band on top, set_strobe_lock_in_freq tunes it
append_phase_band :: proc(self: ^StrobeLockIn, interval: f32) {
    assert(len(self.bands) < MAX_BANDS, "more tracks than MAX_BANDS")
    band := PhaseBand{}
    band.interval = interval
    band.speed_scale = 1
    band.noise_floor = init_noise_floor()
    append(&self.bands, band)
}

// Like init_strobe_lock_in, a band per interval of 1 or more, the rest are padding. Adds or removes bands
// on top to match. Kept in vernier mode too, for switching back to harmonic mode.
// The partial, target offset and speed of each track, the offsets and speeds line up with the intervals.
// Takes effect with the next set_strobe_lock_in_freq.
set_strobe_lock_in_tracks :: proc(
    self: ^StrobeLockIn,
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
set_strobe_lock_in_speed :: proc(self: ^StrobeLockIn, base_speed: f32) {
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


// The window size of a band. The comb keeps the other partials out, the readout's fit steadies the cents, a
// narrower band buys less noise for more lag. A semitone left a bass's weak, beating partials jumping a tenth
// of a stripe a frame, 70 cents about halves that and the fundamental's stripes take 0.12 s at C2 instead of
// 0.08 s to follow a turned peg, see sandbox/step_response. -define:STROBE_BAND_CENTS=n to try another.
DFT_RESOLUTION_CENTS :: #config(STROBE_BAND_CENTS, 70)

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
set_strobe_lock_in_freq :: proc(
    self: ^StrobeLockIn,
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
    self.window_noise_gain = window_noise_gain(window)

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

    set_strobe_lock_in_speed(self, base_speed)
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

    // Nothing heard yet, like a track out of range, the previous note's level isn't this one's
    band.amp = 0
    band.snr_db = 0
    band.envelope_snr_db = 0
    band.phase_diff = 0
    band.noise_between = 0
    band.noise_history = {}
}

// Another input's signal is unrelated to the previous one's, everything starts over like at launch: the
// windows on silence, so the noise floors wait for the new input to fill them before they learn it
reset_strobe_lock_in :: proc(self: ^StrobeLockIn) {
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
run_phase_detection :: proc(self: ^StrobeLockIn, is_tonal := false) {
    // The window every track shares, see set_strobe_lock_in_freq, and a frame's new samples before it for
    // the hops. The newest samples come in without delay.
    window_size := self.bands[0].dft.window_size
    resize_sample_buffer(self, window_size + int(MAX_FRAME_S * self.sample_rate))
    read, elapsed := audio_capture_read(self, self.sample_buffer[:self.buffer_len])
    if read == 0 && elapsed > 0 {
        // A stall, the buffer is silent and the tracks start over on the audio after it. The clock too, the
        // noise floors don't learn the silence while the window fills again, see update_band_noise_floor.
        self.sample_clock = 0
        for &band in self.bands do restart_band(&band)

        return
    }
    if read == 0 do return

    self.available = int(elapsed)
    self.sample_clock += elapsed

    // The tracks that measure, all at once. Not one that a retune too low for the strobe left on another
    // window, see set_strobe_lock_in_freq.
    measured: [MAX_BANDS]^PhaseBand
    measured_count := 0
    for &band, band_index in self.bands {
        if measures_band(self, band_index) && band.in_range && band.dft.window_size == window_size {
            measured[measured_count] = &band
            measured_count += 1
        }
    }
    determine_band_phases(self, measured[:measured_count])
    measure_noise_between_partials(self)
    for band in measured[:measured_count] do update_band_noise_floor(self, band, is_tonal)

    for &band, band_index in self.bands {
        if !measures_band(self, band_index) {
            // Vernier mode, the first track's measurement at another speed
            base_band := self.bands[0]
            band.amp, band.envelope, band.onset = base_band.amp, base_band.envelope, base_band.onset
            band.phase_diff, band.rate, band.err_cents = base_band.phase_diff, base_band.rate, base_band.err_cents
            band.drift_hz, band.drift_cents = base_band.drift_hz, base_band.drift_cents
            band.noise_floor, band.snr_db = base_band.noise_floor, base_band.snr_db
            band.envelope_snr_db = base_band.envelope_snr_db
            turn_strobe(&band.scaled_phase, band.phase_diff, band.speed)
        } else if !band.in_range {
            // Nothing to measure up there, quiet so the track stays dark
            band.amp = 0
            band.snr_db = 0
            band.envelope_snr_db = 0
            band.phase_diff = 0
        }
    }
}


// Samples for a frequency resolution of cents_resolution. A fixed window has the same resolution in Hz
// everywhere, a higher note needs fewer samples for as many cents.
dft_window_size :: proc(freq_hz: f32, samplerate: f32, cents_resolution: int) -> int {
    ratio := math.pow(f32(2), f32(cents_resolution) / 1200.0)
    freq_resolution := freq_hz * (ratio - 1.0)
    return int(math.ceil(samplerate / freq_resolution))
}


// Keep the newest samples aligned to the end of the buffer when the window size changes, so the buffer
// always holds one contiguous stretch of audio ending at sample_clock.
resize_sample_buffer :: proc(self: ^StrobeLockIn, size: int) {
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
determine_band_phases :: proc(self: ^StrobeLockIn, bands: []^PhaseBand) {
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

    // A main loop hitch brought in more than the buffer holds past the window. The first hop steps over the
    // skipped samples too, more than half a turn for a track a few Hz off, so it goes the way the track's
    // rate turns over that long instead of the shortest way.
    first_hop := f64(self.available - span + span / hops)

    phase_advances: [MAX_BANDS]f64
    for hop in 1 ..= hops {
        // Up to the newest samples, i.e. the end of the buffer
        window_end := self.buffer_len - span + span * hop / hops
        run_single_dfts(dfts[:len(bands)], self.sample_buffer[window_end - window_size:window_end])

        window_start := self.sample_clock - i64(self.buffer_len - window_end) - i64(window_size)
        for band, index in bands {
            hop_phase := lock_in_phase(band, window_start)
            if had_phase[index] {
                expected := band.rate * first_hop if hop == 1 && self.available > span else 0
                phase_advances[index] += expected + wrap_phase(f64(hop_phase - band.phase) - expected)
            }

            band.phase = hop_phase
        }
    }

    for band, index in bands {
        band.amp = abs(band.dft.dft)
        band.has_phase = true
        advance_band(self, band, phase_advances[index], had_phase[index])
    }
}

// How far the track's frequency plus diff_hz is from it. An octave flat is as far as it goes: noise on a low
// track can advance by more than its frequency, and a negative frequency has no cents.
band_cents_off :: proc(band: ^PhaseBand, diff_hz: f32) -> f32 {
    return cents_deviation(max(band.freq_hz + diff_hz, 0.5 * band.freq_hz), band.freq_hz)
}

// The track's onset, rate, drift and the strobe's turn from the frame's phase advance
advance_band :: proc(self: ^StrobeLockIn, band: ^PhaseBand, phase_advance: f64, had_phase: bool) {
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
        // stripes.
        drift_hz := f32(phase_advance / step * sample_rate / math.TAU)
        alpha := f32(1 - math.exp(-step / (DRIFT_SMOOTH_S * sample_rate)))
        band.drift_hz += alpha * (drift_hz - band.drift_hz)
        band.drift_cents = abs(band_cents_off(band, band.drift_hz))
    }

    // The readout fits the rate while the stripes fully show, over the noise around the track, see
    // update_band_noise_floor. A fading note keeps the last of it, the dimming stripes drift with the noise.
    // Each measurement is weighted by its samples, a stalled frame counts for as long as it took, and by the
    // partial's power against its envelope. Where two components beat, the phase swings fast through the dips;
    // weighted by power the rate settles on their mean pitch by energy instead of following the swings.
    // Against the envelope, not the absolute power: a decaying note's newest moments are its weakest, and they
    // still count as much. A single one has no slope yet, the rate is its advance.
    if had_phase && band.snr_db >= READOUT_MIN_SNR_DB {
        if band.rate_time_s == 0 do band.fit = {}

        band.rate_time_s += f32(self.available) / self.sample_rate

        // The new measurement at time 0 and phase 0 only adds its weight
        level := f64(band.amp / band.envelope) if band.envelope > 0 else 1
        band.fit.weight += step * level * level
        slope, has_slope := fit_slope(band.fit)
        band.rate = slope if has_slope else phase_advance / step
    }

    // Noise on a low track can fit a rate past its own frequency too
    band.err_cents = band_cents_off(band, f32(band.rate * sample_rate / math.TAU))

    // The strobe turns by the phase times the track's speed
    turn_strobe(&band.scaled_phase, band.phase_diff, band.speed)

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

// The strobe's phase is kept within this of 0, an f32 far from it loses the phase's fine steps over a long
// session. Whole turns, a whole number of stripes on every track, the stripes don't move when it wraps.
STROBE_PHASE_WRAP :: 64 * math.TAU

// The strobe's phase turned back by phase_diff times the speed, see scaled_phase
turn_strobe :: proc(scaled_phase: ^f32, phase_diff, speed: f32) {
    scaled_phase^ = math.mod(scaled_phase^ - phase_diff * speed, f32(STROBE_PHASE_WRAP))
}

// Without audio the strobe stops going on after this long
STROBE_AHEAD_MAX_S :: 0.03

// How fast the strobe turns at the readout's rate, radians of the track a second, the way scaled_phase goes
strobe_phase_rate :: proc(self: ^StrobeLockIn, band: PhaseBand) -> f32 {
    radians_per_s := band.rate * f64(self.sample_rate) * strobe_rescale(band.freq_hz)
    return -f32(radians_per_s) * band.speed
}

// How far the strobe turned since its newest sample came in, at the readout's rate. The audio comes in chunks
// that don't line up with the display's frames, 10 ms ones on a Mac at 120 Hz: a frame in six gets none and
// the others a chunk and a bit, a steady drift drawn as measured steps and stalls. Drawn this far ahead it
// moves evenly, and the next measurement takes over where it is.
strobe_phase_ahead :: proc(self: ^StrobeLockIn, band: PhaseBand) -> f32 {
    age := min(time.duration_seconds(time.tick_since(self.newest_tick)), STROBE_AHEAD_MAX_S)
    return strobe_phase_rate(self, band) * f32(age)
}


// Detect a new pluck (sudden amplitude jump), the readout's average starts over. The envelope jumps along,
// while the attack rises through the window each jump starts it over again.
update_onset :: proc(self: ^StrobeLockIn, band: ^PhaseBand) {
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


// The stripes fade in between these SNRs of the track's envelope, below it's the noise
STROBE_FADE_SNR_DB :: [2]f32{8, 16}

// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_band_noise_floor :: proc(self: ^StrobeLockIn, band: ^PhaseBand, is_tonal: bool) {
    dt := f32(self.available) / self.sample_rate

    // The window starts out on the silence the sample buffer is filled with. Once warmed up, after a stall,
    // the floor doesn't learn it, a long window refilling reads the room too low and a note starting then
    // would hold the floor down.
    noise_floor := &band.noise_floor
    window_full := self.sample_clock >= i64(band.dft.window_size)
    if !window_full && noise_floor.warmup == 0 && noise_floor.level > 0 {
        band.snr_db = 20 * math.log10(max(band.amp, MIN_NOISE_FLOOR) / noise_floor.level)
    } else {
        band.snr_db = update_noise_floor(noise_floor, band.amp, dt, window_full, is_tonal)
    }

    // Over the floor and the noise between the partials together when that's measured, the two add as powers:
    // the floor was learned before the note, the noise the note brings along shows only between its partials,
    // see measure_noise_between_partials. More noise, never a higher SNR.
    if band.noise_between > 0 {
        noise := math.sqrt(noise_floor.level * noise_floor.level + band.noise_between * band.noise_between)
        band.snr_db = 20 * math.log10(max(band.amp, MIN_NOISE_FLOOR) / noise)
    }

    // The same with the level at its envelope, what the stripes fade by. In noise a weak partial's level swings a
    // few dB from one tenth of a second to the next, and dips for a moment where it beats: through the fade, a few
    // dB wide, its stripes flickered. The envelope follows over ONSET_ENVELOPE_TIME_S and jumps along with a
    // pluck, the stripes still light up with the attack. Under its noise a track's level is the noise's, nothing
    // of the note is left to remember: the envelope drops to it, a stopped or muted note's stripes go dark at once
    // instead of drawing the noise while the envelope follows, whole turns a frame as the window empties.
    if band.snr_db < 0 do band.envelope = band.amp
    band.envelope_snr_db = band.snr_db + 20 * math.log10(max(band.envelope, MIN_NOISE_FLOOR) / max(band.amp, MIN_NOISE_FLOOR))
}
