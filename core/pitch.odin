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
    using node: AudioCaptureNode,
    nsdf:       NSDFConfig,
    samples:    []f32,
}


PitchInfo :: struct {
    detected_freq: f32,
    detected_note: Note,
    clarity:       f32,
    nsdf_peak:     Vec2,
    rms:           f32,
    rms_dbfs:      f32,
    err_cents:     f32,
}


init_pitch_detector :: proc(samplerate: int, fft_size: int) -> (self: PitchDetector) {
    self.samples = make([]f32, fft_size / 2)
    self.nsdf = nsdf_init(fft_size, samplerate)
    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    nsdf_destroy(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}

// t: time.Time
// started: bool = false
// counter: int = 0

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

    // // FIXME: Runs too many time per second, around 270
    // duration := time.since(t)
    // counter += 1
    // if time.duration_seconds(duration) >= 1.0 || started == false {
    //     started = true
    //     t = time.now()
    //     fmt.println(time.now(), "count", counter, available)
    //     counter = 0
    // }

    info.detected_freq, info.nsdf_peak = nsdf_pitch_detect(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.rms = calculate_rms(self.samples)
    info.rms_dbfs = calculate_dbfs(info.rms)

    info.detected_note = find_note(info.detected_freq)
    info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)

    return info
}


calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}

calculate_dbfs :: proc(rms: f32) -> f32 {
    value_dBFS := 20.0 * math.log10(rms * math.sqrt(f32(2.0)))
    return value_dBFS
}

// compare RMS based on dBFS ?
is_strong_pitch :: proc(pitch_info: PitchInfo, clarity: f32, rms: f32) -> bool {
    return pitch_info.clarity > clarity && pitch_info.rms > rms
}

is_weak_pitch :: proc(pitch_info: PitchInfo, clarity: f32, rms: f32) -> bool {
    return pitch_info.clarity < clarity || pitch_info.rms < rms
}
