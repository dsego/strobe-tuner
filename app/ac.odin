package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"

// -------------------------------------------------------------------------------------------------
//  Pitch detection based on auto correlation
// ------------------------------------------------------------------------------------------------

AcConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    autocorrelation: []f32,
    samplerate: int,
    padded_samples: []f32,
}

ac_init :: proc (fft_size: int, samplerate: int) -> (config: AcConfig = {}) {
    config.fft_size = fft_size
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.autocorrelation = make([]f32, fft_size)
    config.samplerate = samplerate
    config.padded_samples = make([]f32, fft_size)
    return
}

ac_destroy :: proc (config: ^AcConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.autocorrelation)
    delete(config.padded_samples)
}



// Detect pitch via auto-correlation
ac_pitch_detect :: proc (using config: ^AcConfig, samples: []f32) -> (f32, f32, f32) {

    // Generate the autocorrelation
    //   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
    //    then taking the inverse FFT will give us the cyclic auto-correlation.

    assert(len(samples) == fft_size/2)

    // pad samples with zeros to avoid cyclic convolution
    copy(padded_samples[:fft_size/2], samples)

    // FFT transform
    pffft.transform_ordered(
        pffft_setup,
        raw_data(padded_samples),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )

    // multiply FFT with conjugate
    for i in 0..<len(fft) {
        fft[i] = fft[i] * conj(fft[i])
    }

    // inverse FFT to produce auto-correlation
    pffft.transform_ordered(
        pffft_setup,
        raw_data(mem.slice_data_cast([]f32, fft)),
        raw_data(autocorrelation),
        nil,
        pffft.Direction.BACKWARD
    )


    // Find the first maximum peak lag
    lag := 0
    threshold := 0.3 * autocorrelation[0]
    estimated_freq := f32(0)

    i := 1

    // throw away the negative lags
    half_len := len(autocorrelation) / 2 + 1  // + 1 ?
    peak_index := 0

    // go down the slope until we reach the local minimum
    for i < half_len - 1 && autocorrelation[i+1] < autocorrelation[i] {
        i += 1
    }

    lag = i

    // we want to look up to n/2 and find the lag for the max peak
    for i < half_len - 1 {
        if autocorrelation[i+1] > autocorrelation[lag] {
            lag = i + 1
        }
        i += 1
    }

    // interpolate peak to get a more precise result
    peak_location: f32 = 0
    if lag > 0 {
        peak_location = parabolic(
            autocorrelation[lag-1],
            autocorrelation[lag],
            autocorrelation[lag+1]
        )
    }

    improved_lag := f32(lag) + peak_location

    // convert lag to frequency
    if improved_lag > 0.0 {
        estimated_freq = f32(samplerate) / improved_lag
    }

    normalized_val := autocorrelation[lag] / autocorrelation[0]
    return estimated_freq, f32(lag), normalized_val
}
