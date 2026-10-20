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

import fft "../../external/extreme_fft"


// The power spectrum of the latest samples under a Hann window, a picture of what's there. The NSDF's own
// transform takes its window as it is, its normalization wants that, but with no taper every peak has a skirt
// of sidelobes falling only 6 dB an octave: a loud note's reaches across the band, and on a clean input it's
// all there is above the note. Under the Hann window they fall 18 dB an octave, the first 31 dB down, and a
// peak's lobe is twice as wide, 4 bins of the window either side. The window is as long as the picture wants
// its peaks narrow. Zero padded to twice its length like the NSDF's, a bin is half the window's.
WindowedSpectrum :: struct {
    plan:        fft.Quad_Plan,
    fft_size:    int, // twice the window
    taper:       []f32, // the Hann window's weights, as long as the samples
    samples:     []f32, // the latest, the newest at the end, see audio_capture_read
    padded:      []f32, // the tapered samples zero padded to the FFT
    spectrum:    []complex64, // the power of each bin, DC and Nyquist packed into the first, see square_spectrum
    full_scale:  f32, // a full scale sine's bin, its magnitude: a quarter of the window's samples
}

init_windowed_spectrum :: proc(window: int) -> (self: WindowedSpectrum) {
    self.fft_size = 2 * window
    self.plan = fft.create_quad_plan(self.fft_size)
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
    if self.fft_size != 0 do fft.destroy_quad_plan(&self.plan)

    delete(self.taper)
    delete(self.samples)
    delete(self.padded)
    delete(self.spectrum)
}

// The samples under the taper through the transform, the power of each bin into spectrum
run_windowed_spectrum :: proc(self: ^WindowedSpectrum) {
    for sample, index in self.samples do self.padded[index] = sample * self.taper[index]

    mem.zero_slice(self.padded[len(self.samples):])
    fft.run_quad(&self.plan, self.padded, self.spectrum)
    square_spectrum(self.spectrum)
}
