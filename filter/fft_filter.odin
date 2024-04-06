package filter

import "core:fmt"
import "core:mem"
import "core:math"

import "../pffft"
// freq response of our filter impulse -> FFT
// audio samples -> FFT
// multiply FFTs and do inverse transform


NarrowBandpassFilter :: struct {
    size: int,
    pffft_setup: rawptr,
    zero_padded_input: []f32,
    input_dft: []complex64,
    result_dft_ordered: []complex64,
    filter_dft: []complex64,
    result_dft: []complex64,
    result_idft: []f32,
}

filter_init :: proc(size: int, frequency: f32) -> (config: NarrowBandpassFilter = {}) {
    config.size = size
    config.pffft_setup = pffft.new_setup(size*2, pffft.Transform.REAL)
    config.zero_padded_input = make([]f32, size*2)
    config.input_dft = make([]complex64, size*2)
    config.result_dft_ordered = make([]complex64, size*2)
    config.filter_dft = make([]complex64, size*2)
    config.result_dft = make([]complex64, size*2)
    config.result_idft = make([]f32, size*2)

    // config.filter_dft fill gaussian
    //   44100/4096


    //  sinc function highpass conv. lowpass * blackmann window --> fft


    // Lowpass filter time domain coefficients: h (k) =  1/N  *  ( sin(πkK / N) / sin(πk / N) ),
    //  -fs/2  to fs/2 freq range
    // sinc sin(x) / x shape


    // Bandpass from lowpass by shifting the freq response to center about fc
    // -> multiply response coefficients by sinusoid fc

    // half band?

    for i in 0..<len(config.filter_dft) {
        config.filter_dft[i] = complex(0, 0)
    }


    // config.filter_dft[19] = complex(1, 0)
    // config.filter_dft[20] = complex(1, 0)
    // config.filter_dft[21] = complex(1, 0)
    // config.filter_dft[22] = complex(1, 0)
    // config.filter_dft[23] = complex(1, 0)

    return
}

filter_destroy :: proc(config: NarrowBandpassFilter) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.zero_padded_input)
    delete(config.input_dft)
    delete(config.result_dft_ordered)
    delete(config.filter_dft)
    delete(config.result_dft)
    delete(config.result_idft)
}

// gaussian :: proc(data: []f32, amp: f32, spread: f32) {
//     len := f32(len(data))
//     for d, i in data {
//         x := f32(i) - len/2.0
//         data[i] = amp * math.exp(-x * x / spread)
//     }
// }



filter_test_accumulate:: proc(config: NarrowBandpassFilter, input: []f32, output: []f32) {
    result_dft := mem.slice_data_cast([]f32, config.result_dft[:])
    result_idft := mem.slice_data_cast([]f32, config.result_idft[:])
    filter_dft := mem.slice_data_cast([]f32, config.filter_dft[:])
    input_dft := mem.slice_data_cast([]f32, config.input_dft[:])
    result_dft_ordered := mem.slice_data_cast([]f32, config.result_dft_ordered[:])

    mem.copy(
        raw_data(config.zero_padded_input[:]),
        raw_data(input[:]),
        config.size*2
    )

    pffft.transform(
        config.pffft_setup,
        raw_data(config.zero_padded_input[:]),
        raw_data(input_dft[:]),
        nil,
        pffft.Direction.FORWARD
    )

    // Both FFTs need to be scrambled for this method
    pffft.zconvolve_accumulate(
        config.pffft_setup,
        raw_data(input_dft[:]),
        raw_data(filter_dft[:]),
        raw_data(result_dft[:]),
        1.0
    )

    pffft.zreorder(
        config.pffft_setup,
        raw_data(filter_dft),
        raw_data(result_dft_ordered),
        pffft.Direction.FORWARD
    )

    pffft.transform_ordered(
        config.pffft_setup,
        raw_data(result_dft_ordered[:]),
        raw_data(result_idft[:]),
        nil,
        pffft.Direction.BACKWARD
    )

    // scale by 1/N
    for i in 0..<len(output) {
        output[i] = config.result_idft[i] / f32(config.size)
    }
}


// Test FFT processing: convert to FFT, multiply FFT by allpass filter in freq domain
//  and convert back to the time domain.
filter_test_zreorder:: proc(config: NarrowBandpassFilter, input: []f32, output: []f32) {
    result_dft := mem.slice_data_cast([]f32, config.result_dft[:])
    result_idft := mem.slice_data_cast([]f32, config.result_idft[:])
    filter_dft := mem.slice_data_cast([]f32, config.filter_dft[:])
    input_dft := mem.slice_data_cast([]f32, config.input_dft[:])
    result_dft_ordered := mem.slice_data_cast([]f32, config.result_dft_ordered[:])

    mem.copy(
        raw_data(config.zero_padded_input[:]),
        raw_data(input[:]),
        config.size*2
    )

    pffft.transform(
        config.pffft_setup,
        raw_data(config.zero_padded_input[:]),
        raw_data(input_dft[:]),
        nil,
        pffft.Direction.FORWARD
    )

    pffft.zreorder(
        config.pffft_setup,
        raw_data(input_dft),
        raw_data(result_dft_ordered),
        pffft.Direction.FORWARD
    )

    pffft.transform_ordered(
        config.pffft_setup,
        raw_data(result_dft_ordered[:]),
        raw_data(result_idft[:]),
        nil,
        pffft.Direction.BACKWARD
    )

    // scale by 1/N
    for i in 0..<len(output) {
        output[i] = config.result_idft[i] / f32(config.size)
    }
}


// Test overlap FFT processing without applying a filter  (input -> FFT -> IFFT -> output).
// The resulting output should be identical to input.
filter_test_convert:: proc(config: NarrowBandpassFilter, input: []f32, output: []f32) {
    result_dft := mem.slice_data_cast([]f32, config.result_dft[:])
    result_idft := mem.slice_data_cast([]f32, config.result_idft[:])
    filter_dft := mem.slice_data_cast([]f32, config.filter_dft[:])
    input_dft := mem.slice_data_cast([]f32, config.input_dft[:])

    mem.copy(
        raw_data(config.zero_padded_input[:]),
        raw_data(input[:]),
        config.size*2
    )

    pffft.transform_ordered(
        config.pffft_setup,
        raw_data(config.zero_padded_input[:]),
        raw_data(input_dft[:]),
        nil,
        pffft.Direction.FORWARD
    )

    pffft.transform_ordered(
        config.pffft_setup,
        raw_data(input_dft[:]),
        raw_data(result_idft[:]),
        nil,
        pffft.Direction.BACKWARD
    )

    // scale by 1/N
    for i in 0..<len(output) {
        output[i] = config.result_idft[i] / f32(config.size)
    }
}
