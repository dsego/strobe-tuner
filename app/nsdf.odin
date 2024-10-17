/* -------------------------------------------------------------------------------------------------


    Pitch detection based on NSDF (McLeod Pitch Method)

    http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf



------------------------------------------------------------------------------------------------- */


package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"


Vec2 :: [2]f32

NSDFConfig :: struct {
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

nsdf_init :: proc (fft_size: int, samplerate: int) -> (config: NSDFConfig = {}) {
    config.fft_size = fft_size
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.autocorr = make([]f32, fft_size)
    config.nsdf = make([]f32, fft_size/2)
    config.samplerate = samplerate
    config.padded_samples = make([]f32, fft_size)
    return
}

nsdf_destroy :: proc (config: ^NSDFConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.autocorr)
    delete(config.nsdf)
    delete(config.padded_samples)
    delete(config.autocorr_peaks)
    delete(config.nsdf_peaks)
}

nsdf_pitch_detect :: proc (using config: ^NSDFConfig, samples: []f32) -> (f32, Vec2) {

    nsdf_process_samples(config, samples)
    nsdf_run_nsdf(config, samples)

    peak := nsdf_find_nsdf_peak(config)

    estimated_freq:f32 = 0.0

    if peak.x > 0.0 {
        estimated_freq =  f32(samplerate) / peak.x
    }

    return estimated_freq, peak
}

// Generate the auto-correlation
//   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
//    then taking the inverse FFT will give us the cyclic auto-correlation.
@(private)
nsdf_process_samples :: proc (using config: ^NSDFConfig, samples: []f32) {
    assert(len(samples) <= fft_size/2)

    // pad samples with zeros to avoid cyclic convolution
    mem.zero_slice(padded_samples)
    mem.zero_slice(autocorr)
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
    // - conjugation in the frequency domain is equivalent to reversal in the time domain
    // (the difference between cross-correlation and convolution is a time reversal on one of the inputs)
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

    // scale by 1/N
    for i in 0..<len(autocorr) {
        autocorr[i] = autocorr[i] / f32(fft_size)
    }
}


@(private)
nsdf_find_nsdf_peak :: proc (using config: ^NSDFConfig) -> Vec2 {
    // clear out peaks from the previous run
    clear(&nsdf_peaks)

    // TODO
    n := len(nsdf) - 256

    MIN_PEAK_VALUE := 0.5 * nsdf[0]

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
            peak := Vec2{improved_lag, magnitude}
            append(&nsdf_peaks, peak)

            if magnitude >= max_peak.y {
                max_peak = peak
            }
        }


        i += 1
    }

    THRESHOLD: f32 = 0.95
    chosen_peak: Vec2 = {}
    chosen_peak_idx = -1

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
@(private)
nsdf_run_nsdf :: proc (using config: ^NSDFConfig, samples: []f32) {
    n := len(samples)
    copy(nsdf, autocorr[:n])

    // left-hand summation for zero lag
    lhsum := 2.0 * nsdf[0]

    for i in 0..<n {
        if lhsum > 0.0 {
            nsdf[i] *= 2.0 / lhsum
            lhsum -= samples[i] * samples[i] + samples[n-i-1] * samples[n-i-1]
        } else {
            nsdf[i] = 0.0
        }
    }
}
