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


package core

import "core:math"
import "core:testing"


// An input at 88.2 kHz or faster is halved until it's under it, 96 and 192 kHz to 48 kHz, 88.2 and 176.4 kHz
// to 44.1 kHz. Nothing up there is a note, the strobe's work grows with the rate.
DECIMATE_FROM_HZ :: 88_200
MAX_HALVINGS :: 3 // 384 kHz

// Dropping every other sample folds what's over the new Nyquist down into the audio, a converter's shaped
// noise above 20 kHz or an ultrasonic whine onto a track. A halfband lowpass before each drop keeps it out:
// flat to 0.2 of the rate, over 100 dB down from 0.3, which folds onto 0.2 and above. Every other tap but
// the middle one is 0, and the taps are symmetric.
HALFBAND_TAPS :: 67
HALFBAND_PAIRS :: (HALFBAND_TAPS + 1) / 4 // the nonzero taps on each side of the middle one
HALFBAND_KAISER_BETA :: 10

// The input's rate halved MAX_HALVINGS times at most, each stage with its own filter
Decimator :: struct {
    pairs:    [HALFBAND_PAIRS]f32, // the taps 1, 3, 5... from the middle one, which is 0.5
    stages:   [MAX_HALVINGS]HalfbandStage,
    halvings: int,
}

HalfbandStage :: struct {
    // The newest HALFBAND_TAPS inputs twice over, history[position:][:HALFBAND_TAPS] runs from the oldest
    // to the newest without wrapping
    history:  [2 * HALFBAND_TAPS]f32,
    position: int,
    odd:      bool, // the next input is dropped
}

// Halves input_rate until it's under DECIMATE_FROM_HZ, sample_rate is what comes out
init_decimator :: proc(input_rate: f32) -> (self: Decimator, sample_rate: f32) {
    sample_rate = input_rate
    for sample_rate >= DECIMATE_FROM_HZ && self.halvings < MAX_HALVINGS {
        sample_rate /= 2
        self.halvings += 1
    }

    // A windowed sinc at a quarter of the rate, its even taps fall on the sinc's zeros
    sum: f64 = 0.5
    for &tap, index in self.pairs {
        offset := f64(2 * index + 1)
        sinc := math.sin(math.PI * offset / 2) / (math.PI * offset)
        tap = f32(sinc * kaiser(offset, HALFBAND_TAPS / 2, HALFBAND_KAISER_BETA))
        sum += 2 * f64(tap)
    }

    // A level that stays the same at 0 Hz
    for &tap in self.pairs do tap = f32(f64(tap) / sum)
    return

    // The Kaiser window at offset from the middle of one reaching half_width either way
    kaiser :: proc(offset, half_width, beta: f64) -> f64 {
        ratio := offset / half_width
        return bessel_i0(beta * math.sqrt(1 - ratio * ratio)) / bessel_i0(beta)
    }

    // The modified Bessel function of the first kind of order 0, its series
    bessel_i0 :: proc(x: f64) -> f64 {
        sum, term: f64 = 1, 1
        for index in 1 ..< 50 {
            term *= (x / 2) / f64(index)
            sum += term * term
        }
        return sum
    }
}

// Decimates the samples in place, returns how many came out. From the audio thread, the filters run on from
// the previous call.
decimate :: proc(self: ^Decimator, samples: []f32) -> int {
    count := len(samples)
    for &stage in self.stages[:self.halvings] {
        out := 0
        for index in 0 ..< count {
            sample := samples[index]
            stage.history[stage.position] = sample
            stage.history[stage.position + HALFBAND_TAPS] = sample
            stage.position = (stage.position + 1) % HALFBAND_TAPS

            stage.odd = !stage.odd
            if !stage.odd do continue

            // The window's middle, the taps on either side of it in pairs. Written behind the input, out never
            // passes index.
            window := stage.history[stage.position:][:HALFBAND_TAPS]
            middle := HALFBAND_TAPS / 2
            value := 0.5 * window[middle]
            for tap, pair in self.pairs {
                offset := 2 * pair + 1
                value += tap * (window[middle - offset] + window[middle + offset])
            }
            samples[out] = value
            out += 1
        }
        count = out
    }
    return count
}


@(test)
test_decimate :: proc(t: ^testing.T) {
    // The level of a sine at freq_hz through the decimator at input_rate, after the filters settled
    level :: proc(input_rate, freq_hz: f64) -> f64 {
        decimator, _ := init_decimator(f32(input_rate))
        samples := make([]f32, int(input_rate / 2), context.temp_allocator)
        for &sample, index in samples do sample = f32(math.sin(math.TAU * freq_hz * f64(index) / input_rate))

        // In chunks like the audio thread's, an odd size so the drop moves across them
        out := 0
        for start := 0; start < len(samples); start += 333 {
            chunk := samples[start:min(start + 333, len(samples))]
            count := decimate(&decimator, chunk)
            copy(samples[out:], chunk[:count])
            out += count
        }
        peak: f64
        for sample in samples[out / 2:out] do peak = max(peak, abs(f64(sample)))
        return peak
    }

    for rates in ([][2]f32{{48_000, 48_000}, {96_000, 48_000}, {88_200, 44_100}, {192_000, 48_000}, {176_400, 44_100}, {384_000, 48_000}}) {
        _, sample_rate := init_decimator(rates[0])
        testing.expectf(t, sample_rate == rates[1], "%v Hz comes out at %v Hz", rates[0], sample_rate)
    }

    // The audio as it was, up to C8's 4th harmonic at 96 kHz. Above the new Nyquist's lowest fold, nothing.
    for freq in ([]f64{100, 4186, 16_744}) {
        gain := level(96_000, freq)
        testing.expectf(t, abs(gain - 1) < 0.001, "%v Hz at %v", freq, gain)
    }
    for freq in ([]f64{29_000, 31_814, 40_000, 47_000}) {
        gain := level(96_000, freq)
        testing.expectf(t, gain < 1e-5, "%v Hz folds down at %v", freq, gain)
    }

    // Two halvings, 192 kHz: what would fold through either stage
    testing.expect(t, abs(level(192_000, 1000) - 1) < 0.001)
    for freq in ([]f64{30_000, 70_000, 90_000}) {
        gain := level(192_000, freq)
        testing.expectf(t, gain < 1e-5, "%v Hz folds down at %v", freq, gain)
    }
}
