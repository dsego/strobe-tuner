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
import "core:math/cmplx"


// Interpolated DFT
IntpSingleFreqDFT :: struct {
    window_size:    int,
    twiddles_zero:  []complex64,
    twiddles_minus: []complex64,
    twiddles_plus:  []complex64,
    dft_zero:       complex64,
    dft_minus:      complex64,
    dft_plus:       complex64,
}


init_intp_dft :: proc(max_size: int) -> IntpSingleFreqDFT {
    self := IntpSingleFreqDFT{}
    self.twiddles_zero = make([]complex64, max_size)
    self.twiddles_minus = make([]complex64, max_size)
    self.twiddles_plus = make([]complex64, max_size)
    return self
}

set_intp_dft_freq :: proc(
    self: ^IntpSingleFreqDFT,
    window_size: int,
    freq_hz: f32,
    samplerate: f32,
    shift_cents: f32,
) {
    assert(window_size <= len(self.twiddles_zero))

    self.window_size = window_size

    freq_hz_minus := cents_to_freq(-shift_cents, freq_hz)
    freq_hz_plus := cents_to_freq(shift_cents, freq_hz)

    w_zero := math.TAU * freq_hz / samplerate
    w_minus := math.TAU * freq_hz_minus / samplerate
    w_plus := math.TAU * freq_hz_plus / samplerate

    delta_minus := w_minus - w_zero
    delta_plus := w_plus - w_zero

    rot_step_zero := complex(math.cos(w_zero), -math.sin(w_zero))
    rot_step_minus := complex(math.cos(delta_minus), -math.sin(delta_minus))
    rot_step_plus := complex(math.cos(delta_plus), -math.sin(delta_plus))

    phase_zero: complex64 = complex(1.0, 0.0)
    phase_minus: complex64 = complex(1.0, 0.0)
    phase_plus: complex64 = complex(1.0, 0.0)

    // Recalculate windowed twiddles for fast lookup
    for i in 0 ..< self.window_size {
        // exp(-j*2π*k*i/N)
        blackmann := blackmann_window(f32(i), f32(window_size))
        base := complex(blackmann, 0.0) * phase_zero

        self.twiddles_zero[i] = base
        self.twiddles_minus[i] = base * phase_minus
        self.twiddles_plus[i] = base * phase_plus

        phase_zero *= rot_step_zero
        phase_minus *= rot_step_minus
        phase_plus *= rot_step_plus
    }
}

destory_intp_dft :: proc(self: ^IntpSingleFreqDFT) {
    delete(self.twiddles_zero)
    delete(self.twiddles_minus)
    delete(self.twiddles_plus)
}

// Compute full DFT once
run_intp_dft :: proc(self: ^IntpSingleFreqDFT, samples: []f32) -> complex64 {
    assert(len(samples) >= self.window_size)

    self.dft_minus = complex(0, 0)
    self.dft_zero = complex(0, 0)
    self.dft_plus = complex(0, 0)

    for i in 0 ..< self.window_size {
        self.dft_minus += complex(samples[i], 0) * self.twiddles_minus[i]
        self.dft_zero += complex(samples[i], 0) * self.twiddles_zero[i]
        self.dft_plus += complex(samples[i], 0) * self.twiddles_plus[i]
    }

    self.dft_minus /= complex(f32(self.window_size), 0.0)
    self.dft_zero /= complex(f32(self.window_size), 0.0)
    self.dft_plus /= complex(f32(self.window_size), 0.0)

    return self.dft_zero + self.dft_minus + self.dft_plus
}
