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
    autocorr: []f32,
    samplerate: int,
    padded_samples: []f32,
    peaks: [dynamic]int,
}

ac_init :: proc (fft_size: int, samplerate: int) -> (config: AcConfig = {}) {
    config.fft_size = fft_size
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.autocorr = make([]f32, fft_size)
    config.samplerate = samplerate
    config.padded_samples = make([]f32, fft_size)
    return
}

ac_destroy :: proc (config: ^AcConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.autocorr)
    delete(config.padded_samples)
    delete(config.peaks)
}



// Detect pitch via auto-correlation
ac_pitch_detect :: proc (using config: ^AcConfig, samples: []f32) -> (f32, f32) {
    // Generate the autocorr
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
        raw_data(autocorr),
        nil,
        pffft.Direction.BACKWARD
    )

    // Find the first maximum peak lag
    lag := 0
    peak_idx := 0
    i := 1

    // throw away the negative lags
    n := len(autocorr) / 2

    // clear out peaks from the previous run
    clear(&peaks)

    for i < n {
        // go down the slope until we reach the local minimum
        for i < n && autocorr[i+1] < autocorr[i] do i += 1

        // no slope, we're on flat grounds
        if i == 1 do break

        // the min is our starting point
        lag = i

        // search for the max peak across the whole buffer
        for i < n {
            if autocorr[i+1] > autocorr[lag] do lag = i + 1
            i += 1
        }

        // we didn't find a max
        if i == lag do break

        append(&peaks, lag)

        // continue search for other max peaks from this lag
        i = lag + 1
    }

    estimated_freq:f32 = 0.0
    normalized_val:f32 = 0.0

    if len(peaks) > 1 {
        p1 := f32(peaks[0]) + parabolic(
            autocorr[peaks[0]-1],
            autocorr[peaks[0]],
            autocorr[peaks[0]+1]
        )

        p2 := f32(peaks[1]) + parabolic(
            autocorr[peaks[1]-1],
            autocorr[peaks[1]],
            autocorr[peaks[1]+1]
        )
        distance := p2 - p1

        if distance > 0.0 {
            estimated_freq = f32(samplerate) / distance
        }


        // The normalized value can provide a confidence level
        chosen_lag := peaks[0]
        normalized_val = autocorr[chosen_lag] / autocorr[0]
    }

    return estimated_freq, normalized_val
}
