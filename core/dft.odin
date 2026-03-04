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
import "core:math"


SingleFreqDFT :: struct {
    window_size: int,
    norm_freq:   f32, // normalized frequency, eg 440Hz/ 48,000Hz
    twiddles:    []complex64, // precomputed twiddle lookup (windowed)
    dft:         complex64, // stores the resulting DFT after calling run_single_dft
}


init_dft :: proc(max_size: int) -> SingleFreqDFT {
    self := SingleFreqDFT{}
    self.twiddles = make([]complex64, max_size)
    return self
}

set_dft_freq :: proc(self: ^SingleFreqDFT, norm_freq: f32, window_size: int) {
    assert(window_size <= len(self.twiddles))

    self.window_size = window_size
    self.norm_freq = norm_freq
    w := math.TAU * norm_freq

    rot_step := complex(math.cos(w), -math.sin(w))
    phase: complex64 = complex(1.0, 0.0)

    // Recalculate windowed twiddles for fast lookup
    for i in 0 ..< self.window_size {
        // exp(-j*2π*k*i/N)

        // This can further be optimized with incremental Blackman logic to
        //  save on cos/sin calls.
        blackmann := blackmann_window(f32(i), f32(window_size))

        self.twiddles[i] = complex(blackmann, 0.0) * phase
        phase *= rot_step

    }
}

destory_dft :: proc(self: ^SingleFreqDFT) {
    delete(self.twiddles)
}

// Compute full DFT once
run_single_dft :: proc(self: ^SingleFreqDFT, samples: []f32) -> complex64 {
    assert(len(samples) >= self.window_size)

    self.dft = complex(0, 0)

    for i in 0 ..< self.window_size {
        self.dft += complex(samples[i], 0) * self.twiddles[i]
    }

    self.dft /= complex(f32(self.window_size), 0.0)

    return self.dft
}
