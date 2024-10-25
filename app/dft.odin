package app

import "core:math"
import "core:time"
import "core:fmt"

import helpers "../sandbox/helpers"


SingleFreqDFT :: struct {
    size: int,
    twiddle_lookup: []complex64,
    window: []f32, // eg Blackmann window
}

init_dft :: proc (size: int) -> SingleFreqDFT {
    self := SingleFreqDFT{}
    self.size = size
    self.window = make([]f32, size)
    self.twiddle_lookup = make([]complex64, size)

    // Generate the Blackmann window
    for i in 0..<size {
        self.window[i] = blackmann_window(f32(i), f32(size))
    }

    return self
}

set_dft_freq :: proc (self: ^SingleFreqDFT, norm_freq: f32) {
    phase_delta: f32 = math.TAU // f32(self.size) // τ = 2π
    for i in 0..<self.size {
        time := f32(i)
        phase := phase_delta * time * norm_freq
        self.twiddle_lookup[i] = complex(self.window[i], 0) * complex(math.cos(phase), math.sin(phase))
    }
}

destory_dft :: proc (self: ^SingleFreqDFT) {
    delete(self.window)
    delete(self.twiddle_lookup)
}


run_single_dft :: proc (self: ^SingleFreqDFT, samples: []f32) -> complex64 {
    assert(len(samples) >= self.size)

    dft: complex64 = complex(0, 0)

    for i in 0..<self.size {
        dft += complex(samples[i], 0) * self.twiddle_lookup[i]
    }

    return dft
}

