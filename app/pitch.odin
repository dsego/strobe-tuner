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
    win_fft: []complex64, // windowed fft
    spectrum: []f32,
    cepstrum: []f32,
    hps: []f32, // harmonic product spectrum
    fft_conj_product: []complex64,
    autocorrelation: []f32,
    samplerate: int,
    windowed_samples: []f32,
    padded_samples: []f32,
}

pitch_init :: proc (fft_size: int, samplerate: int) -> (config: PitchConfig = {}) {
    config.fft_size = fft_size
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.win_fft = make([]complex64, fft_size)
    config.spectrum = make([]f32, fft_size)
    config.cepstrum = make([]f32, fft_size)
    config.hps = make([]f32, fft_size)
    config.fft_conj_product = make([]complex64, fft_size)
    config.autocorrelation = make([]f32, fft_size)
    config.samplerate = samplerate
    config.windowed_samples = make([]f32, fft_size)
    config.padded_samples = make([]f32, fft_size)
    return
}

pitch_destroy :: proc (config: PitchConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.win_fft)
    delete(config.fft_conj_product)
    delete(config.autocorrelation)
    delete(config.windowed_samples)
    delete(config.spectrum)
    delete(config.cepstrum)
    delete(config.hps)
    delete(config.padded_samples)
}


magnitude :: proc (fft_val: complex64) -> f32 {
    return math.sqrt(real(fft_val) * real(fft_val) + imag(fft_val) * imag(fft_val))
}




pitch_detect_spectrum :: proc(using config: PitchConfig, samples: []f32) -> f32 {

    for i in 0..<fft_size {
        windowed_samples[i] = samples[i] * blackman_harris(f32(i), f32(fft_size))
    }

    pffft.transform_ordered(
        pffft_setup,
        raw_data(windowed_samples),
        raw_data(mem.slice_data_cast([]f32, win_fft)),
        nil,
        pffft.Direction.FORWARD
    )

    // calculate the spectrum
    for i in 0..<len(fft) {
        spectrum[i] = magnitude(win_fft[i])
        // spectrum[i] = math.ln(magnitude(win_fft[i]))
    }



    bin := 0
    max_magnitude := f32(0.0)

    // Keep only the positive frequencies (DC to Nyquist), ignore first 2 bins
    for i in 2..<fft_size/2 {
        magnitude := spectrum[i]
        if magnitude > max_magnitude {
            max_magnitude = magnitude
            bin = i
        }
    }

    // Parabolic interpolation
    peak_location: f32 = 0
    if bin > 0 {
        peak_location = parabolic(
            math.ln(spectrum[bin-1]),
            math.ln(spectrum[bin]),
            math.ln(spectrum[bin+1]),
        )
    }


    improved_bin := f32(bin) + peak_location

    freq := improved_bin * f32(samplerate) / f32(fft_size)

    // fmt.println("HERE", bin, improved_bin, freq)
    // fmt.println("------")
    // fmt.println(
    //     spectrum[bin-1],
    //     spectrum[bin],
    //     spectrum[bin+1],
    // )
    // fmt.println("------")

    return freq
}



// TODO: not working, constantly getting lots of peaks in lower frequencies
pitch_detect_hps :: proc(using config: PitchConfig) -> f32 {


    // perform Harmonic Product Spectrum
    copy(hps, spectrum)
    // size := fft_size / 2

    max_harmonics :: 4

    for downsample_factor in 1..=max_harmonics {
        for i in 0..< fft_size / downsample_factor {
            hps[i] *= spectrum[i * downsample_factor]
        }
    }

    // normalize ?
    // for i in 0..<FFT_SIZE {
        // spectrum[i] *= 2.0 / f32(FFT_SIZE)
        // hps[i] *=  0.00001
    // }

    bin := 0
    max_magnitude := f32(0.0)

    // ignore first 3 bins (arbitrary)
    first_bin := 3

    // Keep only the positive frequencies (DC to Nyquist)
    for i in first_bin..<fft_size/2 {
        magnitude := hps[i]
        if magnitude > max_magnitude {
            max_magnitude = magnitude
            bin = i
        }
    }

    // Parabolic interpolation
    peak_location: f32 = 0
    if bin > 0 {
        peak_location = parabolic(
            hps[bin-1],
            hps[bin],
            hps[bin+1],
        )
    }

    improved_bin := f32(bin) + peak_location

    freq := improved_bin * f32(samplerate) / f32(fft_size)
    return freq
}


// Parabolic interpolation to find the more accurate peak location
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic :: proc (alpha: f32, beta: f32, gamma: f32) -> f32 {
    return 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma)
}


// TODO: compare padded vs unpadded fft
// Detect pitch via auto-correlation
pitch_detect_ac :: proc (using config: PitchConfig, samples: []f32) -> (f32, f32, f32) {

    // Generate the autocorrelation
    //   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
    //    then taking the inverse FFT will give us the cyclic auto-correlation.

    copy(padded_samples, samples[:fft_size/2])

    pffft.transform_ordered(
        pffft_setup,
        raw_data(padded_samples),
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

    // throw away the negative lags
    len := len(autocorrelation) / 2 + 1  // + 1 ?
    peak_index := 0


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


    peak_location: f32 = 0
    if lag > 0 {
        peak_location = parabolic(
            autocorrelation[lag-1],
            autocorrelation[lag],
            autocorrelation[lag+1]
        )
    }

    improved_lag := f32(lag) + peak_location


    if improved_lag > 0.0 {
        estimated_freq = f32(samplerate) / improved_lag
    }
    // fmt.println(lag, improved_lag, estimated_freq)

    // fmt.println("Interpolated peak location", improved_lag)
    // fmt.println("Estimated frequency improved Hz", estimated_freq, improved_lag)

    normalized_val := autocorrelation[lag] / autocorrelation[0]
    return estimated_freq, f32(lag), normalized_val
}


pitch_detect_cepstrum :: proc (using config: PitchConfig, samples: []f32) -> f32 {

    // computing the inverse Fourier transform (IFT) of the logarithm of the estimated signal spectrum.


    // 1. log(mag(spectrum))

    // 2. inverse FFT

    // 3. cepstrum

    // pffft.transform_ordered(
    //     pffft_setup,
    //     raw_data(padded_samples),
    //     raw_data(mem.slice_data_cast([]f32, fft)),
    //     nil,
    //     pffft.Direction.BACKWARD
    // )
    return 0.0
}



spectral_flatness :: proc (spectrum: []f32) -> f32 {
    flatness := geometric_mean(spectrum) / arithmetic_mean(spectrum)
    return flatness
}


arithmetic_mean :: proc (array: []f32) -> f32 {
    mean: f32 = 0.0

    for i in 0..<len(array) {
        mean += array[i] + math.F32_EPSILON // adding epsilon so it never goes to zero
    }

    mean /= f32(len(array))
    return mean
}


geometric_mean :: proc (array: []f32) -> f32 {
    geometric_mean: f32 = 0.0

    for i in 0..<len(array) {
        // note, adding a small value to avoid zeros, because ln(0) = -inf
        //  also adding noise floor produces more sensible values
        geometric_mean += math.ln(array[i] + math.F32_EPSILON)
    }
    geometric_mean /= f32(len(array))
    geometric_mean = math.exp(geometric_mean)

    return geometric_mean
}



// flux = sum([max(spectrum[n] - last_spectrum[n], 0)
//             for n in xrange(self._window_size)])


// Symmetric Blackmann-Harris
// https://en.wikipedia.org/wiki/Window_function
// https://github.com/JvanKatwijk/filter-demo/blob/master/blackman-harris.cpp#L18-L24
blackman_harris :: proc (i: f32, num: f32) -> f32 {
    a0 :: 0.35875
    a1 :: 0.48829
    a2 :: 0.14128
    a3 :: 0.01168

    seg1 := a1 * math.cos(2.0 * math.PI * i / (num - 1.0))
    seg2 := a2 * math.cos(4.0 * math.PI * i / (num - 1.0))
    seg3 := a3 * math.cos(6.0 * math.PI * i / (num - 1.0))
    res := a0 - seg1 + seg2 - seg3

    return res
}

freq_in_range :: proc (freq: f32) -> bool {
    return freq > MIN_FREQ && freq < MAX_FREQ
}
