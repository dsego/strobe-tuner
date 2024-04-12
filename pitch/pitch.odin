package pitch
import "core:mem"
import "core:fmt"

import "../pffft"

// -------------------------------------------------------------------------------------------------
//  Pitch detection based on auto-correlation
// -------------------------------------------------------------------------------------------------

PitchConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    fft_conj_product: []complex64,
    autocorrelation: []f32,
    // padded_samples: []f32,
}

pitch_init :: proc (fft_size: int) -> (config: PitchConfig = {}) {
    config.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    config.fft = make([]complex64, fft_size)
    config.fft_conj_product = make([]complex64, fft_size)
    config.autocorrelation = make([]f32, fft_size)
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
pitch_detect :: proc (using config: PitchConfig, samples: []f32) -> f32 {

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

    lag := f32(0.0)
    min := 0
    max := 0

    i := 0
    for i < len(autocorrelation) - 1 {

        // go down the slope until we reach the local minimum
        for i < len(autocorrelation) - 1 {
            if autocorrelation[i+1] > autocorrelation[i] {
                break
            }
            i += 1
        }

        // go up the slope until we reach the local maximum
        for i < len(autocorrelation) - 1 {
            if autocorrelation[i+1] < autocorrelation[i] {
                break
            }
            i += 1
        }
        fmt.println("Found local max at", i)

        if autocorrelation[i] > 0.5 * autocorrelation[0] {
            lag = f32(i)
            fmt.println("Found peak lag", i)
            fmt.println("Estimated frequency Hz", 44100.0 / f32(i) )
            break
        }
    }


    return lag
}
