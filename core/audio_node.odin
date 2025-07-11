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


AudioCaptureNode :: struct {
    name:            string, // debugging info
    ringbuffer:      RingBuffer,
    ringbuffer_data: []u8,
    stream_callback: proc(ctx: ^AudioCaptureNode, input: []f32),
}

init_audio_capture_node :: proc(self: ^AudioCaptureNode, name: string) {
    // NOTE: Needs to be a power of 2 for portaudio ring buffers
    rb, rb_data := init_ringbuffer(65536)
    self.name = name
    self.ringbuffer = rb
    self.ringbuffer_data = rb_data
    self.stream_callback = audio_capture_callback
}

flush_audio_capture_ringbuffer :: proc(self: ^AudioCaptureNode) {
    flush_ringbuffer(&self.ringbuffer)
}

destroy_audio_capture_node :: proc(self: ^AudioCaptureNode) {
    delete(self.ringbuffer_data)
}

audio_capture_callback :: proc(self: ^AudioCaptureNode, input: []f32) {
    write_to_ringbuffer(&self.ringbuffer, input)
}

// Fill the buffer with new audio samples.
// If there are more samples available than the size of the buffer, it will overwrite the complete
// buffer with new samples. Otherwise it will shift the existing samples.
audio_capture_read :: proc(
    self: ^AudioCaptureNode,
    audio_buffer: []f32,
    min_available: i32 = 0,
) -> i32 {
    available := frames_available_in_ringbuffer(&self.ringbuffer)

    if available <= min_available do return 0

    size := len(audio_buffer)

    if int(available) >= size {
        skip := available - i32(size)
        advance_ringbuffer_read(&self.ringbuffer, skip)
        read_ringbuffer(&self.ringbuffer, audio_buffer[:], u32(size))
    } else {
        // move old samples back to make room for new samples
        copy(audio_buffer, audio_buffer[available:size])

        // copy over new samples into the freed space
        offset := size - int(available)
        read_ringbuffer(&self.ringbuffer, audio_buffer[offset:], u32(available))
    }

    return available
}
