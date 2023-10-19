package filter

import "core:mem"
import "core:math"

import "../pffft"
// freq response of our filter impulse -> FFT
// audio samples -> FFT
// multiply FFTs and do inverse transform


NarrowBandpassFilter :: struct {
    size: int,
    pffft_setup: rawptr,
    zero_padded: []f32,
    zero_padded_dft: []complex64,
    filter_dft: []complex64,
    result_dft: []complex64,
}

filter_init :: proc(size: int, frequency: f32) -> (config: NarrowBandpassFilter = {}) {
    config.size = size*2
    config.pffft_setup = pffft.new_setup(size*2, pffft.Transform.REAL)
    config.zero_padded = make([]f32, size*2)
    config.zero_padded_dft = make([]complex64, size*2)
    config.filter_dft = make([]complex64, size*2)
    config.result_dft = make([]complex64, size*2)

    // config.filter_dft fill gaussian
    //   44100/4096


    //  sinc function highpass conv. lowpass * blackmann window --> fft

    config.filter_dft[19] = complex(1, 0)
    config.filter_dft[20] = complex(1, 0)
    config.filter_dft[21] = complex(1, 0)
    config.filter_dft[22] = complex(1, 0)
    // config.filter_dft[23] = complex(1, 0)

    return
}

filter_destroy :: proc(config: NarrowBandpassFilter) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.zero_padded)
    delete(config.filter_dft)
    delete(config.result_dft)
}

gaussian :: proc(data: []f32, amp: f32, spread: f32) {
    len := f32(len(data))
    for d, i in data {
        x := f32(i) - len/2.0
        data[i] = amp * math.exp(-x * x / spread)
    }
}




filter_process:: proc(config: NarrowBandpassFilter, input: []f32, output: []f32) {

    result_dft := mem.slice_data_cast([]f32, config.result_dft[:])
    filter_dft := mem.slice_data_cast([]f32, config.filter_dft[:])
    zero_padded_dft := mem.slice_data_cast([]f32, config.zero_padded_dft[:])

    mem.copy(
        raw_data(config.zero_padded[:]),
        raw_data(input[:]),
        config.size
    )

    pffft.transform_ordered(
        config.pffft_setup,
        raw_data(config.zero_padded[:]),
        raw_data(zero_padded_dft[:]),
        nil,
        pffft.Direction.FORWARD
    )

    for _, i in config.zero_padded_dft {
        config.result_dft[i] = config.zero_padded_dft[i] * config.filter_dft[i]
    }


    // NOTE Both DFTs need to be scrambled for this method
    // pffft.zconvolve_accumulate(
    //     config.pffft_setup,
    //     raw_data(zero_padded_dft[:]),
    //     raw_data(filter_dft[:]),
    //     raw_data(result_dft[:]),
    //     1.0
    // )

    pffft.transform_ordered(
        config.pffft_setup,
        raw_data(result_dft[:]),
        raw_data(output[:]),
        nil,
        pffft.Direction.BACKWARD
    )
}


