package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"

// -------------------------------------------------------------------------------------------------
//  Pitch detection based on auto-correlation
// -------------------------------------------------------------------------------------------------

PitchConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    fft_conj_product: []complex64,
    autocorrelation: []f32,
    samplerate: int,
    // padded_samples: []f32,
}

pitch_init :: proc (fft_size: int, samplerate: int) -> (config: PitchConfig = {}) {
    config.fft_size = fft_size
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.fft_conj_product = make([]complex64, fft_size)
    config.autocorrelation = make([]f32, fft_size)
    config.samplerate = samplerate
    // config.padded_samples = make([]f32, fft_size)
    return
}

pitch_destroy :: proc (config: PitchConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.fft_conj_product)
    delete(config.autocorrelation)
}


pitch_run_fft :: proc (using config: PitchConfig, samples: []f32) {
    pffft.transform_ordered(
        pffft_setup,
        raw_data(samples),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )

    for i in 0..<len(fft) {
        fft_conj_product[i] = fft[i] * conj(fft[i])
    }

    pffft.transform_ordered(
        pffft_setup,
        raw_data(mem.slice_data_cast([]f32, fft_conj_product)),
        raw_data(autocorrelation),
        nil,
        pffft.Direction.BACKWARD
    )
}


magnitude :: proc (fft_val: complex64) -> f32 {
    return math.sqrt(real(fft_val) * real(fft_val) + imag(fft_val) * imag(fft_val))
}


pitch_detect_spectrum :: proc(using config: PitchConfig) -> f32 {
    bin := 0
    max_magnitude := f32(0.0)

    for i in 3..<fft_size/2 {
        magnitude := magnitude(fft[i])
        if magnitude > max_magnitude {
            max_magnitude = magnitude
            bin = i
        }
    }

    // Parabolic interpolation
    peak_location: f32 = 0
    if bin > 0 {
        peak_location = parabolic_interpolation(
            magnitude(fft[bin-1]),
            magnitude(fft[bin]),
            magnitude(fft[bin+1])
        )
    }

    improved_bin := f32(bin) + peak_location

    freq := improved_bin * SAMPLERATE / FFT_SIZE
    return freq
}


// Parabolic interpolation to find the more accurate peak location
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic_interpolation :: proc (alpha: f32, beta: f32, gamma: f32) -> f32 {
    return 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma)
}


// TODO: compare padded vs unpadded fft
// Detect pitch via auto-correlation
pitch_detect_ac :: proc (using config: PitchConfig) -> (f32, f32, f32) {

    // Generate the autocorrelation
    //   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
    //    then taking the inverse FFT will give us the cyclic auto-correlation.

    // copy(padded_samples, samples)

    // Find the first maximum peak lag
    lag := 0
    threshold := 0.3 * autocorrelation[0]
    estimated_freq := f32(0)

    i := 1

    len := len(autocorrelation) / 2
    peak_index := 0


    for i < len {

        // go down the slope until we reach the local minimum
        for i < len - 1 && autocorrelation[i+1] < autocorrelation[i] {
            i += 1
        }


        lag = i
        // fmt.println("local min", i, autocorrelation[i]/autocorrelation[0], threshold/autocorrelation[0])


        // we want to look up to n/2 and find the lag for the max peak
        for i < len - 1 {
            if autocorrelation[i+1] > autocorrelation[lag] {
                lag = i + 1
            }
            i += 1
        }

        // go up the slope until we reach the local maximum
        // for i < len - 1 && autocorrelation[i+1] > autocorrelation[i] {
        //     i += 1
        // }

        // fmt.println("local max", i, autocorrelation[i]/autocorrelation[0], threshold/autocorrelation[0])

        // if autocorrelation[i] > threshold {
        //     lag = i
        //     // trying to find the fundamental when the first harmonic is close,
        //     //  even if second the peak is a tiny bit smaller
        //     threshold = autocorrelation[i]
        //     // fmt.println("Found local max at", i)
        //     peak_index += 1
        // }

        // // we don't need to look at other peaks?
        // if peak_index >= 2 do break

        i += 1
    }

    // fmt.println("Found peak at lag", lag, i)
    // estimated_freq = f32(samplerate) / f32(lag)
    // fmt.println("Estimated frequency Hz", estimated_freq)



    peak_location: f32 = 0
    if lag > 0 {
        peak_location = parabolic_interpolation(
            autocorrelation[lag-1],
            autocorrelation[lag],
            autocorrelation[lag+1]
        )
    }

    improved_lag := f32(lag) + peak_location

    if improved_lag > 0.0 {
        estimated_freq = f32(samplerate) / improved_lag
    }

    // fmt.println("Interpolated peak location", improved_lag)
    // fmt.println("Estimated frequency improved Hz", estimated_freq, improved_lag)

    normalized_val := autocorrelation[lag] / autocorrelation[0]
    return estimated_freq, f32(lag), normalized_val
}
