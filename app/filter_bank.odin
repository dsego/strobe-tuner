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
run_dft :: proc(freq_hz: f32, samples: []f32, samplerate: f32, drift: f32 = 0.0) -> (dft: complex64) {
    freq_bin := freq_hz / samplerate

    for sample, i in samples {
        time := 2.0 * math.PI * (f32(i) + drift)

        // Fourier formula: cos(2πft) - i×sin(2πft)
        ft := freq_bin * time
        re := sample * math.cos(ft)
        im := sample * math.sin(ft)

        dft += complex(re, im)
    }
    return
}


// TODO
// TODO
// TODO
//  Precalculate sin/cos stuff (phase_angle) just once per frequency
reconstruct_from_dft :: proc(
    freq_hz: f32,
    samples: []f32,
    output: []f32,
    samplerate: f32,
    drift: f64,
) -> f32 {
    dft: complex64 = complex(0, 0)

    // interval := samplerate/freq_hz
    // trunc_interval := math.trunc(interval)
    // fraction := interval - trunc_interval
    // freq_hz := samplerate / trunc_interval

    freq_bin := freq_hz / samplerate


    // apply windowing?
    n := f32(len(samples))

    for i in 0..<len(samples) {
        output[i] = samples[i] // * blackmann_window(f32(i), n)
        // output[i] = samples[i] * blackman_harris(f32(i), f32(len(samples)))
    }


    for sample, i in output {
        // Fourier formula: cos(2πft) - i×sin(2πft)
        // -----------------------------------------------
        // PROMISING! Makes the strobe pattern stationary - not quite?
        // -----------------------------------------------
        ft := freq_bin * 2.0 * math.PI * (f32(i) + f32(drift)) // 2πft

        // -----------------------------------------------

        re := sample * math.cos(ft) //*blackmann_window(f32(i), n)
        im := sample * math.sin(ft) //*blackmann_window(f32(i), n)


        dft += complex(re, im)
    }
    // one bin DFT overly aggressive filtering??

    sin := real(dft)
    cos := imag(dft)
    phase := math.atan2(sin, cos)
    amp := magnitude(dft)

    state := 1
    half_interval := samplerate / freq_hz / 2.0
    next_flip := half_interval * phase / math.PI

    for _, i in output {
        output[i] = amp * math.sin(freq_bin * 2.0 * math.PI * f32(i) + phase)
        // if f32(i) > next_flip {
        //     state = -state
        //     next_flip += interval
        // }
        // output[i] = amp * f32(state)
        output[i] /= f32(len(output))
    }

    return amp
}


blackmann_window :: proc (k: f32, size: f32) -> f32 {
    a0:f32 = 0.42
    a1:f32 = 0.5
    a2:f32 = 0.08

    l:f32 = 2.0 * math.PI * k / (2.0 * size/2 - 1.0)
    return a0 - a1 * math.cos(l) + a2 * math.cos(2.0 * l)
}



// TODO instead of  generating a sine, generate a square wave with amp modulating the "strength"


// goertzl 740 ?


// matched filter? - wavelet cross correlation


// add more poles to reson???

// TODO TODO TOD bandpass fir filter


