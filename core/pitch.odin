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


// A strong pitch stays strong down to this far under min_snr_db, so a decaying note doesn't flicker
// between strong and weak around the threshold
SNR_HYSTERESIS_DB :: 1.5


PitchDetector :: struct {
    using node:                   AudioCaptureNode,
    nsdf:                         NSDFConfig,
    samples:                      []f32,
    clarity_high:                 f32,
    clarity_low:                  f32,
    noise_floor:                  NoiseFloor, // of the RMS
    min_snr_db:                   f32,
    snr_db:                       f32,
    pitch_standard:               f32, // A4, detected notes are named against it
}


PitchInfo :: struct {
    measured:        bool,
    fresh:           bool, // a new measurement this frame, false when repeating the previous one
    detected_freq:   f32,
    detected_note:   Note,
    clarity:         f32,
    nsdf_peak:       Vec2,
    rms:             f32,
    rms_dbfs:        f32,
    err_cents:       f32,
    is_strong_pitch: bool,
    is_weak_pitch:   bool,
    is_tonal:        bool, // a clear pitch whatever its level, the noise floors don't learn it as the background
    snr_db:          f32,
    noise_floor:     f32,
}


init_pitch_detector :: proc(
    samplerate: int,
    fft_size: int,
    clarity_high: f32,
    clarity_low: f32,
    min_snr_db: f32,
    noise_floor_snr_db_threshold: f32,
) -> (
    self: PitchDetector,
) {
    self.samples = make([]f32, fft_size / 2)
    self.nsdf = nsdf_init(fft_size, samplerate)
    self.clarity_high = clarity_high
    self.clarity_low = clarity_low
    self.min_snr_db = min_snr_db
    self.noise_floor = init_noise_floor(noise_floor_snr_db_threshold)
    self.pitch_standard = 440.0

    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    nsdf_destroy(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}

// Takes the previous detection to repeat when there are no new samples, the Tuner keeps the history
run_pitch_detection :: proc(self: ^PitchDetector, prev_info: PitchInfo) -> PitchInfo {
    info := PitchInfo{}

    // Target FPS so we only run the FFT at so many times per second, instead of hundreds of times
    frames_per_second := 20

    available := audio_capture_read(
        self,
        self.samples,
        i32(self.nsdf.samplerate / frames_per_second),
    )

    // no new audio samples available, skip pitch detection
    if available <= 0 {
        stale := prev_info
        stale.fresh = false
        return stale
    }

    info.measured = true
    info.fresh = true
    info.detected_freq, info.nsdf_peak = nsdf_pitch_detect(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.rms = math.max(calculate_rms(self.samples), MIN_RMS_TRACKABLE)
    info.rms_dbfs = dbfs(info.rms)

    dt := f32(available) / f32(self.nsdf.samplerate)
    // Down to A0, flat by up to half a semitone, at the pitch standard
    min_freq := cents_to_freq(LOWEST_NOTE * 100 - 50, self.pitch_standard)
    // A clear pitch is a note, not the background, even before the floor knows how loud that is
    info.is_tonal = info.detected_freq >= min_freq && info.clarity >= self.clarity_high
    self.snr_db = update_noise_floor(&self.noise_floor, info.rms, dt, is_tonal = info.is_tonal)
    info.snr_db = self.snr_db
    info.noise_floor = self.noise_floor.level
    // No peak gives 0 Hz, which has no note
    if info.detected_freq > 0 {
        info.detected_note = find_note(info.detected_freq, self.pitch_standard)
        info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)
    }

    weak_snr_db := self.min_snr_db - SNR_HYSTERESIS_DB
    strong_snr_db := weak_snr_db if prev_info.is_strong_pitch else self.min_snr_db

    info.is_strong_pitch =
        info.detected_freq >= min_freq &&
        info.clarity >= self.clarity_high &&
        info.snr_db >= strong_snr_db

    info.is_weak_pitch =
        info.detected_freq < min_freq ||
        info.clarity < self.clarity_low ||
        info.snr_db < weak_snr_db

    return info
}

calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}

dbfs :: proc(signal: $T) -> T {
    return 20.0 * math.log10(signal * math.sqrt(cast(T)2.0))
}
