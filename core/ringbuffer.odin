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

import pa_rb "../external/odin-pa_ringbuffer"


/* -------------------------------------------------------------------------------------------------

    A shallow wrapper around the PortAudio ringbuffer implementation

------------------------------------------------------------------------------------------------- */


RingBuffer :: pa_rb.RingBuffer


init_ringbuffer :: proc(size: int) -> (RingBuffer, []u8) {
    ringbuffer := RingBuffer{}
    data := make([]u8, size * size_of(f32))
    pa_rb.InitializeRingBuffer(&ringbuffer, i32(size_of(f32)), i32(size), raw_data(data))
    return ringbuffer, data
}


advance_ringbuffer_read :: proc(self: ^RingBuffer, frames_to_skip: i32) -> i32 {
    return pa_rb.AdvanceRingBufferReadIndex(self, frames_to_skip)
}

frames_available_in_ringbuffer :: proc(self: ^RingBuffer) -> i32 {
    return pa_rb.GetRingBufferReadAvailable(self)
}


flush_ringbuffer :: proc(self: ^RingBuffer) {
    pa_rb.FlushRingBuffer(self)
}

write_to_ringbuffer :: proc(self: ^RingBuffer, input: []f32) {
    pa_rb.WriteRingBuffer(self, raw_data(input), i32(len(input)))
}


read_ringbuffer :: proc(self: ^RingBuffer, buffer: []f32, frame_count: u32) -> u32 {
    assert(len(buffer) >= int(frame_count), "frame_count larger than buffer size")

    frames_read := pa_rb.ReadRingBuffer(self, raw_data(buffer), i32(frame_count))
    return u32(frames_read)
}
