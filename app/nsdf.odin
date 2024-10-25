/* -------------------------------------------------------------------------------------------------


    Pitch detection based on NSDF (McLeod Pitch Method)

    http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf



------------------------------------------------------------------------------------------------- */


package app
import "core:mem"
import "core:fmt"
import "core:math"

import "../pffft"


Vec2 :: [2]f32

NSDFConfig :: struct {
    pffft_setup: rawptr,
    fft_size: int,
    fft: []complex64,
    spectrum: []f32,
    autocorr: []f32,
    nsdf: []f32,
    samplerate: int,
    padded_samples: []f32,
    autocorr_peaks: [dynamic]int,
    nsdf_peaks: [dynamic]Vec2,
    chosen_peak_idx: int,
}

nsdf_init :: proc (fft_size: int, samplerate: int) -> (self: NSDFConfig = {}) {
    self.fft_size = fft_size
    self.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    self.fft = make([]complex64, fft_size)
    self.autocorr = make([]f32, fft_size)
    self.spectrum = make([]f32, fft_size)
    self.nsdf = make([]f32, fft_size/2)
    self.samplerate = samplerate
    self.padded_samples = make([]f32, fft_size)
    return
}

nsdf_destroy :: proc (self: ^NSDFConfig) {
    pffft.destroy_setup(self.pffft_setup)
    delete(self.fft)
    delete(self.spectrum)
    delete(self.autocorr)
    delete(self.nsdf)
    delete(self.padded_samples)
    delete(self.autocorr_peaks)
    delete(self.nsdf_peaks)
}

nsdf_pitch_detect :: proc (self: ^NSDFConfig, samples: []f32) -> (f32, Vec2) {

    nsdf_process_samples(self, samples)
    nsdf_run_nsdf(self, samples)

    peak := nsdf_find_peak(self)

    estimated_freq: f32 = 0.0

    if peak.x > 0.0 {
        estimated_freq =  f32(self.samplerate) / peak.x
    }

    // apply windowing?
    // spectrum_freq := nsdf_find_spectrum_freq(self, estimated_freq)
    // fmt.println(estimated_freq, spectrum_freq)

    return estimated_freq, peak
}


// TODO: remove
nsdf_find_spectrum_freq :: proc(self: ^NSDFConfig, nsdf_freq: f32) -> f32 {
 // calculate the spectrum
    for i in 0..<self.fft_size/2 {
        self.spectrum[i] = magnitude(self.fft[i])
    }

    bin := 0
    max_magnitude := f32(0.0)

    mag: f32 = 0.0

    // Keep only the positive frequencies (DC to Nyquist), ignore first 2 bins
    for i in 2..<self.fft_size/2 {
        mag := self.spectrum[i]

        // only search around the already found NSDF peak
        freq_resolution := f32(self.samplerate) / f32(self.fft_size)
        freq_hz := f32(i) * freq_resolution
        if freq_hz >= nsdf_freq + freq_resolution {
            break
        }

        if mag > max_magnitude {
            max_magnitude = mag
            bin = i
        }
    }

    // Parabolic interpolation to determine a more accurate pitch
    peak_location: f32 = 0
    if bin > 0 {
        peak_location, _ = parabolic(
            math.ln(self.spectrum[bin-1]),
            math.ln(self.spectrum[bin]),
            math.ln(self.spectrum[bin+1]),
        )
    }

    improved_bin := f32(bin) + peak_location
    freq := improved_bin * f32(self.samplerate) / f32(self.fft_size)

    return freq
}


// Generate the auto-correlation
//   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
//    then taking the inverse FFT will give us the cyclic auto-correlation.
@(private)
nsdf_process_samples :: proc (self: ^NSDFConfig, samples: []f32) {
    assert(len(samples) <= self.fft_size/2)

    // pad samples with zeros to avoid cyclic convolution
    mem.zero_slice(self.padded_samples)
    mem.zero_slice(self.autocorr)
    copy(self.padded_samples, samples)

    // FFT transform
    pffft.transform_ordered(
        self.pffft_setup,
        raw_data(self.padded_samples),
        raw_data(mem.slice_data_cast([]f32, self.fft)),
        nil,
        pffft.Direction.FORWARD
    )

    // multiply FFT with conjugate
    // - conjugation in the frequency domain is equivalent to reversal in the time domain
    // (the difference between cross-correlation and convolution is a time reversal on one of the inputs)
    for i in 0..<len(self.fft) {
        self.fft[i] = self.fft[i] * conj(self.fft[i])
    }

    // inverse FFT to produce auto-correlation
    pffft.transform_ordered(
        self.pffft_setup,
        raw_data(mem.slice_data_cast([]f32, self.fft)),
        raw_data(self.autocorr),
        nil,
        pffft.Direction.BACKWARD
    )

    // scale by 1/N
    for i in 0..<len(self.autocorr) {
        self.autocorr[i] = self.autocorr[i] / f32(self.fft_size)
    }
}


@(private)
nsdf_find_peak :: proc (self: ^NSDFConfig) -> Vec2 {
    // clear out peaks from the previous run
    clear(&self.nsdf_peaks)

    // TODO
    n := len(self.nsdf) - 256

    MIN_PEAK_VALUE := 0.5 * self.nsdf[0]

    max_peak := Vec2{0.0, 0.0}

    // enumerate all the candidate peaks
    i := 1
    for i < n {

        // go down the first slope
        for i < n && self.nsdf[i] > 0.0 do i += 1

        // skip all negative values
        for i < n && self.nsdf[i] <= 0.0 do i += 1

        lag := i
        min := lag

        // search for a local max peak in the positive area
        for i < n - 1 && self.nsdf[i] > 0.0 {
            if self.nsdf[i] > self.nsdf[lag] && self.nsdf[i] > self.nsdf[i+1] && self.nsdf[i] > MIN_PEAK_VALUE {
                lag = i
            }
            i += 1
        }

        if lag > min {
            peak_location, magnitude := parabolic(
                self.nsdf[lag-1],
                self.nsdf[lag],
                self.nsdf[lag+1]
            )

            improved_lag := f32(lag) + peak_location
            peak := Vec2{improved_lag, magnitude}
            append(&self.nsdf_peaks, peak)

            if magnitude >= max_peak.y {
                max_peak = peak
            }
        }


        i += 1
    }

    THRESHOLD: f32 = 0.95
    chosen_peak: Vec2 = {}
    self.chosen_peak_idx = -1

    // take the first key maximum above this threshold
    for p, idx in self.nsdf_peaks {
        if p.y >= THRESHOLD * max_peak.y {
            chosen_peak = p
            self.chosen_peak_idx = idx
            break
        }
    }

    return chosen_peak
}

// Normalized Square Difference Function (through autocorrelation)
// http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf
@(private)
nsdf_run_nsdf :: proc (self: ^NSDFConfig, samples: []f32) {
    n := len(samples)
    copy(self.nsdf, self.autocorr[:n])

    // left-hand summation for zero lag
    lhsum := 2.0 * self.nsdf[0]

    for i in 0..<n {
        if lhsum > 0.0 {
            self.nsdf[i] *= 2.0 / lhsum
            lhsum -= samples[i] * samples[i] + samples[n-i-1] * samples[n-i-1]
        } else {
            self.nsdf[i] = 0.0
        }
    }
}
