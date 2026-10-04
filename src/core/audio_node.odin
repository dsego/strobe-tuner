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


// The input's, miniaudio and AAudio convert the device's own. PITCH_FFT_SIZE, MAX_WINDOW_SIZE and the values
// tuned with the sandbox tools are for it.
SAMPLERATE :: 48_000

// The input of one consumer, the pitch detection, the strobe or the scope. The audio thread writes into its
// ring buffer, the consumer reads from it every frame.
AudioCaptureNode :: struct {
    name:            string, // debugging info
    ringbuffer:      RingBuffer,
    ringbuffer_data: []u8,
}

init_audio_capture_node :: proc(self: ^AudioCaptureNode, name: string) {
    // A power of 2 for the PortAudio ring buffer
    self.name = name
    self.ringbuffer, self.ringbuffer_data = init_ringbuffer(65536)
}

flush_audio_capture_ringbuffer :: proc(self: ^AudioCaptureNode) {
    flush_ringbuffer(&self.ringbuffer)
}

destroy_audio_capture_node :: proc(self: ^AudioCaptureNode) {
    delete(self.ringbuffer_data)
}

// From the audio thread, or a test feeding the samples
audio_capture_write :: proc(self: ^AudioCaptureNode, input: []f32) {
    write_ringbuffer(&self.ringbuffer, input)
}

// Fill the buffer with new audio samples.
// If there are more samples available than the size of the buffer, it will overwrite the complete
// buffer with new samples. Otherwise it will shift the existing samples.
audio_capture_read :: proc(
    self: ^AudioCaptureNode,
    audio_buffer: []f32,
    min_available: i32 = 0,
) -> i32 {
    available := ringbuffer_available(&self.ringbuffer)

    if available <= min_available do return 0

    size := len(audio_buffer)

    if int(available) >= size {
        skip_ringbuffer(&self.ringbuffer, available - i32(size))
        read_ringbuffer(&self.ringbuffer, audio_buffer)
    } else {
        // move old samples back to make room for new samples
        copy(audio_buffer, audio_buffer[available:size])

        // copy over new samples into the freed space
        offset := size - int(available)
        read_ringbuffer(&self.ringbuffer, audio_buffer[offset:])
    }

    return available
}
