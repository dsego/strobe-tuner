package app

import "core:math"
import "core:time"
import "core:fmt"

import helpers "../helpers"

blackmann_window :: proc (k: f32, size: f32) -> f32 {
    a0:f32 = 0.42
    a1:f32 = 0.5
    a2:f32 = 0.08

    l: f32 = math.TAU * k / (size - 1.0)
    return a0 - a1 * math.cos(l) + a2 * math.cos(2.0 * l)
}


run_single_dft :: proc (normalized_freq: f32, sample_slice: []f32) -> complex64 {
    window_size := len(sample_slice)
    dft: complex64 = complex(0, 0)
    for i in 0..<window_size {
        // Fourier formula: cos(2πft) - i×sin(2πft)
        time := f32(i)
        ft := normalized_freq * math.TAU * time  // 2πft
        // We need to window to suppress inaccuracies due to edge effects
        win: f32 = blackmann_window(time, f32(window_size))
        re := sample_slice[i] * win * math.cos(ft)
        im := sample_slice[i] * win * math.sin(ft)
        dft += complex(re, im)
    }
    return dft
}



generate_windowed_twiddles :: proc (normalized_freq: f32, window: []f32, twiddle_lookup: []complex64) {
    win_size := len(twiddle_lookup)
    phase_delta := math.TAU / f32(win_size) // τ = 2π
    for i in 0..<win_size {
        time := f32(i)
        phase := phase_delta * time * normalized_freq
        twiddle_lookup[i] = complex(window[i], 0) * complex(math.cos(phase), -math.sin(phase))
    }
}

generate_blackmann_window :: proc (window: []f32) {
    size := len(window)
    for i in 0..<size {
        time := f32(i)
        window[i] = blackmann_window(time, f32(size))
    }
}

run_single_dft_optim :: proc (
    normalized_freq: f32,
    sample_slice: []f32,
    twiddle_lookup: []complex64,
) -> complex64 {
    window_size := len(sample_slice)
    dft: complex64 = complex(0, 0)
    for i in 0..<window_size {
        dft += complex(sample_slice[i], 0) * twiddle_lookup[i]
    }
    return dft
}



ITERATIONS :: 10000
WIN_SIZE :: 4096
NORM_FREQ :: 110.0 / 44100.0

// Naive single DFT: 149.2359791 µs
// Optimized single DFT: 42.769783399999994 µs

main :: proc () {
    path: cstring = "./media/acoustic_A2.wav"
    audio_buffer := make([]f32, 2000000)
    defer delete(audio_buffer)
    helpers.read_wav(path=path, samples=audio_buffer)


    // ----------------------------------------
    // Naive version
    // ----------------------------------------
    {
        stopwatch := time.Stopwatch{}
        time.stopwatch_start(&stopwatch)

        for i in 0..<ITERATIONS do run_single_dft(NORM_FREQ, audio_buffer[:WIN_SIZE])

        time.stopwatch_stop(&stopwatch)
        duration := time.stopwatch_duration(stopwatch)

        µs := time.duration_microseconds(duration)
        fmt.printf("Naive single DFT: {} µs\n", µs / f64(ITERATIONS))

    }

    // ----------------------------------------
    // Optimized version
    // ----------------------------------------
    {
        twiddles : [WIN_SIZE]complex64
        window : [WIN_SIZE]f32

        generate_blackmann_window(window[:])
        generate_windowed_twiddles(NORM_FREQ, window[:], twiddles[:])

        stopwatch := time.Stopwatch{}
        time.stopwatch_start(&stopwatch)

        for i in 0..<ITERATIONS do run_single_dft_optim(NORM_FREQ, audio_buffer[:WIN_SIZE], twiddles[:])

        time.stopwatch_stop(&stopwatch)
        duration := time.stopwatch_duration(stopwatch)

        µs := time.duration_microseconds(duration)
        fmt.printf("Optimized single DFT: {} µs\n", µs / f64(ITERATIONS))
    }
}
