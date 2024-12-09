package core


import "base:runtime"
import "core:fmt"
import "core:math"


PicthDetector :: struct {
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
}


init_pitch_detector :: proc(samplerate: int, fft_size: int) -> (self: PicthDetector) {
    self.samples = make([]f32, fft_size / 2)
    self.nsdf = nsdf_init(fft_size, samplerate)
    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PicthDetector) {
    destroy_audio_capture_node(self)
    nsdf_destroy(&self.nsdf)
    delete(self.samples)
}


// TODO: keep track of previous pitches
run_pitch_detection :: proc(self: ^PicthDetector, prev_info: PitchInfo) -> PitchInfo {
    info := PitchInfo{}
    available := audio_capture_read(self, self.samples)

    // no new audio samples available, skip pitch detection
    if available <= 0 do return prev_info

    info.detected_freq, info.nsdf_peak = nsdf_pitch_detect(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.rms = calculate_rms(self.samples)

    info.detected_note = find_note(info.detected_freq)
    return info
}


calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}

// compare RMS based on dBFS ?
// TODO: define thresholds in config
is_strong_pitch :: proc(pitch_info: PitchInfo) -> bool {
    return pitch_info.clarity > 0.95 && pitch_info.rms > 0.05
}

// TODO: define thresholds in config
is_weak_pitch :: proc(pitch_info: PitchInfo) -> bool {
    return pitch_info.clarity < 0.9 || pitch_info.rms < 0.001
}
