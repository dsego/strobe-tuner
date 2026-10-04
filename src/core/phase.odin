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


MIN_STROBE_FREQ_HZ :: 16.0
MAX_BANDS :: 5 // the strobe's tracks, the config holds as many
MAX_WINDOW_SIZE :: 262_144 // the sample buffer, the window for the lowest note fits in it
PHASE_AVERAGE_SPREAD_CENTS :: 5
// A band goes up to 90% of Nyquist (21.6 kHz at 48 kHz), above it the audio can't hold the frequency and
// the input filters roll off before that anyway
MAX_BAND_NORM_FREQ :: 0.45

// The strobe phase of each band is rescaled to this frequency so that every note spins at the same
// rate per cent of detuning
STROBE_REFERENCE_HZ :: 656.5

// The cents of each track are the slope of a least squares line through the phase, older measurements
// weighted down with this time constant. Its weight on the rate of each moment peaks this long ago and is
// twice that on average, steady but a turned peg shows that much later than on the stripes.
READOUT_FIT_S :: 0.15

// The pitch of a plucked string glides down from sharp during the attack. The readout's average starts
// over once the attack has passed through the analysis window.
ONSET_RATIO :: 1.5 // amp jump over the slow envelope that counts as a new pluck (~3.5 dB)
ONSET_ENVELOPE_TIME_S :: 0.3
ONSET_HOLD_S :: 0.1 // extra time after the attack reaches the window centre


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
    averaged_dft: SingleFreqDFT, // with PHASE_AVERAGE_SPREAD_CENTS, see set_dft_freq
    window_delay: int, // samples, how far back the DFTs measure, see gamma_comb_delay
    time_stretch: f32, // samples in a period of the base note, the strobe shader's time scale
    phase:        f32, // measured lock-in phase, relative to the reference oscillator
    amp:          f32,
    phase_diff:   f32, // strobe phase advance since the previous frame (normalized to STROBE_REFERENCE_HZ)
    err_cents:    f32, // of the averaged rate
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
    onset_hold:   int, // samples left during which the attack is distrusted
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
    available:        int, // the new samples of the latest run_phase_detection

    // Absolute index of the sample just past the end of the newest window, i.e. the lock-in clock
    sample_clock:     i64,

    // Number of valid samples in sample_buffer, the newest sample sits at sample_buffer[buffer_len - 1]
    buffer_len:       int,
}


init_phase_comparator :: proc(base_freq_hz: f32, strobe_intervals: []f32, mode: StrobeMode) -> ^PhaseComparator {
    self := new(PhaseComparator)
    init_audio_capture_node(self, "phase-tracker")
    self.sample_buffer = make([]f32, MAX_WINDOW_SIZE)
    self.mode = mode
    self.base_freq_hz = base_freq_hz

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
    destroy_dft(&band.averaged_dft)
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

    comb_samples := comb_periods(self.bands[:], mode) * SAMPLERATE / base_freq_hz

    for &band, band_index in self.bands {
        band.time_stretch = SAMPLERATE / base_freq_hz
        restart_band(&band)

        switch self.mode {
        case .HARMONIC:
            // Named after the exact partial, a big offset would otherwise land on the next note
            band.note = freq_to_note(band.interval * base_freq_hz, pitch_standard)
            band.freq_hz = band.interval * base_freq_hz * math.pow(2, band.offset_cents / 1200)
        case .VERNIER:
            band.freq_hz = base_freq_hz
            band.note = freq_to_note(band.freq_hz, pitch_standard)
        }
        band.norm_freq = band.freq_hz / SAMPLERATE
        band.in_range = band.norm_freq < MAX_BAND_NORM_FREQ
        band.ref_omega = math.TAU * f64(band.freq_hz) / SAMPLERATE

        if measures_band(self, band_index) {
            // Every track gets the fundamental's window. Sized in cents of its own partial an upper track's
            // window would be shorter, its band wider in Hz for a weaker partial, and it shimmers.
            gamma_size := dft_window_size(base_freq_hz, SAMPLERATE, DFT_RESOLUTION_CENTS)
            window := gamma_comb_window(gamma_size, comb_samples)
            set_dft_freq(&band.dft, band.norm_freq, window)
            set_dft_freq(&band.averaged_dft, band.norm_freq, window, PHASE_AVERAGE_SPREAD_CENTS)
            band.window_delay = gamma_comb_delay(gamma_size, comb_samples)
        }
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
    band.envelope = 0
    band.onset_hold = 0
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
run_phase_detection :: proc(self: ^PhaseComparator, use_phase_average: bool, is_tonal := false) {
    // Just the longest window, the lowest partial's, which isn't always the first track's. The buffer is no
    // longer than that, the newest samples come in without delay.
    window_size := self.bands[0].dft.window_size
    if self.mode == .HARMONIC {
        for band in self.bands do window_size = max(window_size, band.dft.window_size)
    }
    resize_sample_buffer(self, window_size)
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

    for &band, band_index in self.bands {
        if !measures_band(self, band_index) {
            // Vernier mode, the first track at another speed
            base_band := self.bands[0]
            band.amp = base_band.amp
            band.phase_diff = base_band.phase_diff
            band.noise_floor = base_band.noise_floor
            band.snr_db = base_band.snr_db
            band.scaled_phase -= band.phase_diff * band.speed
        } else if !band.in_range {
            // Nothing to measure up there, quiet so the track stays dark
            band.amp = 0
            band.snr_db = 0
            band.phase_diff = 0
        } else {
            determine_band_phase(self, &band, use_phase_average)
            update_band_noise_floor(self, &band, is_tonal)
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


// A single bin DFT over the newest samples, demodulated against the band's reference oscillator
determine_band_phase :: proc(self: ^PhaseComparator, band: ^PhaseBand, use_phase_average: bool) {
    // Every band analyses the newest samples, i.e. the end of the buffer
    window_size := band.dft.window_size
    samples := self.sample_buffer[self.buffer_len - window_size:self.buffer_len]

    dft := run_single_dft(&band.averaged_dft if use_phase_average else &band.dft, samples)
    band.amp = abs(dft)

    // Lock-in / heterodyne: the DFT twiddles restart at 0 for every window, so rotate the result by
    // the reference oscillator phase at the window start (absolute sample index).
    // A signal exactly at the reference frequency then yields a constant phase.
    window_start := self.sample_clock - i64(window_size)
    ref_phase := math.mod(f64(window_start) * band.ref_omega, math.TAU)
    lock_in := complex128(dft) * complex(math.cos(ref_phase), -math.sin(ref_phase))
    prev_measured := band.phase
    band.phase = f32(cmplx.phase(lock_in))

    update_onset(self, band)

    // The strobe turns by the measured phase, the shortest way from the previous frame's, nothing else
    // carries over between frames. A band can only be off by half the frame rate in Hz, further out its
    // narrow window has faded the stripes. No advance on the first frame after a reset, the phase before
    // it is arbitrary.
    had_phase := band.has_phase
    phase_advance := wrap_phase(f64(band.phase - prev_measured)) if had_phase else 0
    band.has_phase = true

    // Rescaled so all notes spin at the same rate per cent
    band.phase_diff = f32(phase_advance * strobe_rescale(band.freq_hz))

    step := f64(self.available)
    if had_phase {
        decay := math.exp(-step / (READOUT_FIT_S * SAMPLERATE))
        shift_fit(&band.fit, step, phase_advance, decay)
    }

    // The readout fits the rate once the attack has passed, and while the stripes show, a fading note
    // keeps the last of it. Each measurement is weighted by its samples, a stalled frame counts for as long
    // as it took. A single one has no slope yet, the rate is its advance.
    if had_phase && band.onset_hold == 0 && band.snr_db >= STROBE_FADE_SNR_DB[0] {
        if band.rate_time_s == 0 do band.fit = {}
        band.rate_time_s += f32(self.available) / SAMPLERATE

        // The new measurement at time 0 and phase 0 only adds its weight
        band.fit.weight += step
        slope, has_slope := fit_slope(band.fit)
        band.rate = slope if has_slope else phase_advance / step
    }
    freq_diff_hz := f32(band.rate * SAMPLERATE / math.TAU)
    band.err_cents = cents_deviation(band.freq_hz + freq_diff_hz, band.freq_hz)

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


// Detect a new pluck (sudden amplitude jump) and distrust the phase until the attack has passed
update_onset :: proc(self: ^PhaseComparator, band: ^PhaseBand) {
    band.onset_hold = max(band.onset_hold - self.available, 0)

    is_loud := band.snr_db > NOISE_FLOOR_SNR_DB_THRESHOLD
    if is_loud && band.amp > ONSET_RATIO * band.envelope {
        // The attack affects the phase until it has passed the window's delay
        band.onset_hold = band.window_delay + int(ONSET_HOLD_S * SAMPLERATE)
        // The readout's average starts over on each pluck
        band.rate_time_s = 0
    }

    alpha := 1.0 - math.exp(-f32(self.available) / (ONSET_ENVELOPE_TIME_S * SAMPLERATE))
    band.envelope += alpha * (band.amp - band.envelope)
}



// The stripes fade in between these SNRs, below it's the background noise (it stays under ~10 dB)
STROBE_FADE_SNR_DB :: [2]f32{8, 16}

// The readout follows a track this loud, where its stripes are fully there
READOUT_MIN_SNR_DB :: STROBE_FADE_SNR_DB[1]
READOUT_WEAK_FUNDAMENTAL_DB :: 20 // this far under the loudest partial the fundamental gives way to it
READOUT_SWITCH_DB :: 6 // another partial takes over once it's this much louder, the fundamental this much nearer
READOUT_RANGE_CENTS :: 30 // the pitch detection's distance from the note, further out the tracks can't follow

// The track the readout follows, the fundamental. A weak or missing fundamental gives way to the loudest
// partial, a weak one wanders with the loud partials around it. The partials read a few cents apart, the
// current one stays until another is clearly louder, and the fundamental takes over again once it's
// clearly back. -1 for none.
//
// ready once its averaged rate has settled after the attack, until then the readout is the pitch detection's. Not another
// track's that settles sooner, the fundamental's window is the longest and the readout would hop from
// one to the other after every pluck.
strobe_readout_track :: proc(self: ^PhaseComparator, current: int) -> (track: int, ready: bool) {
    loud :: proc(band: PhaseBand) -> bool {
        return band.in_range && band.snr_db >= READOUT_MIN_SNR_DB
    }

    // Vernier mode measures the first track, the others show it at other speeds
    count := 1 if self.mode == .VERNIER else len(self.bands)
    loudest, fundamental := -1, -1
    for band, index in self.bands[:count] {
        if !loud(band) do continue
        if loudest < 0 || band.snr_db > self.bands[loudest].snr_db do loudest = index
        if band.interval == 1 do fundamental = index
    }
    if loudest < 0 do return -1, false

    track = loudest
    weak_db: f32 = READOUT_WEAK_FUNDAMENTAL_DB
    if current != fundamental do weak_db -= READOUT_SWITCH_DB
    if fundamental >= 0 && self.bands[loudest].snr_db - self.bands[fundamental].snr_db < weak_db {
        track = fundamental
    } else if current >= 0 && current < count && current != loudest && current != fundamental && loud(self.bands[current]) {
        if self.bands[loudest].snr_db - self.bands[current].snr_db < READOUT_SWITCH_DB do track = current
    }

    band := self.bands[track]
    ready = band.onset_hold == 0 && band.rate_time_s >= 2 * READOUT_FIT_S
    return
}

// Whether any track's stripes are at least half faded in, the note is still ringing. The background noise
// stays under it. fundamental_only for just the track of the strobe's own note.
strobe_shows_note :: proc(self: ^PhaseComparator, fundamental_only := false) -> bool {
    fade := STROBE_FADE_SNR_DB
    for band in self.bands {
        if fundamental_only && band.interval != 1 do continue
        if band.in_range && band.snr_db >= 0.5 * (fade[0] + fade[1]) do return true
    }
    return false
}

// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_band_noise_floor :: proc(self: ^PhaseComparator, band: ^PhaseBand, is_tonal: bool) {
    dt := f32(self.available) / SAMPLERATE
    // The window starts out on the silence the sample buffer is filled with
    window_full := self.sample_clock >= i64(band.dft.window_size)
    band.snr_db = update_noise_floor(&band.noise_floor, band.amp, dt, window_full, is_tonal)
}


@(test)
test_phase_detection_lock_in :: proc(t: ^testing.T) {
    FRAME :: 400 // samples per display frame at 120 FPS
    target_hz: f32 = 261.63

    run :: proc(target_hz: f32, detune_cents: f32, use_phase_average: bool) -> (err_cents: [2]f32, phase_diff: f32) {
        intervals := []f32{1, 2}
        pc := init_phase_comparator(target_hz, intervals, .HARMONIC)
        defer destroy_phase_comparator(pc)
        set_phase_comparator_freq(pc, target_hz, 440, 0.025, 2, .HARMONIC)

        freq := f64(cents_to_freq(detune_cents, target_hz))
        chunk: [FRAME]f32
        clock := 0
        for _ in 0 ..< 2 * SAMPLERATE / FRAME {
            for &sample in chunk {
                phase := math.TAU * freq * f64(clock) / SAMPLERATE
                sample = f32(0.1 * math.sin(phase) + 0.05 * math.sin(2 * phase))
                clock += 1
            }
            audio_capture_write(pc, chunk[:])
            run_phase_detection(pc, use_phase_average)
        }
        return {pc.bands[0].err_cents, pc.bands[1].err_cents}, pc.bands[0].phase_diff
    }

    for average in ([]bool{false, true}) {
        // In tune: the strobe stands still
        err, diff := run(target_hz, 0, average)
        testing.expectf(t, abs(err[0]) < 0.05 && abs(err[1]) < 0.05, "in tune, got %v cents", err)
        testing.expectf(t, abs(diff) < 1e-4, "in tune, got phase advance %v", diff)

        // Sharp: both bands report the detuning, the strobe phase advances
        err, diff = run(target_hz, 3, average)
        testing.expectf(t, abs(err[0] - 3) < 0.1 && abs(err[1] - 3) < 0.1, "+3 cents, got %v cents", err)
        testing.expect(t, diff > 0)

        // Flat
        err, diff = run(target_hz, -7, average)
        testing.expectf(t, abs(err[0] + 7) < 0.1 && abs(err[1] + 7) < 0.1, "-7 cents, got %v cents", err)
        testing.expect(t, diff < 0)
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

        freq := f64(cents_to_freq(detune_cents, target_hz))
        chunk: [FRAME]f32
        clock := 0
        frames_per_s := SAMPLERATE / FRAME
        start: f32
        for frame in 0 ..< 3 * frames_per_s {
            if frame == 2 * frames_per_s do start = pc.bands[0].scaled_phase
            for &sample in chunk {
                sample = f32(0.1 * math.sin(math.TAU * freq * f64(clock) / SAMPLERATE))
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
                ideal := math.TAU * STROBE_REFERENCE_HZ * (math.pow(2, cents / 1200) - 1) * BASE_SPEED * speed_scale
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
