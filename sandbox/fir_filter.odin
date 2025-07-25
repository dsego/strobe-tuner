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

import "core:fmt"
import "core:testing"


FirFilter :: struct {
    buffer:  []f32,
    weights: []f32, // aka impulse response
    average: f32,
    index:   int,
}

init_fir_filter :: proc(size: int) -> FirFilter {
    self := FirFilter{}
    self.buffer = make([]f32, size)
    self.weights = make([]f32, size)
    return self
}

destroy_fir_filter :: proc(self: ^FirFilter) {
    delete(self.buffer)
    delete(self.weights)
}

// TODO: weights need to shift based on index
run_fir_filter :: proc(self: ^FirFilter, input: f32) -> f32 {
    size := len(self.buffer)

    self.average -= self.buffer[self.index] / f32(size)

    // replace the oldest entry with the newest
    self.buffer[self.index] = input
    self.average += input / f32(size)

    self.index += 1
    if self.index >= size do self.index = 0
    return self.average
}


@(test)
test_fir_filter :: proc(t: ^testing.T) {
    avg := init_fir_filter(5)
    defer destroy_fir_filter(&avg)

    // (4 + 2 + 1 + 8 + 2 ) / 5
    run_fir_filter(&avg, 4)
    run_fir_filter(&avg, 2)
    run_fir_filter(&avg, 1)
    run_fir_filter(&avg, 8)
    r := run_fir_filter(&avg, 2)

    testing.expect_value(t, r, 3.4)

    // ( 8 + 2 + 3 + 3 + 7)  / 5
    run_fir_filter(&avg, 3)
    run_fir_filter(&avg, 3)
    r = run_fir_filter(&avg, 7)

    testing.expect_value(t, r, 4.6)

}
