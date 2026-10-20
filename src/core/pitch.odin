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


package core


import "core:math"
import "core:slice"


// Tuned on test recordings with the sandbox tools, not in the settings

// The window, 4096 samples at 48 kHz, a power of 2 at least this long at any rate. The FFT is twice as long.
PITCH_WINDOW_S :: 0.085

// Under a guitar's low E (82 Hz), it takes out DC and low frequency rumble. A lower note like a bass's E1
// (41 Hz) loses its fundamental here, it's still found from its harmonics.
PITCH_HIGHPASS_HZ :: 60

// A strong pitch is this clear at least and this far over the noise floor, a weak one less clear than
// PITCH_CLARITY_LOW
PITCH_CLARITY_LOW :: 0.9
PITCH_CLARITY_HIGH :: 0.98
PITCH_MIN_SNR_DB :: 2

// A strong pitch stays strong down to this far under PITCH_MIN_SNR_DB, so a decaying note doesn't flicker
// between strong and weak around the threshold
SNR_HYSTERESIS_DB :: 1.5

// Mains hum repeats as steadily as a held note, and the grid holds it to a few cents of 50 or 60 Hz where
// no note is tuned: G1 +35 ¢, A♯1 +50 ¢, B1 -49 ¢. It's the background, a string tuned through it loses
// its note for a moment. Off, a note held there stayed dark the whole time and a pitch is a note, e.g.
// -define:MAINS_HUM=true to try it.
MAINS_HUM :: #config(MAINS_HUM, false)
MAINS_HZ :: [?]f32{50, 60}
MAINS_CENTS :: 8

// The window moves on by a display frame at 60 fps, the 8192 point FFT is cheap. The note recognition confirms
// a note by time, so the rate only changes how soon it's seen.
DETECTIONS_PER_SECOND :: 60

// The pitch detection hears up to here, above C8 (4186 Hz). Hiss and pick noise over it only blur the
// period, the strobe still gets the whole band. A slow input's under its Nyquist, see pitch_lowpass_hz.
PITCH_LOWPASS_HZ :: 5000

// Under this rate a Bluetooth headset's microphone, 16 or 24 kHz, the app warns that high notes and the
// partials over Nyquist are out of reach
LOW_SAMPLE_RATE :: 44_100


PitchDetector :: struct {
    using node:     AudioCaptureNode,
    nsdf:           NSDF,
    samples:        []f32,
    // DC and rumble lift the NSDF so it doesn't dip between periods, hiss blurs it, see PITCH_LOWPASS_HZ.
    // Only here, the strobe's tracks are narrow and the scope wants the wave as it is.
    highpass:       Biquad,
    lowpass:        Biquad,
    noise_floor:    NoiseFloor, // of the RMS
    snr_db:         f32,
    pitch_standard: f32, // A4, detected notes are named against it
}


PitchInfo :: struct {
    measured:        bool,
    fresh:           bool, // a new measurement this frame, false when repeating the previous one
    elapsed_s:       f32, // the new audio since the previous measurement
    detected_freq:   f32,
    detected_note:   Note,
    clarity:         f32,
    shortest_period: bool, // the first NSDF peak, not a guess at a multiple of the period
    rms:             f32,
    rms_dbfs:        f32,
    err_cents:       f32,
    is_strong_pitch: bool,
    is_weak_pitch:   bool,
    is_tonal:        bool, // a pitch whatever its level, medium clarity or more, the noise floors don't learn it as the background
    snr_db:          f32,
    noise_floor:     f32,
}


init_pitch_detector :: proc(pitch_standard: f32 = 440.0, sample_rate: f32 = DEFAULT_SAMPLE_RATE) -> (self: PitchDetector) {
    self.noise_floor = init_noise_floor()
    self.pitch_standard = pitch_standard

    init_audio_capture_node(&self, sample_rate)
    size_pitch_detector(&self)
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    destroy_nsdf(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}

// The input opened at another rate, the window and the filters are made again for it and everything starts
// over like for another input, see reset_pitch_detector
set_pitch_detector_sample_rate :: proc(self: ^PitchDetector, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    destroy_nsdf(&self.nsdf)
    delete(self.samples)
    size_pitch_detector(self)
    reset_noise_floor(&self.noise_floor)
}

// The window's samples at the rate, PITCH_WINDOW_S rounded up to a power of 2: 4096 at 48 kHz
pitch_window :: proc(sample_rate: f32) -> int {
    window := 1
    for f32(window) < PITCH_WINDOW_S * sample_rate do window *= 2
    return window
}

// The window, the NSDF and the filters at the node's rate
size_pitch_detector :: proc(self: ^PitchDetector) {
    window := pitch_window(self.sample_rate)

    self.samples = make([]f32, window)
    self.nsdf = init_nsdf(2 * window, self.sample_rate)
    self.highpass = init_highpass(PITCH_HIGHPASS_HZ, self.sample_rate)
    self.lowpass = init_lowpass(pitch_lowpass_hz(self.sample_rate), self.sample_rate)
}

// PITCH_LOWPASS_HZ, or under Nyquist on a slow input, an 8 kHz phone line's 4 kHz
pitch_lowpass_hz :: proc(sample_rate: f32) -> f32 {
    return min(PITCH_LOWPASS_HZ, 0.4 * sample_rate)
}

// Another input's signal is unrelated to the previous one's: the window starts out silent like at launch,
// the filters from rest and the noise floor is learned again
reset_pitch_detector :: proc(self: ^PitchDetector) {
    slice.zero(self.samples)
    reset_biquad(&self.highpass)
    reset_biquad(&self.lowpass)
    reset_noise_floor(&self.noise_floor)
}

// Takes the previous detection to repeat when there are no new samples, the NoteTarget keeps the history
run_pitch_detection :: proc(self: ^PitchDetector, prev_info: PitchInfo) -> PitchInfo {
    info := PitchInfo{}

    // Once a display frame's worth of new samples is in, the read wants more than its minimum
    min_available := int(self.sample_rate) / DETECTIONS_PER_SECOND - 1
    read, elapsed := audio_capture_read_filtered(self, self.samples, &self.highpass, &self.lowpass, min_available)

    if read == 0 {
        stale := prev_info
        stale.fresh = false
        return stale
    }

    info.measured = true
    info.fresh = true

    nsdf_peak: Vec2
    info.detected_freq, nsdf_peak = run_nsdf(&self.nsdf, self.samples)
    info.clarity = nsdf_peak.y
    info.shortest_period = self.nsdf.chosen_peak == 0
    info.rms = max(calculate_rms(self.samples), MIN_NOISE_FLOOR)
    info.rms_dbfs = dbfs(info.rms)

    dt := f32(elapsed) / self.sample_rate
    info.elapsed_s = dt

    // A0 to C8, the piano's notes the ruler has, up to half a semitone out, at the pitch standard
    min_freq := freq_at_cents(self.pitch_standard, LOWEST_NOTE * 100 - 50)
    max_freq := freq_at_cents(self.pitch_standard, HIGHEST_NOTE * 100 + 50)
    in_range := info.detected_freq >= min_freq && info.detected_freq <= max_freq
    mains := false

    when MAINS_HUM {
        for mains_hz in MAINS_HZ {
            if abs(cents_deviation(info.detected_freq, mains_hz)) <= MAINS_CENTS do mains = true
        }
    }

    // A pitch is a note, not the background, even before the floor knows how loud that is. A voice or a
    // muddied string can be one, noise doesn't repeat that well.
    info.is_tonal = in_range && info.clarity >= PITCH_CLARITY_LOW && !mains
    self.snr_db = update_noise_floor(&self.noise_floor, info.rms, dt, is_tonal = info.is_tonal)
    info.snr_db = self.snr_db
    info.noise_floor = self.noise_floor.level

    // No peak gives 0 Hz, which has no note
    if info.detected_freq > 0 {
        info.detected_note = freq_to_note(info.detected_freq, self.pitch_standard)
        info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)
    }

    weak_snr_db: f32 = PITCH_MIN_SNR_DB - SNR_HYSTERESIS_DB
    strong_snr_db: f32 = weak_snr_db if prev_info.is_strong_pitch else PITCH_MIN_SNR_DB

    info.is_strong_pitch = info.is_tonal && info.clarity >= PITCH_CLARITY_HIGH && info.snr_db >= strong_snr_db
    info.is_weak_pitch =
        mains ||
        !in_range ||
        info.clarity < PITCH_CLARITY_LOW ||
        info.snr_db < weak_snr_db

    return info
}

calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for sample in samples do square_sum += sample * sample

    return math.sqrt(square_sum / f32(len(samples)))
}

// Of an RMS level, against a full scale sine's RMS so a full scale sine is 0 dBFS
dbfs :: proc(signal: $T) -> T {
    return 20.0 * math.log10(signal * math.sqrt(cast(T)2.0))
}
