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
import "core:slice"
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
    // audio thread, see audio_capture_skip_stale.
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

// After a stall that dropped samples, the ones still in the ring buffer came before them and are stale.
// Skips them, returns how many samples went by, the skipped and the dropped, 0 without a stall.
audio_capture_skip_stale :: proc(self: ^AudioCaptureNode) -> (lost: i64) {
    dropped := intrinsics.atomic_exchange(&self.dropped, 0)
    if dropped == 0 do return 0

    available := ringbuffer_available(&self.ringbuffer)
    skip_ringbuffer(&self.ringbuffer, available)
    // Also what was dropped until the skip made room
    return i64(available) + dropped + intrinsics.atomic_exchange(&self.dropped, 0)
}

// Fills the buffer with the new samples, the older ones shift towards the start to make room. Of more than
// fits, the oldest are skipped.
//
// elapsed is the time since the previous read in samples, read of them are new at the end of the buffer.
// When read is less, samples went by that the buffer didn't get, a filter over the new ones starts over.
// After a stall read is 0 and the buffer is silent, see audio_capture_skip_stale, the next read is the
// audio after the gap.
audio_capture_read :: proc(
    self: ^AudioCaptureNode,
    audio_buffer: []f32,
    min_available: i32 = 0,
) -> (
    read: int,
    elapsed: i64,
) {
    if lost := audio_capture_skip_stale(self); lost > 0 {
        slice.zero(audio_buffer)
        return 0, lost
    }

    available := ringbuffer_available(&self.ringbuffer)

    if available <= min_available do return 0, 0

    size := len(audio_buffer)

    if int(available) >= size {
        skip_ringbuffer(&self.ringbuffer, available - i32(size))
        read_ringbuffer(&self.ringbuffer, audio_buffer)
        return size, i64(available)
    }

    // move old samples back to make room for new samples
    copy(audio_buffer, audio_buffer[available:size])

    // copy over new samples into the freed space
    offset := size - int(available)
    read_ringbuffer(&self.ringbuffer, audio_buffer[offset:])

    return int(available), i64(available)
}


// A stall longer than the ring buffer holds, the stale samples are skipped and the time counted once
@(test)
test_audio_capture_stall :: proc(t: ^testing.T) {
    node: AudioCaptureNode
    init_audio_capture_node(&node, "test")
    defer destroy_audio_capture_node(&node)

    SAMPLES :: 70_000
    input := make([]f32, SAMPLES)
    defer delete(input)
    slice.fill(input, 1)
    audio_capture_write(&node, input)

    buffer: [1024]f32
    slice.fill(buffer[:], 1)
    read, elapsed := audio_capture_read(&node, buffer[:])
    testing.expect_value(t, read, 0)
    testing.expect_value(t, elapsed, SAMPLES)
    testing.expect(t, slice.all_of(buffer[:], 0), "the buffer isn't silent")

    // The audio after the gap
    audio_capture_write(&node, input[:100])
    read, elapsed = audio_capture_read(&node, buffer[:])
    testing.expect_value(t, read, 100)
    testing.expect_value(t, elapsed, 100)
    testing.expect(t, slice.all_of(buffer[len(buffer) - 100:], 1), "the new samples aren't at the end")
}
