// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package benchmark

import "core:time"
import "core:fmt"
import "core:math/rand"

import ".."
import "../../pffft"

SIZE :: 8192
ITERATIONS :: 1000


// Results on Apple M1 Pro 2021 with -o:speed
//  Pffft: 7.300834 µs
//  Single bin DFT: 0.00091699999999999995 µs

// Without -o:speed
//  Pffft: 13.055584000000001 µs
//  Single bin DFT: 101.444042 µs

main :: proc() {


    // Run optimized FFT transforms
    {
        out : [SIZE*2]f32
        samples: [SIZE]f32
        for i in 0..<SIZE do samples[i] = rand.float32_range(-1.0, 1.0)

        stopwatch := time.Stopwatch{}

        setup := pffft.new_setup(SIZE, pffft.Transform.REAL)
        defer pffft.destroy_setup(setup)

        time.stopwatch_start(&stopwatch)
        for i in 0..<ITERATIONS {
            pffft.transform_ordered(setup, raw_data(samples[:]),raw_data(out[:]), nil, pffft.Direction.FORWARD)
        }
        time.stopwatch_stop(&stopwatch)

        duration := time.stopwatch_duration(stopwatch)
        µs := time.duration_microseconds(duration)
        fmt.printf("Pffft: {} µs\n", µs / f64(ITERATIONS))
    }

    // Run single bin DFT
    {
        dft := core.init_dft(SIZE)
        samples: [SIZE]f32
        core.set_dft_freq(&dft, 110.0/48_000.0)

        for i in 0..<SIZE do samples[i] = f32(1)

        stopwatch := time.Stopwatch{}

        time.stopwatch_start(&stopwatch)
        for i in 0..<ITERATIONS {
            core.run_single_dft(&dft, samples[:])
        }
        time.stopwatch_stop(&stopwatch)

        duration := time.stopwatch_duration(stopwatch)
        µs := time.duration_microseconds(duration)
        fmt.printf("Single bin DFT: {} µs\n", µs / f64(ITERATIONS))
    }
}
