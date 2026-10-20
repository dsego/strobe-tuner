// Copyright (C) 2026  Davorin Šego

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


#+build !js
package core

import "core:slice"
import "core:testing"


// A stall longer than the ring buffer holds, the stale samples are skipped and the time counted once
@(test)
test_audio_capture_stall :: proc(t: ^testing.T) {
    node: AudioCaptureNode
    init_audio_capture_node(&node, DEFAULT_SAMPLE_RATE)
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
