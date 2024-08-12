package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"


CepsConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    spectrum: []f32, // log spectrum
    cepstrum: []f32,
    samplerate: int,
    windowed_samples: []f32,
}

ceps_init :: proc (fft_size: int, samplerate: int) -> (config: CepsConfig = {}) {
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft_size = fft_size
    config.fft = make([]complex64, fft_size)
    config.spectrum = make([]f32, fft_size)
    config.cepstrum = make([]f32, fft_size)
    config.samplerate = samplerate
    config.windowed_samples = make([]f32, fft_size)
    return
}

ceps_destroy :: proc (config: CepsConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.windowed_samples)
    delete(config.spectrum)
    delete(config.cepstrum)
}

// computing the inverse Fourier transform (IFT) of the logarithm of the estimated signal spectrum.
ceps_pitch_detect :: proc(using config: CepsConfig, samples: []f32) -> f32 {
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
        mag := magnitude(fft[i])
        spectrum[i] = math.ln(mag * mag)
    }

    // 2. inverse FFT
    pffft.transform_ordered(
        pffft_setup,
        raw_data(spectrum),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )

    // 3. cepstrum
    for i in 0..<len(fft) {
        mag := magnitude(fft[i])
        cepstrum[i] = mag * mag
    }

    // TODO: find peak

    return 0.0
}


