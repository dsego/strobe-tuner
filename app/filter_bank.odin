package app

import "core:math"
import "core:fmt"

// Generate piano key frequencies 1-88
//  f(n) = 2 ^ ((n - 49) / 12) * 440
//  https://en.wikipedia.org/wiki/Piano_key_frequencies
LEN :: 88
piano_key_frequencies: [LEN]f32 = {}
piano_key_spectrum: [LEN]f32 = {}

gen_freqs :: proc () {
    for i in 0..<LEN {
        freq := math.pow(2, (f32(i+1) - 49.0) / 12.0) * 440.0
        piano_key_frequencies[i] = freq
    }
}

windowed_samples: [2048]f32

run_filters :: proc (dft_freqs: []f32, samples: []f32, samplerate: f32) {

    for s, i in samples {
        windowed_samples[i] = s * blackman_harris(f32(i), f32(len(samples)))
    }

    for f_hz, i in dft_freqs {
        piano_key_spectrum[i] = magnitude(run_dft(f_hz, windowed_samples[:], samplerate))
    }
}


// A brute force implementation that executes the Fourier formula directly
run_dft :: proc(freq_hz: f32, samples: []f32, samplerate: f32) -> (dft: complex64) {
    freq_bin := freq_hz * f32(len(samples)) / samplerate
    phase_angle:f32 = 2.0 * math.PI / f32(len(samples))

    for sample, i in samples {
        time := phase_angle * f32(i)

        // Fourier formula: cos(2πft) - i×sin(2πft)
        ft := freq_bin * time
        re := sample * math.cos(ft)
        im := -sample * math.sin(ft)

        dft += complex(re, im)
    }
    return
}


reconstruct_from_dft :: proc(
    freq_hz: f32,
    samples: []f32,
    output: []f32,
    samplerate: f32,
) {
    dft: complex64
    freq_bin := freq_hz * f32(len(samples)) / samplerate
    phase_angle: f32 = 2.0 * math.PI / f32(len(samples))

    for sample, i in samples {
        // 2πt
        time := phase_angle * f32(i)

        // Fourier formula: cos(2πft) - i×sin(2πft)
        ft := freq_bin * time // 2πft

        re := sample * math.cos(ft)
        im := -sample * math.sin(ft)

        dft += complex(re, im)
    }

    sin := real(dft)
    cos := imag(dft)
    phase := math.atan2(sin, cos)
    amp := magnitude(dft)

    fmt.println(amp)

    for _, i in samples {
        time := phase_angle * f32(i)
        output[i] = amp * math.sin(freq_bin * time - phase)
        output[i] /= f32(len(output))
    }
}

