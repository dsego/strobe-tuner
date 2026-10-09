// Copyright (C) 2026  Davorin Šego

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

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"

import pffft "../../external/odin-pffft"


// The power spectrum of the latest samples under a Hann window, a picture of what's there. The NSDF's own
// transform takes its window as it is, its normalization wants that, but with no taper every peak has a skirt
// of sidelobes falling only 6 dB an octave: a loud note's reaches across the band, and on a clean input it's
// all there is above the note. Under the Hann window they fall 18 dB an octave, the first 31 dB down, and a
// peak's lobe is twice as wide, 4 bins of the window either side. The window is as long as the picture wants
// its peaks narrow. Zero padded to twice its length like the NSDF's, a bin is half the window's.
WindowedSpectrum :: struct {
    pffft_setup: rawptr,
    fft_size:    int, // twice the window
    taper:       []f32, // the Hann window's weights, as long as the samples
    samples:     []f32, // the latest, the newest at the end, see windowed_spectrum_write or audio_capture_read
    padded:      []f32, // the tapered samples zero padded to the FFT
    spectrum:    []complex64, // the power of each bin, DC and Nyquist packed into the first, see square_spectrum
    full_scale:  f32, // a full scale sine's bin, its magnitude: a quarter of the window's samples
}

init_windowed_spectrum :: proc(window: int) -> (self: WindowedSpectrum) {
    self.fft_size = 2 * window
    self.pffft_setup = pffft.new_setup(self.fft_size, pffft.Transform.REAL)
    self.taper = make([]f32, window)
    self.samples = make([]f32, window)
    self.padded = runtime.make_aligned([]f32, self.fft_size, 16)
    self.spectrum = runtime.make_aligned([]complex64, self.fft_size / 2, 16)

    for &weight, index in self.taper {
        weight = f32(0.5 * (1 - math.cos(math.TAU * f64(index) / f64(window))))
    }
    self.full_scale = f32(window) / 4
    return
}

destroy_windowed_spectrum :: proc(self: ^WindowedSpectrum) {
    if self.pffft_setup != nil do pffft.destroy_setup(self.pffft_setup)

    delete(self.taper)
    delete(self.samples)
    delete(self.padded)
    delete(self.spectrum)
}

// The newest samples after the ones before, of more than the window holds the latest
windowed_spectrum_write :: proc(self: ^WindowedSpectrum, samples: []f32) {
    count := min(len(samples), len(self.samples))
    copy(self.samples, self.samples[count:])
    copy(self.samples[len(self.samples) - count:], samples[len(samples) - count:])
}

// The samples under the taper through the transform, the power of each bin into spectrum
run_windowed_spectrum :: proc(self: ^WindowedSpectrum) {
    for sample, index in self.samples do self.padded[index] = sample * self.taper[index]

    mem.zero_slice(self.padded[len(self.samples):])
    pffft.transform_ordered(self.pffft_setup, raw_data(self.padded), cast(^f32)raw_data(self.spectrum), nil, pffft.Direction.FORWARD)
    square_spectrum(self.spectrum)
}


// A half scale sine on a bin of the window reads 6 dB under full scale. Beside the peak the first sidelobe is
// 31 dB down, and the skirt 20 bins of the window out over 60 dB, where the NSDF's transform with no taper
// has it 36 dB down.
@(test)
test_windowed_spectrum :: proc(t: ^testing.T) {
    WINDOW :: 4096
    PEAK_BIN :: 200 // the window's 100th bin, the padded transform's 200th
    self := init_windowed_spectrum(WINDOW)
    defer destroy_windowed_spectrum(&self)

    nsdf := init_nsdf(2 * WINDOW, DEFAULT_SAMPLE_RATE)
    defer destroy_nsdf(&nsdf)

    samples: [WINDOW]f32
    for &sample, i in samples do sample = f32(0.5 * math.sin(math.TAU * 100 * f64(i) / WINDOW))
    windowed_spectrum_write(&self, samples[:])
    run_windowed_spectrum(&self)
    nsdf_autocorrelate(&nsdf, samples[:])

    peak_db := 20 * math.log10(math.sqrt(real(self.spectrum[PEAK_BIN])) / self.full_scale)
    testing.expectf(t, abs(peak_db + 6.02) < 0.05, "the peak reads %v dB", peak_db)

    // dB from the peak at a bin of a padded transform
    from_peak :: proc(spectrum: []complex64, bin: int) -> f32 {
        return 10 * math.log10(real(spectrum[bin]) / real(spectrum[PEAK_BIN]))
    }

    // Past the lobe, 4 bins either side
    ripple_db: f32 = -200
    for bin in PEAK_BIN + 5 ..= PEAK_BIN + 12 do ripple_db = max(ripple_db, from_peak(self.spectrum, bin))

    testing.expectf(t, ripple_db > -35 && ripple_db < -28, "the first sidelobe is %v dB down", ripple_db)

    // 20 and a half bins out, where the untapered window's sidelobes peak between its nulls on the even bins
    skirt_db := from_peak(self.spectrum, PEAK_BIN + 41)
    plain_db := from_peak(nsdf.spectrum, PEAK_BIN + 41)
    testing.expectf(t, skirt_db < -60, "the skirt is %v dB down", skirt_db)
    testing.expectf(t, plain_db > -40 && plain_db < -30, "with no taper the skirt is %v dB down", plain_db)
}

// The longest window the Window setting makes, 4 of the detector's at 48 kHz, written a display frame at a
// time: the peak is where the note is and nothing stands beside it at the detector's window's spacing, where
// a history of whole windows would put a comb
@(test)
test_windowed_spectrum_hops :: proc(t: ^testing.T) {
    WINDOW :: 4 * 4096
    HOP :: 800
    FREQ :: 82.0
    self := init_windowed_spectrum(WINDOW)
    defer destroy_windowed_spectrum(&self)

    hop: [HOP]f32
    for count in 0 ..< 2 * WINDOW / HOP {
        for &sample, i in hop do sample = f32(0.5 * math.sin(math.TAU * FREQ * f64(count * HOP + i) / DEFAULT_SAMPLE_RATE))
        windowed_spectrum_write(&self, hop[:])
    }
    run_windowed_spectrum(&self)

    peak_bin, peak_power := 0, f32(0)
    for value, bin in self.spectrum[1:] {
        if real(value) > peak_power do peak_bin, peak_power = bin + 1, real(value)
    }
    bin_hz := f32(DEFAULT_SAMPLE_RATE) / f32(self.fft_size)
    testing.expectf(t, abs(f32(peak_bin) * bin_hz - FREQ) < bin_hz, "the peak is at %v Hz", f32(peak_bin) * bin_hz)

    peak_db := 20 * math.log10(math.sqrt(peak_power) / self.full_scale)
    testing.expectf(t, abs(peak_db + 6.02) < 0.1, "the peak reads %v dB", peak_db)

    comb_bins := int(f32(self.fft_size) / 4096)
    for bin in ([2]int{peak_bin - comb_bins, peak_bin + comb_bins}) {
        tooth_db := 10 * math.log10(real(self.spectrum[bin]) / peak_power)
        testing.expectf(t, tooth_db < -30, "%v dB at a detector window's spacing from the peak", tooth_db)
    }
}
