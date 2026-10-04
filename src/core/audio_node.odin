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

import "base:intrinsics"
import "core:testing"


// The input's, miniaudio and AAudio convert the device's own. PITCH_FFT_SIZE, MAX_WINDOW_SIZE and the values
// tuned with the sandbox tools are for it.
SAMPLERATE :: 48_000

// The input of one consumer, the pitch detection, the strobe or the scope. The audio thread writes into its
// ring buffer, the consumer reads from it every frame.
AudioCaptureNode :: struct {
    name:            string, // debugging info
    ringbuffer:      RingBuffer,
    ringbuffer_data: []u8,
    // Samples that didn't fit, the main loop stalled for longer than the ring buffer holds. Written by the
    // audio thread, see audio_capture_dropped.
    dropped:         i64,
}

init_audio_capture_node :: proc(self: ^AudioCaptureNode, name: string) {
    // A power of 2 for the PortAudio ring buffer
    self.name = name
    self.ringbuffer, self.ringbuffer_data = init_ringbuffer(65536)
}

// Only while the input is closed, the audio thread doesn't write
flush_audio_capture_ringbuffer :: proc(self: ^AudioCaptureNode) {
    flush_ringbuffer(&self.ringbuffer)
    intrinsics.atomic_store(&self.dropped, 0)
}

destroy_audio_capture_node :: proc(self: ^AudioCaptureNode) {
    delete(self.ringbuffer_data)
}

// From the audio thread, or a test feeding the samples
audio_capture_write :: proc(self: ^AudioCaptureNode, input: []f32) {
    written := write_ringbuffer(&self.ringbuffer, input)
    if written < len(input) do intrinsics.atomic_add(&self.dropped, i64(len(input) - written))
}

// The samples dropped since the last call. A sample clock adds them, the newest sample is that much later
// than the ones read before it.
audio_capture_dropped :: proc(self: ^AudioCaptureNode) -> i64 {
    return intrinsics.atomic_exchange(&self.dropped, 0)
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


// A stall longer than the ring buffer holds, what didn't fit is counted once
@(test)
test_audio_capture_dropped :: proc(t: ^testing.T) {
    node: AudioCaptureNode
    init_audio_capture_node(&node, "test")
    defer destroy_audio_capture_node(&node)

    SAMPLES :: 70_000
    input := make([]f32, SAMPLES)
    defer delete(input)
    audio_capture_write(&node, input)

    available := i64(ringbuffer_available(&node.ringbuffer))
    dropped := audio_capture_dropped(&node)
    testing.expect(t, dropped > 0, "dropped none")
    testing.expect_value(t, available + dropped, SAMPLES)
    testing.expect_value(t, audio_capture_dropped(&node), 0)
}
