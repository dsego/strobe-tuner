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

    assert(len(samples) <= fft_size/2)

    // pad samples with zeros to avoid cyclic convolution
    mem.zero_slice(padded_samples)
    copy(padded_samples, samples)

    // windowing ?
    // for i in 0..<fft_size/2 {
    //     padded_samples[i] = padded_samples[i] * blackman_harris(f32(i), f32(fft_size/2))
    // }

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
    i := 1

    // TODO: don't look for notes lower than 20Hz = lag 50ms
    // TODO: enumerate all discrete peaks -> run parabolic interpolation on first 2-3 to find the true max peak
    // TODO: can we be smarter about traversing lags, maybe skip ahead X samples at a time instead of checking each sample

    // throw away the negative lags
    half_len := len(autocorrelation) / 2 + 1  // + 1 ?

    // go down the slope until we reach the local minimum
    for i < half_len - 1 && autocorrelation[i+1] < autocorrelation[i] {
        i += 1
    }

    // fmt.println("MIN", autocorrelation[i])

    lag = i

    // we want to look up to n/2 and find the lag for the max peak
    for i < half_len - 1 {
        if autocorrelation[i+1] > autocorrelation[lag] {
            lag = i + 1
        }
        i += 1
    }

    chosen_lag := lag
    // fmt.println("MAX", autocorrelation[i])

    // interpolate peak to get a more precise result
    peak_location: f32 = 0

    if chosen_lag > 0 {
        peak_location = parabolic(
            autocorrelation[chosen_lag-1],
            autocorrelation[chosen_lag],
            autocorrelation[chosen_lag+1]
        )
    }

    improved_lag := f32(chosen_lag) + peak_location
    // improved_lag := f32(chosen_lag)

    // convert lag to frequency
    estimated_freq := f32(0)
    if improved_lag > 0.0 {
        estimated_freq = f32(samplerate) / improved_lag
    }
    // fmt.println(chosen_lag, improved_lag)

    // The normalized value can provide a confidence level
    normalized_val := autocorrelation[chosen_lag] / autocorrelation[0]
    if math.is_nan(normalized_val) {
        normalized_val = 0.0
    }

    return estimated_freq, f32(improved_lag), normalized_val
}
