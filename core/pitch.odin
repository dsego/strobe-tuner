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


import "core:fmt"
import "core:math"
import "core:time"


PitchDetector :: struct {
    using node:                   AudioCaptureNode,
    nsdf:                         NSDFConfig,
    samples:                      []f32,
    clarity_high:                 f32,
    clarity_low:                  f32,
    rms_history:                  [20]f32,
    rms_history_idx:              int,
    noise_floor:                  f32,
    min_snr_db:                   f32,
    snr_db:                       f32,
    noise_floor_snr_db_threshold: f32,
}


PitchInfo :: struct {
    measured:        bool,
    detected_freq:   f32,
    detected_note:   Note,
    clarity:         f32,
    nsdf_peak:       Vec2,
    rms:             f32,
    rms_dbfs:        f32,
    err_cents:       f32,
    is_strong_pitch: bool,
    is_weak_pitch:   bool,
    snr_db:          f32,
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
    self.noise_floor = 0.01 // initialize to a realistic value to get first SNR
    self.noise_floor_snr_db_threshold = noise_floor_snr_db_threshold

    // Initialize to sentinel values (real RMS values won't be negative)
    for i in 0 ..< len(self.rms_history) {
        self.rms_history[i] = -1.0
    }

    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    nsdf_destroy(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}

tick: time.Tick

// TODO: keep track of previous pitches
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
    if available <= 0 do return prev_info

    // d := time.tick_lap_time(&tick)
    // fmt.println("pitch", time.duration_milliseconds(d), available, self.nsdf.samplerate)

    info.measured = true
    info.detected_freq, info.nsdf_peak = nsdf_pitch_detect(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.rms = calculate_rms(self.samples)
    info.rms_dbfs = calculate_dbfs(info.rms)

    // current SNR
    self.snr_db = 20.0 * math.log10(info.rms / self.noise_floor)
    info.snr_db = self.snr_db

    update_noise_floor(self, info.rms)

    info.detected_note = find_note(info.detected_freq)
    info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)

    info.is_strong_pitch = info.clarity > self.clarity_high && info.snr_db > self.min_snr_db
    info.is_weak_pitch = info.clarity < self.clarity_low || info.snr_db < self.min_snr_db

    return info
}


@(private)
// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_noise_floor :: proc(self: ^PitchDetector, rms: f32) {

    // Update RMS history
    self.rms_history[self.rms_history_idx] = rms
    self.rms_history_idx += 1
    if self.rms_history_idx >= len(self.rms_history) {
        self.rms_history_idx = 0
    }

    // Pause updating when signal is loud, based on an SNR threshold
    if self.snr_db >= self.noise_floor_snr_db_threshold do return

    min_rms: f32 = rms

    // Find minimum RMS
    for val in self.rms_history {
        if val > -1.0 && val < min_rms {
            min_rms = val
        }
    }

    // Set noise floor based on minimum RMS over X windows
    if min_rms < self.noise_floor {
        // Fast update downward
        self.noise_floor = min_rms
    } else {
        // Slow upward adaptation to avoid overreaction
        alpha: f32 = 0.1
        self.noise_floor += alpha * (min_rms - self.noise_floor)
    }
}

@(private)
calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}

@(private)
calculate_dbfs :: proc(rms: f32) -> f32 {
    // The reason for the sqrt(2) is so the dBFS value of a full-scale sine wave equals 0
    value_dBFS := 20.0 * math.log10(rms * math.sqrt(f32(2.0)))
    return value_dBFS
}
