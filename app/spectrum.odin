package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"


SpectrumConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    spectrum: []f32, // magnitude spectrum
    hps: []f32, // harmonic product spectrum
    samplerate: int,
    windowed_samples: []f32,
}

spectrum_init :: proc (fft_size: int, samplerate: int) -> (config: SpectrumConfig = {}) {
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft_size = fft_size
    config.fft = make([]complex64, fft_size)
    config.spectrum = make([]f32, fft_size)
    config.samplerate = samplerate
    config.windowed_samples = make([]f32, fft_size)
    return
}

spectrum_destroy :: proc (config: ^SpectrumConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.fft)
    delete(config.windowed_samples)
    delete(config.spectrum)
}

spectrum_pitch_detect :: proc(using config: ^SpectrumConfig, samples: []f32) -> f32 {
    sample_len := len(samples)
    assert(sample_len == fft_size/2)

    // pad with zeros and apply windowing
    for i in 0..<sample_len {
        windowed_samples[i] = samples[i] * blackman_harris(f32(i), f32(sample_len))
    }

    pffft.transform_ordered(
        pffft_setup,
        raw_data(windowed_samples),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )

    // calculate the spectrum
    for i in 0..<len(fft) {
        spectrum[i] = magnitude(fft[i])
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

    // Parabolic interpolation to determine a more accurate pitch
    peak_location: f32 = 0
    if bin > 0 {
        peak_location, _ = parabolic(
            math.ln(spectrum[bin-1]),
            math.ln(spectrum[bin]),
            math.ln(spectrum[bin+1]),
        )
    }

    improved_bin := f32(bin) + peak_location
    freq := improved_bin * f32(samplerate) / f32(fft_size)

    return freq
}


spectral_flatness :: proc (spectrum: []f32) -> f32 {
    flatness := geometric_mean(spectrum) / arithmetic_mean(spectrum)
    return flatness
}
