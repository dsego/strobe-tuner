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
    A small Kalman filter tracks that phase and its rate, weighting each measurement by the band SNR.

 -------------------------------------------------------------------------------------------------*/


package core

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:math/linalg"
import "core:slice"
import "core:testing"


MIN_STROBE_FREQ_HZ :: 16.0
MAX_BANDS :: 8
MAX_WINDOW_SIZE :: 262_144 // the sample buffer, the window for the lowest note fits in it
PHASE_AVERAGE_SPREAD_CENTS :: 5
// A band goes up to 90% of Nyquist (21.6 kHz at 48 kHz), above it the audio can't hold the frequency and
// the input filters roll off before that anyway
MAX_BAND_NORM_FREQ :: 0.45

// The strobe phase of each band is rescaled to this frequency so that every note spins at the same
// rate per cent of detuning
STROBE_REFERENCE_HZ :: 656.5

// Phase tracker (Kalman filter) process noise, i.e. how much the phase and frequency of a real string
// are expected to wander on their own. Larger values follow the measurement more closely.
TRACKER_PHASE_NOISE_RAD :: 0.05 // rad per √s
TRACKER_FREQ_NOISE_CENTS :: 10.0 // cents per √s
TRACKER_INITIAL_FREQ_CENTS :: 50.0 // frequency uncertainty after a reset
TRACKER_MAX_MEASUREMENT_VAR :: 10.0 // rad², weak signals are effectively ignored

// The pitch of a plucked string glides down from sharp during the attack. The tracker trusts the
// measurement less while the attack is still inside the analysis window.
ONSET_RATIO :: 1.5 // amp jump over the slow envelope that counts as a new pluck (~3.5 dB)
ONSET_ENVELOPE_TIME_S :: 0.3
ONSET_HOLD_S :: 0.1 // extra time after the attack reaches the window centre
ONSET_MIN_MEASUREMENT_VAR :: 0.05 // rad²


StrobeMode :: enum {
    HARMONIC, // a track per partial
    FINE, // every track on the fundamental, each one turning faster than the one under it
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
    time_stretch: f32, // samples in a period of the base note, the strobe shader's time scale
    phase:        f32, // measured lock-in phase, relative to the reference oscillator
    amp:          f32,
    phase_diff:   f32, // strobe phase advance since the previous frame (normalized to STROBE_REFERENCE_HZ)
    err_cents:    f32, // of the tracked frequency
    scaled_phase: f32, // the strobe's phase, phase_diff times the speed added up
    phase_sigma:  f32, // uncertainty (std dev) of the tracked phase, same scale as phase_diff
    speed:        f32, // under 1 the strobe turns slower, over 1 faster
    snr_db:       f32,
    noise_floor:  NoiseFloor,

    // Lock-in reference oscillator frequency, radians per sample
    ref_omega:    f64,

    // Phase tracker state: unwrapped phase (rad) and frequency offset (rad/sample) vs the reference
    tracker:      PhaseTracker,

    // Onset detection
    envelope:     f32,
    onset_hold:   int, // samples left during which the attack is distrusted
}


// 2-state Kalman filter following the lock-in phase: [phase, frequency offset]
PhaseTracker :: struct {
    active:     bool,
    phase:      f64,
    omega:      f64,
    covariance: matrix[2, 2]f64,
}


PhaseComparator :: struct {
    using node:       AudioCaptureNode,
    base_freq_hz:     f32,
    speed_multiplier: f32, // fine mode, each track turns this much faster than the one under it
    sample_buffer:    []f32,
    bands:            [dynamic]PhaseBand,
    samplerate:       f32,
    mode:             StrobeMode,
    available:        int, // the new samples of the latest run_phase_detection
    snr_threshold_db: f32, // for the noise floor of a track added later

    // Absolute index of the sample just past the end of the newest window, i.e. the lock-in clock
    sample_clock:     i64,

    // Number of valid samples in sample_buffer, the newest sample sits at sample_buffer[buffer_len - 1]
    buffer_len:       int,
}


init_phase_comparator :: proc(
    base_freq_hz: f32,
    samplerate: f32,
    strobe_intervals: []f32,
    mode: StrobeMode,
    noise_floor_snr_db_threshold: f32,
) -> ^PhaseComparator {
    self := new(PhaseComparator)
    init_audio_capture_node(self, "phase-tracker")
    self.sample_buffer = make([]f32, MAX_WINDOW_SIZE)
    self.samplerate = samplerate
    self.mode = mode
    self.base_freq_hz = base_freq_hz
    self.snr_threshold_db = noise_floor_snr_db_threshold

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

// Fine mode measures the first band only, the others show it at other speeds
measures_band :: proc(self: ^PhaseComparator, band_index: int) -> bool {
    return self.mode == .HARMONIC || band_index == 0
}

// A new band on top, set_phase_comparator_freq tunes it
append_phase_band :: proc(self: ^PhaseComparator, interval: f32) {
    band := PhaseBand{}
    band.interval = interval
    band.speed_scale = 1
    band.noise_floor = init_noise_floor(self.snr_threshold_db)
    append(&self.bands, band)
}

// Like init_phase_comparator, a band per interval of 1 or more, the rest are padding. Adds or removes bands
// on top to match. Kept in fine mode too, for switching back to harmonic mode.
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

// Harmonic mode turns each track by its partial and its own speed, fine mode each one faster than the one under it
set_phase_comparator_speed :: proc(self: ^PhaseComparator, base_speed: f32) {
    speed := base_speed
    for &band in self.bands {
        switch self.mode {
        case .HARMONIC:
            band.speed = base_speed * band.interval * band.speed_scale
        case .FINE:
            band.speed = speed
            speed *= self.speed_multiplier
        }
    }
}


// The window size of a band, each a quarter of a semitone wide
DFT_RESOLUTION_CENTS :: 25

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

    for &band, band_index in self.bands {
        band.time_stretch = self.samplerate / base_freq_hz
        band.phase = 0
        band.tracker = {}
        band.envelope = 0
        band.onset_hold = 0

        switch self.mode {
        case .HARMONIC:
            // Named after the exact partial, a big offset would otherwise land on the next note
            band.note = freq_to_note(band.interval * base_freq_hz, pitch_standard)
            band.freq_hz = band.interval * base_freq_hz * math.pow(2, band.offset_cents / 1200)
        case .FINE:
            band.freq_hz = base_freq_hz
            band.note = freq_to_note(band.freq_hz, pitch_standard)
        }
        band.norm_freq = band.freq_hz / self.samplerate
        band.in_range = band.norm_freq < MAX_BAND_NORM_FREQ
        band.ref_omega = math.TAU * f64(band.freq_hz) / f64(self.samplerate)

        if measures_band(self, band_index) {
            window_size := dft_window_size(band.freq_hz, self.samplerate, DFT_RESOLUTION_CENTS)
            set_dft_freq(&band.dft, band.norm_freq, window_size)
            set_dft_freq(&band.averaged_dft, band.norm_freq, window_size, PHASE_AVERAGE_SPREAD_CENTS)
        }
    }
    set_phase_comparator_speed(self, base_speed)
}

// Relearn the background noise, e.g. after switching the input device
reset_phase_noise_floor :: proc(self: ^PhaseComparator) {
    for &band in self.bands {
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
    available := audio_capture_read(self, self.sample_buffer[:self.buffer_len])
    if available <= 0 do return

    self.available = int(available)
    self.sample_clock += i64(available)

    for &band, band_index in self.bands {
        if !measures_band(self, band_index) {
            // Fine mode, the first track at another speed
            base_band := self.bands[0]
            band.amp = base_band.amp
            band.phase_diff = base_band.phase_diff
            band.phase_sigma = base_band.phase_sigma
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
    self := init_phase_comparator(110, 48_000, intervals, .HARMONIC, 10)
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
    band.phase = f32(cmplx.phase(lock_in))

    update_onset(self, band, window_size)

    was_active := band.tracker.active
    prev_phase := band.tracker.phase
    update_phase_tracker(self, band)

    // Strobe phase follows the tracked phase, rescaled so all notes spin at the same rate per cent.
    // No advance on the first frame after a reset, the initial phase is arbitrary.
    phase_advance := band.tracker.phase - prev_phase if was_active else 0
    band.phase_diff = f32(phase_advance * STROBE_REFERENCE_HZ / f64(band.freq_hz))
    band.phase_sigma = f32(math.sqrt(band.tracker.covariance[0, 0]) * STROBE_REFERENCE_HZ / f64(band.freq_hz))

    // The tracked frequency offset in cents
    freq_diff_hz := f32(band.tracker.omega * f64(self.samplerate) / math.TAU)
    band.err_cents = cents_deviation(band.freq_hz + freq_diff_hz, band.freq_hz)

    // The strobe turns by the phase times the track's speed
    band.scaled_phase -= band.phase_diff * band.speed
}


// Detect a new pluck (sudden amplitude jump) and distrust the phase until the attack has passed
update_onset :: proc(self: ^PhaseComparator, band: ^PhaseBand, window_size: int) {
    band.onset_hold = max(band.onset_hold - self.available, 0)

    is_loud := band.snr_db > band.noise_floor.snr_threshold_db
    if is_loud && band.amp > ONSET_RATIO * band.envelope {
        // The attack affects the phase until it has passed the window centre
        band.onset_hold = window_size / 2 + int(ONSET_HOLD_S * self.samplerate)
    }

    alpha := 1.0 - math.exp(-f32(self.available) / (ONSET_ENVELOPE_TIME_S * self.samplerate))
    band.envelope += alpha * (band.amp - band.envelope)
}


// Kalman filter over [phase, frequency offset], the measurement is the wrapped lock-in phase.
// The measurement noise follows the band SNR: a loud note is tracked closely, a decaying note
// gradually coasts on its last good frequency instead of wandering with the noise.
update_phase_tracker :: proc(self: ^PhaseComparator, band: ^PhaseBand) {
    tracker := &band.tracker
    measured := f64(band.phase)
    cent_omega := band_cent_omega(band^)

    if !tracker.active {
        tracker.active = true
        tracker.phase = measured
        tracker.omega = 0
        freq_var := math.pow(TRACKER_INITIAL_FREQ_CENTS * cent_omega, 2)
        tracker.covariance = {math.PI * math.PI, 0, 0, freq_var}
        return
    }

    // Predict
    dt := f64(self.available)
    samplerate := f64(self.samplerate)
    transition := matrix[2, 2]f64{1, dt, 0, 1}
    process_noise := matrix[2, 2]f64 {
        TRACKER_PHASE_NOISE_RAD * TRACKER_PHASE_NOISE_RAD / samplerate * dt, 0,
        0, math.pow(TRACKER_FREQ_NOISE_CENTS * cent_omega, 2) / samplerate * dt,
    }
    tracker.phase += tracker.omega * dt
    tracker.covariance = transition * tracker.covariance * linalg.transpose(transition) + process_noise

    // Phase noise variance of a phasor in noise ≈ 1 / (2 SNR)
    EPS :: 1e-12
    noise_ratio := f64(band.noise_floor.level) / (f64(band.amp) + EPS)
    measurement_var := clamp(0.5 * noise_ratio * noise_ratio, 1e-9, TRACKER_MAX_MEASUREMENT_VAR)
    if band.onset_hold > 0 do measurement_var = max(measurement_var, ONSET_MIN_MEASUREMENT_VAR)

    // Update, unwrapping the measurement around the prediction
    innovation := wrap_phase(measured - tracker.phase)
    covariance := tracker.covariance
    innovation_var := covariance[0, 0] + measurement_var
    gain := [2]f64{covariance[0, 0] / innovation_var, covariance[1, 0] / innovation_var}

    tracker.phase += gain[0] * innovation
    tracker.omega += gain[1] * innovation
    tracker.covariance = {
        covariance[0, 0] - gain[0] * covariance[0, 0], covariance[0, 1] - gain[0] * covariance[0, 1],
        covariance[1, 0] - gain[1] * covariance[0, 0], covariance[1, 1] - gain[1] * covariance[0, 1],
    }
}


// The readout follows a track this loud, where its stripes are fully there (STROBE_FADE_SNR_DB in
// app/strobe_display.odin)
READOUT_MIN_SNR_DB :: 16
READOUT_MAX_SIGMA_CENTS :: 2 // the tracked frequency is known this closely, not just reset or coasting
READOUT_WEAK_FUNDAMENTAL_DB :: 20 // this far under the loudest partial the fundamental gives way to it
READOUT_SWITCH_DB :: 6 // another partial takes over once it's this much louder, the fundamental this much nearer
READOUT_RANGE_CENTS :: 30 // the pitch detection's distance from the note, further out the tracks can't follow

// The track the readout follows, the fundamental. A weak or missing fundamental gives way to the loudest
// partial, a weak one wanders with the loud partials around it. The partials read a few cents apart, the
// current one stays until another is clearly louder, and the fundamental takes over again once it's
// clearly back. -1 for none.
//
// ready once its frequency has settled, until then the readout is the pitch detection's. Not another
// track's that settles sooner, the fundamental's window is the longest and the readout would hop from
// one to the other after every pluck.
strobe_readout_track :: proc(self: ^PhaseComparator, current: int) -> (track: int, ready: bool) {
    loud :: proc(band: PhaseBand) -> bool {
        return band.in_range && band.snr_db >= READOUT_MIN_SNR_DB
    }

    // Fine mode measures the first track, the others show it at other speeds
    count := 1 if self.mode == .FINE else len(self.bands)
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
    sigma_cents := math.sqrt(band.tracker.covariance[1, 1]) / band_cent_omega(band)
    ready = band.tracker.active && band.onset_hold == 0 && sigma_cents <= READOUT_MAX_SIGMA_CENTS
    return
}

// Radians per sample for one cent at the band's frequency
band_cent_omega :: proc(band: PhaseBand) -> f64 {
    return band.ref_omega * (math.pow(2.0, 1.0 / 1200.0) - 1.0)
}


// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_band_noise_floor :: proc(self: ^PhaseComparator, band: ^PhaseBand, is_tonal: bool) {
    dt := f32(self.available) / self.samplerate
    // The window starts out on the silence the sample buffer is filled with
    window_full := self.sample_clock >= i64(band.dft.window_size)
    band.snr_db = update_noise_floor(&band.noise_floor, band.amp, dt, window_full, is_tonal)
}


@(test)
test_phase_detection_lock_in :: proc(t: ^testing.T) {
    SAMPLERATE :: 48_000
    FRAME :: 400 // samples per display frame at 120 FPS
    target_hz: f32 = 261.63

    run :: proc(target_hz: f32, detune_cents: f32, use_phase_average: bool) -> (err_cents: [2]f32, phase_diff: f32) {
        intervals := []f32{1, 2}
        pc := init_phase_comparator(target_hz, SAMPLERATE, intervals, .HARMONIC, 10)
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
    SAMPLERATE :: 48_000
    FRAME :: 800 // samples per display frame at 60 FPS
    BASE_SPEED :: 0.0125

    // Radians of the wheel per second, over the last of 3 seconds
    run :: proc(target_hz: f32, detune_cents: f32, speed_scale: f32) -> f32 {
        intervals := []f32{1}
        pc := init_phase_comparator(target_hz, SAMPLERATE, intervals, .HARMONIC, 10)
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
    // the tracker has nothing to follow.
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
