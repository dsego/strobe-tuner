package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"

CepsConfig :: struct {
    pffft_setup: rawptr,
    pffft_ceps_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    log_spectrum: []f32,
    cepstrum: []f32,
    samplerate: int,
    windowed_samples: []f32,
}

ceps_init :: proc (fft_size: int, samplerate: int) -> (config: CepsConfig = {}) {
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.pffft_ceps_setup = pffft.new_setup(fft_size/2, pffft.Transform.REAL)
    config.fft_size = fft_size
    config.fft = make([]complex64, fft_size)
    config.log_spectrum = make([]f32, fft_size)
    config.cepstrum = make([]f32, fft_size)
    config.samplerate = samplerate
    config.windowed_samples = make([]f32, fft_size)
    return
}

ceps_destroy :: proc (config: ^CepsConfig) {
    pffft.destroy_setup(config.pffft_setup)
    pffft.destroy_setup(config.pffft_ceps_setup)
    delete(config.fft)
    delete(config.windowed_samples)
    delete(config.log_spectrum)
    delete(config.cepstrum)
}

// TODO: make it work
// computing the inverse Fourier transform (IFT) of the logarithm of the estimated signal spectrum.
ceps_pitch_detect :: proc(using config: ^CepsConfig, samples: []f32) -> (f32, f32, f32) {
    assert(len(samples) == fft_size/2)

    // pad with zeros and apply windowing
    for i in 0..<fft_size/2 {
        windowed_samples[i] = samples[i] * blackman_harris(f32(i), f32(fft_size))
    }

    pffft.transform_ordered(
        pffft_setup,
        raw_data(windowed_samples),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )

    // 1. log(mag(spectrum))
    for i in 0..<len(fft) {
        mag := max(square(fft[i]), math.F32_EPSILON)
        log_spectrum[i] = math.ln(mag)
    }

    // 2. inverse FFT
    // Note: IFFT(log(abs(FFT(s)))) == real(FFT(log(abs(FFT(s)))))
    pffft.transform_ordered(
        pffft_ceps_setup,
        raw_data(mem.slice_data_cast([]f32, log_spectrum)),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )


    // 3. cepstrum
    for i in 0..<len(fft) {
        cepstrum[i] = real(fft[i]) * 0.01
    }



    // Find the first maximum peak lag
    lag := 0
    threshold := 0.3 * cepstrum[0]
    estimated_freq := f32(0)

    i := 1


    // throw away the negative lags
    half_len := len(cepstrum) / 2 + 1  // + 1 ?
    peak_index := 0

    // go down the slope until we reach the local minimum
    for i < half_len - 1 && cepstrum[i+1] < cepstrum[i] {
        i += 1
    }

    lag = i

    // we want to look up to n/2 and find the lag for the max peak
    for i < half_len - 1 {
        if cepstrum[i+1] > cepstrum[lag] {
            lag = i + 1
        }
        i += 1
    }

    // interpolate peak to get a more precise result
    peak_location: f32 = 0
    if lag > 0 {
        peak_location, _ = parabolic(
            cepstrum[lag-1],
            cepstrum[lag],
            cepstrum[lag+1]
        )
    }

    improved_lag := f32(lag) + peak_location

    // convert lag to frequency
    if improved_lag > 0.0 {
        estimated_freq = f32(samplerate) / improved_lag / 2.0
    }

    return estimated_freq, f32(improved_lag), cepstrum[lag]
}


