package recursive_dft

import "core:fmt"
import "core:math"
import "core:math/cmplx"


DFT_SIZE :: 9600
HOP_SIZE :: 50
SAMPLERATE :: 48000.0
TARGET_FREQ :: 440.0


main :: proc() {

    // ------ Generate sine wave: 440Hz ------------------------------------------------------------

    samples: [DFT_SIZE + HOP_SIZE]f32 = {}


    for i in 0 ..< DFT_SIZE + HOP_SIZE {
        samples[i] = math.sin(math.TAU * f32(TARGET_FREQ) * f32(i) / f32(SAMPLERATE))
    }


    // ------ Initial DFT --------------------------------------------------------------------------

    norm_freq := TARGET_FREQ / f32(SAMPLERATE)
    w := math.TAU * norm_freq


    dft: complex64 = complex(0, 0)

    for i in 0 ..< DFT_SIZE {
        rotation := w * f32(i)
        twiddle := complex(math.cos(rotation), -math.sin(rotation))
        dft += complex(samples[i], 0) * twiddle
    }


    // ------ Recursive (sliding) DFT --------------------------------------------------------------


    delta: complex64 = complex(0, 0)


    for i in 0 ..< HOP_SIZE {
        rotation := w * f32(i)
        twiddle := complex(math.cos(rotation), -math.sin(rotation))
        delta += complex(samples[i + DFT_SIZE] - samples[i], 0) * twiddle
    }

    w_h := w * f32(HOP_SIZE)
    twiddle_hop := complex(math.cos(w_h), math.sin(w_h))
    dft_recursive: complex64 = (dft + delta) * twiddle_hop


    // ------ Recompute for validation -------------------------------------------------------------

    dft_recomputed: complex64 = complex(0, 0)

    for i in 0 ..< DFT_SIZE {
        rotation := w * f32(i)
        twiddle := complex(math.cos(rotation), -math.sin(rotation))
        dft_recomputed += complex(samples[i + HOP_SIZE], 0) * twiddle
    }

    // ------ Output -------------------------------------------------------------------------------


    fmt.printf("Initial DFT:       mag = {}, phase = {} rad \n", math.abs(dft), cmplx.phase(dft))
    fmt.printf(
        "Recursive DFT:     mag = {}, phase = {} rad \n",
        math.abs(dft_recursive),
        cmplx.phase(dft_recursive),
    )
    fmt.printf(
        "Recomputed:        mag = {}, phase = {} rad \n",
        math.abs(dft_recomputed),
        cmplx.phase(dft_recomputed),
    )


}
