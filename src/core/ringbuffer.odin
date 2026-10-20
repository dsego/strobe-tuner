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

// Ported from PortAudio's ring buffer, src/common/pa_ringbuffer.c:
//
// Author: Phil Burk, http://www.softsynth.com
// modified for SMP safety on Mac OS X by Bjorn Roche
// modified for SMP safety on Linux by Leland Lucius
// also, allowed for const where possible
// modified for multiple-byte-sized data elements by Sven Fischer
//
// Copyright (c) 1999-2000 Ross Bencina and Phil Burk
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software,
// and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
// ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
// CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


package core

import "base:intrinsics"

// Samples from one thread to another, one writes and one reads. The indexes run over twice the length, equal
// is empty and a length apart is full. Each side publishes its index after its copy with a release store and
// takes the other's with an acquire load, in place of PortAudio's memory barriers.
RingBuffer :: struct {
    data:        []f32, // a power of 2 long
    write_index: int, // stored by the writer
    read_index:  int, // stored by the reader
}

init_ringbuffer :: proc(size: int) -> RingBuffer {
    assert(size > 0 && size & (size - 1) == 0, "a ring buffer is a power of 2 long")

    return {data = make([]f32, size)}
}

destroy_ringbuffer :: proc(self: ^RingBuffer) {
    delete(self.data)
}

// The samples between the indexes, either side's view
ringbuffer_count :: proc(self: ^RingBuffer, write_index, read_index: int) -> int {
    return (write_index - read_index) & (2 * len(self.data) - 1)
}

// From the reader
ringbuffer_available :: proc(self: ^RingBuffer) -> int {
    write_index := intrinsics.atomic_load_explicit(&self.write_index, .Acquire)
    return ringbuffer_count(self, write_index, self.read_index)
}

// From the reader, at most what's available
skip_ringbuffer :: proc(self: ^RingBuffer, frame_count: int) {
    read_index := (self.read_index + frame_count) & (2 * len(self.data) - 1)
    intrinsics.atomic_store_explicit(&self.read_index, read_index, .Release)
}

// Only while neither side reads or writes
flush_ringbuffer :: proc(self: ^RingBuffer) {
    self.write_index = 0
    self.read_index = 0
}

// Writes as much as fits, returns how many frames were written. Past the end it wraps to the start.
write_ringbuffer :: proc(self: ^RingBuffer, input: []f32) -> int {
    read_index := intrinsics.atomic_load_explicit(&self.read_index, .Acquire)
    free := len(self.data) - ringbuffer_count(self, self.write_index, read_index)
    count := min(len(input), free)

    start := self.write_index & (len(self.data) - 1)
    first := min(count, len(self.data) - start)
    copy(self.data[start:], input[:first])
    copy(self.data, input[first:count])

    write_index := (self.write_index + count) & (2 * len(self.data) - 1)
    intrinsics.atomic_store_explicit(&self.write_index, write_index, .Release)
    return count
}

// Fills the buffer, or as much of it as there is, returns how many frames were read
read_ringbuffer :: proc(self: ^RingBuffer, buffer: []f32) -> int {
    count := min(len(buffer), ringbuffer_available(self))

    start := self.read_index & (len(self.data) - 1)
    first := min(count, len(self.data) - start)
    copy(buffer, self.data[start:start + first])
    copy(buffer[first:count], self.data[:count - first])

    skip_ringbuffer(self, count)
    return count
}
