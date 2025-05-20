package core

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

    // Recalculate windowed twiddles for fast lookup
    for i in 0 ..< self.window_size {
        rotation := w * f32(i)

        // exp(-j*2π*k*i/N)
        blackmann := blackmann_window(f32(i), f32(window_size))
        self.twiddles[i] =
            complex(blackmann, 0.0) * complex(math.cos(rotation), -math.sin(rotation))
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

    return self.dft / complex(f32(self.window_size), 0.0)
}


// TODO: Remove, this won't work with windowed twiddles!
// Recursive DFT based on a previous fully computed DFT value.
// Rotates accumulated DFT result by a fixed twiddle for the hop.
run_recursive_dft :: proc(self: ^SingleFreqDFT, samples: []f32, hop_size: int) -> complex64 {
    assert(len(samples) >= self.window_size + hop_size)

    delta: complex64 = complex(0, 0)
    w := math.TAU * self.norm_freq

    for i in 0 ..< hop_size {
        rotation := w * f32(i)
        twiddle := complex(math.cos(rotation), -math.sin(rotation))
        delta += complex(samples[i + self.window_size] - samples[i], 0) * twiddle
    }
    w_h := w * f32(hop_size)

    twiddle_hop := complex(math.cos(w_h), math.sin(w_h))
    dft_recursive: complex64 = (self.dft + delta) * twiddle_hop

    self.dft = dft_recursive

    return self.dft
}
