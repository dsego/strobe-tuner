package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"

// -------------------------------------------------------------------------------------------------
//  Pitch detection based on auto correlation
// ------------------------------------------------------------------------------------------------

Vec2 :: [2]f32

AcConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    autocorr: []f32,
    nsdf: []f32,
    samplerate: int,
    padded_samples: []f32,
    autocorr_peaks: [dynamic]int,
    nsdf_peaks: [dynamic]Vec2,
    chosen_peak_idx: int,
}

ac_init :: proc (fft_size: int, samplerate: int) -> (config: AcConfig = {}) {
    config.fft_size = fft_size
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.autocorr = make([]f32, fft_size)
    config.nsdf = make([]f32, fft_size)
    config.samplerate = samplerate
    config.padded_samples = make([]f32, fft_size)
    return
}

ac_destroy :: proc (config: ^AcConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.autocorr)
    delete(config.nsdf)
    delete(config.padded_samples)
    delete(config.autocorr_peaks)
    delete(config.nsdf_peaks)
}



// Detect pitch via auto-correlation
ac_pitch_detect :: proc (using config: ^AcConfig, samples: []f32) -> (f32, Vec2) {
    ac_process_samples(config, samples)

    // ac_find_autocorr_peaks(config)

    ac_nsdf(config, samples)
    peak, ok := ac_find_nsdf_peak(config).?

    estimated_freq: f32 = 0.0
    normalized_val: f32 = 0.0

    if ok {
        estimated_freq =  f32(samplerate) / peak.x
    }

    return estimated_freq, peak
}

// Generate the auto-correlation
//   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
//    then taking the inverse FFT will give us the cyclic auto-correlation.
ac_process_samples :: proc (using config: ^AcConfig, samples: []f32) {
    assert(len(samples) <= fft_size/2)

    // pad samples with zeros to avoid cyclic convolution
    mem.zero_slice(padded_samples)
    copy(padded_samples, samples)

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
}


ac_find_autocorr_peaks :: proc (using config: ^AcConfig) {
    lag := 0
    peak_idx := 0
    i := 1

    // throw away the negative lags
    n := len(autocorr) / 2

    // clear out peaks from the previous run
    clear(&autocorr_peaks)

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

        append(&autocorr_peaks, lag)

        // continue search for other max peaks from this lag
        i = lag + 1
    }
}


ac_find_nsdf_peak :: proc (using config: ^AcConfig) -> Maybe(Vec2)  {
    // clear out peaks from the previous run
    clear(&nsdf_peaks)

    found := false

    MIN_PEAK_VALUE := 0.5 * nsdf[0]

    // throw away the negative lags and ignore the right most area that's glitching
    n := len(nsdf) / 2 - len(nsdf) / 16

    max_peak := Vec2{0.0, 0.0}

    // enumerate all the candidate peaks
    i := 1
    for i < n {

        // go down the first slope
        for i < n && nsdf[i] > 0.0 do i += 1

        // skip all negative values
        for i < n && nsdf[i] <= 0.0 do i += 1

        lag := i
        min := lag

        // search for a local max peak in the positive area
        for i < n - 1 && nsdf[i] > 0.0 {
            if nsdf[i] > nsdf[lag] && nsdf[i] > nsdf[i+1] && nsdf[i] > MIN_PEAK_VALUE {
                lag = i
            }
            i += 1
        }

        if lag > min {
            peak_location, magnitude := parabolic(
                nsdf[lag-1],
                nsdf[lag],
                nsdf[lag+1]
            )
            improved_lag := f32(lag) + peak_location
            append(&nsdf_peaks, Vec2{improved_lag, magnitude})

            if magnitude >= max_peak.y {
                max_peak = Vec2{improved_lag, magnitude}
            }
        }


        i += 1
    }

    THRESHOLD: f32 = 0.8
    chosen_peak: Maybe(Vec2) = nil

    // take the first key maximum above this threshold
    for p, idx in nsdf_peaks {
        if p.y >= THRESHOLD * max_peak.y {
            chosen_peak = p
            chosen_peak_idx = idx
            break
        }
    }

    return chosen_peak
}

// Normalized Square Difference Function (through autocorrelation)
// http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf
ac_nsdf :: proc (using config: ^AcConfig, samples: []f32) {
    n := len(samples)
    copy(nsdf, autocorr[:n])

    // left-hand summation for zero lag
    lhsum := 2.0 * nsdf[0] / f32(len(nsdf))

    for i in 0..<n {
        if lhsum > 0.0 {
            nsdf[i] *= 2.0 / lhsum
        } else {
            nsdf[i] = 0.0
        }
        lhsum -= samples[i] * samples[i] + samples[n-i-1] * samples[n-i-1]
    }
}
