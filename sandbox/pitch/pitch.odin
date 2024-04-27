package pitch
import "core:mem"
import "core:fmt"

import "../../pffft"

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


// TODO: compare padded vs unpadded fft
pitch_detect :: proc (using config: PitchConfig, samples: []f32) -> (f32, f32, f32) {

    // Generate the autocorrelation
    //   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
    //    then taking the inverse FFT will give us the cyclic auto-correlation.

    // copy(padded_samples, samples)

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

    // Find the first maximum peak lag
    lag := 0
    threshold := 0.3 * autocorrelation[0]
    estimated_freq := f32(0)

    i := 1

    len := len(autocorrelation) / 2

    fmt.println("Threshold",  autocorrelation[1]/autocorrelation[0], autocorrelation[2]/autocorrelation[0], autocorrelation[3]/autocorrelation[0])
    peak_index := 0

    for i < len {

        // go down the slope until we reach the local minimum
        for i < len - 1 && autocorrelation[i+1] < autocorrelation[i] {
            i += 1
        }
        // fmt.println("local min", i, autocorrelation[i]/autocorrelation[0], threshold/autocorrelation[0])

        // go up the slope until we reach the local maximum
        for i < len - 1 && autocorrelation[i+1] > autocorrelation[i] {
            i += 1
        }

        // fmt.println("local max", i, autocorrelation[i]/autocorrelation[0], threshold/autocorrelation[0])

        if autocorrelation[i] > threshold {
            lag = i
            // trying to find the fundamental when the first harmonic is close,
            //  even if second the peak is a tiny bi smaller
            threshold = 0.9 * autocorrelation[i]
            fmt.println("Found local max at", i)
            peak_index += 1
        }

        // we don't need to look at other peaks?
        if peak_index >= 2 do break

        i += 1
    }

    // fmt.println("Found peak at lag", lag, i)
    // estimated_freq = f32(samplerate) / f32(lag)
    // fmt.println("Estimated frequency Hz", estimated_freq)

    // Parabolic interpolation to find the more accurate peak location
    // https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html

    peak_location: f32 = 0
    if lag > 0 {
        alpha := autocorrelation[lag-1]
        beta := autocorrelation[lag]
        gamma := autocorrelation[lag+1]
        peak_location = 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma)
    }

    improved_lag := f32(lag) + peak_location
    estimated_freq = f32(samplerate) / improved_lag
    // fmt.println("Interpolated peak location", improved_lag)
    // fmt.println("Estimated frequency improved Hz", estimated_freq)

    normalized_val := autocorrelation[lag] / autocorrelation[0]
    return estimated_freq, f32(lag), normalized_val
}
