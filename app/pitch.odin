package app

import "core:fmt"
import "core:math"



PicthDetector :: struct {
    using node: AudioCaptureNode,
    autocorr: AcConfig,
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    samples: []f32,
}


PitchInfo :: struct {
    detected_freq: f32,
    detected_note: Note,
    clarity: f32,
    nsdf_peak: Vec2,
    rms: f32,
    found: bool,
}


init_pitch_detector :: proc() -> (self: PicthDetector) {
    self.samples = make([]f32, FFT_SIZE/2)
    self.autocorr = ac_init(FFT_SIZE, SAMPLERATE)
    rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
    self.ringbuffer = rb
    self.ringbuffer_data = rb_data
    self.stream_callback = pitch_audio_callback
    return
}

destroy_pitch_detector :: proc(self: ^PicthDetector) {
    ac_destroy(&self.autocorr)
    delete(self.samples)
    delete(self.ringbuffer_data)
}

pitch_audio_callback :: proc (ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, PicthDetector, "node")
    write_to_ringbuffer(&self.ringbuffer, input)
}


// TODO: keep track of previous pitches
run_pitch_detection :: proc (self: ^PicthDetector, prev_info: PitchInfo) -> PitchInfo {
    info := PitchInfo{}

    new_count := int(frames_available_in_ringbuffer(&self.ringbuffer))

    // no new audio samples available, skip pitch detection
    if new_count <= 0 do return info

    // TODO test if this introduces discontinuities !!!

    if new_count < len(self.samples) {
        // move old samples back to make room for new samples
        copy(self.samples, self.samples[new_count:])

        // copy over new samples into the freed space
        pos := len(self.samples) - new_count
        read_ringbuffer(&self.ringbuffer, self.samples[pos:], u32(new_count))
    } else {
        read_ringbuffer(&self.ringbuffer, self.samples, u32(len(self.samples)))
    }

    info.detected_freq, info.nsdf_peak = ac_pitch_detect(&self.autocorr, self.samples)
    info.clarity = info.nsdf_peak.y
    info.rms = calculate_rms(self.samples)

    info.detected_note = find_note(info.detected_freq)


    // -20dB
    info.found = info.rms >= 0.01 && info.clarity >= 0.98

    return info
}


calculate_rms :: proc (samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}
