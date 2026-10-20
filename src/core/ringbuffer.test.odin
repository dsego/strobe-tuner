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

import "core:testing"


@(test)
test_ringbuffer_wraps :: proc(t: ^testing.T) {
    ringbuffer := init_ringbuffer(8)
    defer destroy_ringbuffer(&ringbuffer)

    // Full at 8, the rest is turned away
    testing.expect_value(t, write_ringbuffer(&ringbuffer, {1, 2, 3, 4, 5, 6, 7, 8, 9}), 8)
    testing.expect_value(t, ringbuffer_available(&ringbuffer), 8)

    first: [5]f32
    testing.expect_value(t, read_ringbuffer(&ringbuffer, first[:]), 5)
    testing.expect_value(t, first, [5]f32{1, 2, 3, 4, 5})

    // Past the end and on from the start
    testing.expect_value(t, write_ringbuffer(&ringbuffer, {10, 11, 12, 13}), 4)
    testing.expect_value(t, ringbuffer_available(&ringbuffer), 7)

    skip_ringbuffer(&ringbuffer, 1)
    rest: [8]f32
    testing.expect_value(t, read_ringbuffer(&ringbuffer, rest[:]), 6)
    testing.expect_value(t, rest, [8]f32{7, 8, 10, 11, 12, 13, 0, 0})
    testing.expect_value(t, ringbuffer_available(&ringbuffer), 0)
}
