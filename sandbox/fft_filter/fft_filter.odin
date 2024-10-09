/*

  Overlap-add filtering technique based on Understanding DSP by R.G. Lyons (big green book):

    - Input sequence segmented into data blocks of length M.
    - FIR filter's impulse response is Q.
    - Input sequence is of length P.

    1. Choose an FFT size of N where N ~= 2Q

    2. Append N - Q zero-valued samples to the end of the impulse response and perform
       an N-point FFT producing H(m).

    3. Compute block size M = N - (Q - 1).

    4. Append (Q - 1) zero-valued samples to the end of the first M samples

    5. Perform an N-point FFT on the N-point FFT sequence, multiply the FFT result by the H(m) sequence
        and perform an inverse FFT on the product. Retain the first M samples, generating the first
        M-point output block.

    6. Append (Q - 1) zero-valued samples to the end of the second M samples, creating the second
        N-point FFT input.

    7. Perform an N-point FFT on the second input sequence, multiply by H(m) and perform an
        inverse FFT of the product.
       Add the last (Q - 1) samples from the previous inverse FFT to the first (Q - 1) samples
        of the current inverse FFT sequence. Retain the first M samples resulting from the
        (Q - 1)-element addition process, generating the second M-point output block.

    8. Repeat 6 & 7 until we have gone through the original filter input sequence.

    9. Concatenate the output blocks, discarding trailing zero-valued samples.

    10. Optimize N to minimize computation workload, N >= M + Q - 1


    TODO:

    Can we improve the performance by zero padding (upsampling) the response FFT?

*/


package filter

import "core:fmt"
import "core:mem"
import "core:math"

import "../../pffft"


FilterConfig :: struct {
    impulse_response_size: int,
    fft_size: int,
    block_size: int,
    pffft_setup: rawptr,
    padded_impulse_response: []f32,
    padded_impulse_response_fft: []complex64,
    padded_impulse_response_fft_ordered: []complex64,
    padded_input: []f32,
    padded_input_fft: []complex64,
    fft_product: []complex64,
    fft_product_ordered: []complex64,
    ifft_result: []f32,
    overlap: []f32,
}

filter_init :: proc(
    impulse_response_size: int,
) -> (config: FilterConfig = {}) {
    // Taps needed:
    //      N-taps =  attenuation / 22 * (f-stop - f-pass)

    // FIR filter's impulse response is Q
    config.impulse_response_size = impulse_response_size

    // Choose an FFT size of N where N ~= 2Q
    config.fft_size = math.next_power_of_two(2 * impulse_response_size)

    // Compute M = N - (Q - 1)
    config.block_size = config.fft_size - impulse_response_size + 1

    // Append N - Q zero-valued samples to the end of the impulse response and perform
    // an N-point FFT producing H(m)
    config.padded_impulse_response = make([]f32, config.fft_size)
    config.padded_impulse_response_fft = make([]complex64, config.fft_size)
    config.padded_impulse_response_fft_ordered = make([]complex64, config.fft_size)
    config.padded_input_fft = make([]complex64, config.fft_size)
    config.fft_product = make([]complex64, config.fft_size)
    config.fft_product_ordered = make([]complex64, config.fft_size)
    config.ifft_result = make([]f32, config.fft_size)
    config.overlap = make([]f32, impulse_response_size - 1)
    config.padded_input = make([]f32, config.fft_size)

    config.pffft_setup = pffft.new_setup(config.fft_size, pffft.Transform.REAL)



    // Low-pass filter
    // h(K) = 1/N * (sin(πkK/N) / sin(πk/N))
    // K passband samples between -N/2 & N/2, N = samplerate, k = time

    // TODO:
    //      pass band - multiply by sine


    passband_freq :: 110.0
    SAMPLERATE :: 44100.0

    // Append N - Q zero-valued samples to the end of the impulse
    for i in 0..<impulse_response_size {

        pb_sin := math.sin(math.PI * f32(i) * passband_freq / SAMPLERATE)
        sin := math.sin(math.PI * f32(i) / SAMPLERATE)

        config.padded_impulse_response[i] =
            blackmann_window(f32(i), f32(impulse_response_size)) *
            pb_sin * (pb_sin / sin) / SAMPLERATE
    }
    config.padded_impulse_response[0] = passband_freq / SAMPLERATE


    // Perform an N-point FFT producing H(m).
    pffft.transform(
        config.pffft_setup,
        raw_data(config.padded_impulse_response),
        raw_data(mem.slice_data_cast([]f32, config.padded_impulse_response_fft)),
        nil,
        pffft.Direction.FORWARD
    )

    pffft.zreorder(
        config.pffft_setup,
        raw_data(mem.slice_data_cast([]f32, config.padded_impulse_response_fft)),
        raw_data(mem.slice_data_cast([]f32, config.padded_impulse_response_fft_ordered)),
        pffft.Direction.FORWARD
    )


    fmt.println("FILTER: Initializing filter")
    fmt.println("........FFT size: ", config.fft_size)
    fmt.println("........Block size", config.block_size)

    return config
}


filter_destroy :: proc(config: FilterConfig) {
    pffft.destroy_setup(config.pffft_setup)
    delete(config.padded_impulse_response)
    delete(config.padded_impulse_response_fft)
    delete(config.padded_input)
    delete(config.padded_input_fft)
    delete(config.fft_product)
    delete(config.fft_product_ordered)
    delete(config.ifft_result)
    delete(config.overlap)
}


filter_process :: proc(
    using config: FilterConfig,
    input: []f32,
    output: []f32,
) {
    // fmt.println(len(input), block_size)

    // Read inputs block by block
    for i := 0; i < len(input) - block_size; i += block_size
    {
        fmt.println("........Processing block", i, i+block_size)

        // Zero pad M samples
        copy(padded_input, input[i:i+block_size])

        // Need to zero out because zconvolve_accumulate reuses the old data
        for j in 0..<len(fft_product) {
            fft_product[j] = complex(0, 0)
        }

        raw_padded_input := raw_data(padded_input)
        raw_padded_input_fft := raw_data(mem.slice_data_cast([]f32, padded_input_fft))
        raw_padded_impulse_response_fft := raw_data(mem.slice_data_cast([]f32, padded_impulse_response_fft))
        raw_fft_product := raw_data(mem.slice_data_cast([]f32, fft_product))
        raw_fft_product_ordered := raw_data(mem.slice_data_cast([]f32, fft_product_ordered))
        raw_ifft_result := raw_data(ifft_result)

        // Perform an N-point FFT on the N-point FFT sequence
        pffft.transform(
            pffft_setup,
            raw_padded_input,
            raw_padded_input_fft,
            nil,
            pffft.Direction.FORWARD
        )

        // multiply the FFT result by the H(m) sequence
        pffft.zconvolve_accumulate(
            pffft_setup,
            raw_padded_input_fft,
            raw_padded_impulse_response_fft,
            raw_fft_product,
            1.0 / f32(fft_size)
        )

        // Perform an inverse FFT on the product
        pffft.zreorder(
            pffft_setup,
            raw_fft_product,
            raw_fft_product_ordered,
            pffft.Direction.FORWARD
        )

        pffft.transform_ordered(
            pffft_setup,
            raw_fft_product_ordered,
            raw_ifft_result,
            nil,
            pffft.Direction.BACKWARD
        )

        copy(output[i:], ifft_result[:block_size])

        // Add the last (Q - 1) samples from the previous inverse FFT to the first (Q - 1) samples
        // of the current inverse FFT sequence
        for j in 0..<(impulse_response_size - 1) {
            output[i+j] += overlap[j]
        }

        copy(overlap, ifft_result[block_size:])
    }
}

// TODO: is this correct?
// It produces only the right side lobe
blackmann_window :: proc (k: f32, size: f32) -> f32 {
    shift : f32 = math.PI
    l : f32 = shift + 2.0 * math.PI * k / (2.0 * size - 1.0)
    return 0.42 - 0.5 * math.cos(l) + 0.08 * math.cos(2.0 * l)
}
