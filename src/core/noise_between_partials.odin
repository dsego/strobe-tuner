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

import "core:math"
import "core:slice"


// A track's SNR is taken over the noise floor and the noise between the note's partials together, as powers, the
// latter as the spectrum display draws it, see update_band_noise_floor. The noise floor learns the room before the
// note, but a string brings its own noise along, it rises with the pluck and fades with the note: a weak partial
// sinking into it shook at full strength over the floor, and a track with no partial in it, a fifth over a single
// note, lit on it. Added to the floor it only ever dims, the floor still keeps the silence dark. On
// sandbox/samples the shake it predicts is the measured one from 15 dB up, see sandbox/partial_levels.

// The gaps within this many of the note's partials either side of a track, and no further than
// NOISE_SPAN_MAX_HZ: close enough that the noise there is about as loud as on the track
NOISE_SPAN_PARTIALS :: 2
NOISE_SPAN_MAX_HZ :: 500

// With fewer bins in the gaps there's no telling, the track keeps the floor's SNR alone
NOISE_MIN_BINS :: 8

// A track's noise is the median of its readings over the last NOISE_HISTORY_S, one every NOISE_HISTORY_STEP_S:
// a reading swings a few dB, and the next frame's window is mostly the same samples, it takes a few windows to
// even out. A pluck splashes over the gaps until its attack has passed through the window, under half of the
// readings, the median leaves it out where an average would carry it for seconds. A note's noise fades with
// it by a few dB a second, the median is a quarter second behind, the tracks dim a little early.
NOISE_HISTORY_S :: 0.5
NOISE_HISTORY_STEP_S :: 1.0 / 60
NOISE_HISTORY :: int(NOISE_HISTORY_S / NOISE_HISTORY_STEP_S)

NoiseHistory :: struct {
    powers: [NOISE_HISTORY]f32,
    count:  int,
    next:   int, // where the next reading goes, over the oldest once it's full
    due_s:  f32, // until the next reading
}


// A partial's main lobe under the Blackman-Harris window, this many of the window's bins either side
NOISE_LOBE_BINS :: 4

// Each track's noise between the note's partials, see noise_between_partials, as the level it would read on
// the track through the window they share, smoothed. On the samples the tracks just measured, as many of the
// newest as fit their window in a power of 2: sized for the note like it, a partial's lobe is a small part of
// the gap to the next. Under a Blackman-Harris window, its sidelobes 92 dB down: the Hann window's are 60 dB
// down halfway to the next partial, and a clean input's partials stand further than that over the noise. A
// track with no gaps to tell by keeps 0, the floor's SNR alone.
measure_noise_between_partials :: proc(self: ^StrobeLockIn) {
    window := 1
    for 2 * window <= self.bands[0].dft.window_size do window *= 2

    transform := &self.noise_spectrum
    if len(transform.samples) != window {
        destroy_windowed_spectrum(transform)
        transform^ = init_windowed_spectrum(window)

        for &weight, index in transform.taper {
            angle := math.TAU * f64(index) / f64(window)
            weight = f32(0.35875 - 0.48829 * math.cos(angle) + 0.14128 * math.cos(2 * angle) - 0.01168 * math.cos(3 * angle))
        }
    }
    copy(transform.samples, self.sample_buffer[self.buffer_len - window:self.buffer_len])
    run_windowed_spectrum(transform)

    // A track's own band is no gap either, it may hold another note's partial, a fifth's
    avoid: [MAX_BANDS]f32
    for band, index in self.bands do avoid[index] = band.freq_hz
    tracks_hz := avoid[:len(self.bands)]

    dt := f32(self.available) / self.sample_rate
    for &band in self.bands {
        power, ok := noise_between_partials(transform^, self.sample_rate, band.freq_hz, self.base_freq_hz, tracks_hz, self.band_cents)
        if !band.in_range || !ok {
            band.noise_between = 0
            band.noise_history = {}
            continue
        }

        history := &band.noise_history
        history.due_s -= dt
        if history.due_s <= 0 {
            history.powers[history.next] = power
            history.next = (history.next + 1) % NOISE_HISTORY
            history.count = min(history.count + 1, NOISE_HISTORY)
            history.due_s += NOISE_HISTORY_STEP_S
            history.due_s = max(history.due_s, 0)
        }

        readings := history.powers
        slice.sort(readings[:history.count])
        band.noise_between = math.sqrt(readings[history.count / 2] * self.window_noise_gain)
    }
}

// The noise's power a sample around freq_hz, from the transform's bins in the gaps between the note's partials,
// base_hz apart, and away from the tracks: their median, a gap holds the noise and the odd stray, a hum or a
// ringing string's partial. A white noise's bins are spread exponentially, their median is ln 2 of their mean,
// and a bin lets the sum of the squared weights of the samples' power through. Under the fundamental the gap is
// as wide as the others, lower down is the room's rumble. ok is false with too few bins to tell.
noise_between_partials :: proc(
    transform: WindowedSpectrum,
    sample_rate, freq_hz, base_hz: f32,
    tracks_hz: []f32,
    band_cents: int,
) -> (
    power: f32,
    ok: bool,
) {
    window := f32(len(transform.samples))
    bin_hz := sample_rate / f32(transform.fft_size)

    // A partial's main lobe, and as far off the note as a track still hears it, see hears_note
    lobe_hz := NOISE_LOBE_BINS * sample_rate / window
    off_note := math.pow(2, f32(band_cents) / 1200) - 1
    near :: proc(freq_hz, partial_hz, lobe_hz, off_note: f32) -> bool {
        return abs(freq_hz - partial_hz) <= lobe_hz + off_note * partial_hz
    }

    span_hz := min(NOISE_SPAN_PARTIALS * base_hz, NOISE_SPAN_MAX_HZ)
    first := max(int(math.ceil(max(freq_hz - span_hz, 0.5 * base_hz) / bin_hz)), 1)
    last := min(int((freq_hz + span_hz) / bin_hz), transform.fft_size / 2 - 1)
    if last < first do return 0, false

    powers := make([dynamic]f32, 0, last - first + 1, context.temp_allocator)
    for bin in first ..= last {
        bin_freq := f32(bin) * bin_hz

        // Between the partial under it and the one over it, the fundamental's the lowest
        below := math.floor(bin_freq / base_hz)
        if below >= 1 && near(bin_freq, below * base_hz, lobe_hz, off_note) do continue
        if near(bin_freq, (below + 1) * base_hz, lobe_hz, off_note) do continue

        on_track := false
        for track_hz in tracks_hz do on_track ||= near(bin_freq, track_hz, lobe_hz, off_note)
        if on_track do continue

        append(&powers, real(transform.spectrum[bin]))
    }
    if len(powers) < NOISE_MIN_BINS do return 0, false

    squares: f32
    for weight in transform.taper do squares += weight * weight

    slice.sort(powers[:])
    median := powers[len(powers) / 2]
    return median / math.LN2 / squares, true
}
