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
    using node:   AudioCaptureNode,
    nsdf:         NSDFConfig,
    samples:      []f32,
    clarity_high: f32,
    rms_high:     f32,
    clarity_low:  f32,
    rms_low:      f32,
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
}


init_pitch_detector :: proc(
    samplerate: int,
    fft_size: int,
    clarity_high: f32,
    rms_high: f32,
    clarity_low: f32,
    rms_low: f32,
) -> (
    self: PitchDetector,
) {
    self.samples = make([]f32, fft_size / 2)
    self.nsdf = nsdf_init(fft_size, samplerate)
    self.clarity_high = clarity_high
    self.rms_high = rms_high
    self.clarity_low = clarity_low
    self.rms_low = rms_low
    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    nsdf_destroy(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}


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

    info.measured = true
    info.detected_freq, info.nsdf_peak = nsdf_pitch_detect(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.rms = calculate_rms(self.samples)
    info.rms_dbfs = calculate_dbfs(info.rms)

    info.detected_note = find_note(info.detected_freq)
    info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)

    info.is_strong_pitch = info.clarity > self.clarity_high && info.rms > self.rms_high
    info.is_weak_pitch = info.clarity < self.clarity_low || info.rms < self.rms_low

    return info
}


calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}

calculate_dbfs :: proc(rms: f32) -> f32 {
    // The reason for the sqrt(2) is so the dBFS value of a full-scale sine wave equals 0
    value_dBFS := 20.0 * math.log10(rms * math.sqrt(f32(2.0)))
    return value_dBFS
}
