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

import pa_rb "../../external/odin-pa_ringbuffer"


/* -------------------------------------------------------------------------------------------------

    A shallow wrapper around the PortAudio ringbuffer implementation

------------------------------------------------------------------------------------------------- */


RingBuffer :: pa_rb.RingBuffer


init_ringbuffer :: proc(size: int) -> (RingBuffer, []u8) {
    ringbuffer := RingBuffer{}
    data := make([]u8, size * size_of(f32))
    pa_rb.InitializeRingBuffer(&ringbuffer, pa_rb.rb_size_t(size_of(f32)), pa_rb.rb_size_t(size), raw_data(data))
    return ringbuffer, data
}


skip_ringbuffer :: proc(self: ^RingBuffer, frame_count: int) {
    pa_rb.AdvanceRingBufferReadIndex(self, pa_rb.rb_size_t(frame_count))
}

ringbuffer_available :: proc(self: ^RingBuffer) -> int {
    return int(pa_rb.GetRingBufferReadAvailable(self))
}

flush_ringbuffer :: proc(self: ^RingBuffer) {
    pa_rb.FlushRingBuffer(self)
}

// Writes as much as fits, returns how many frames were written
write_ringbuffer :: proc(self: ^RingBuffer, input: []f32) -> int {
    return int(pa_rb.WriteRingBuffer(self, raw_data(input), pa_rb.rb_size_t(len(input))))
}

// Fills the buffer, or as much of it as there is, returns how many frames were read
read_ringbuffer :: proc(self: ^RingBuffer, buffer: []f32) -> int {
    return int(pa_rb.ReadRingBuffer(self, raw_data(buffer), pa_rb.rb_size_t(len(buffer))))
}
