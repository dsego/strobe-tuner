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


package app

import "core:fmt"
import "core:math"
import "core:slice"

import "../core"
import "../gfx"

// What the pitch detection hears, the power spectrum of the input through its filters under a Hann window
// as long as the Window setting says, its own transform, see core.WindowedSpectrum. One of the display
// types. Not a way to tune, the peaks are about 8 Hz wide at 170 ms: it shows what's there and how far it
// stands over the noise, e.g. a fridge's 300 Hz hum louder than the string. The loudest peaks are named by
// their note, the marks are the strobe's tracks, a note the tuner has sits on them.
// As SNR each bin is drawn over the noise around it, the room's rumble and hiss lie flat along the bottom
// and only what stands out rises, as far as the tuner can tell it from the noise. As dBFS it's the level,
// sloping down with the room.
// The power is averaged over the window's length. One frame of noise spikes 10 dB here and there, averaged
// it evens out while a steady tone stays, a pluck takes as long to come up.
// The detector's band, after its highpass and lowpass, a bass E1's fundamental or the mains look weaker
// than they are. Its own samples, not the detector's window: a frame that takes longer than the window,
// e.g. a debug build's at the longest setting, reads one whole window and skips the rest, and a history
// of those showed a comb at the window's spacing, 12 Hz, with the note between its teeth.

SPECTRUM_LOW_HZ :: 40
SPECTRUM_FLOOR_DB :: -120 // dBFS, under any input's noise

// The plot's bottom and top, over the noise and as the level
SPECTRUM_SNR_DB :: [2]f32{0, 60}
SPECTRUM_DBFS_DB :: [2]f32{-90, 0}

// The noise around a bin, the median of the bins this far either side, a low note's partials between
// are fewer than half of them. Worked out every few Hz and drawn straight between. Of as many bins at
// every window, every other or every fourth of a long window's finer ones: the medians cost the same,
// and a bin in a peak's lobe says what its neighbours do.
SPECTRUM_NOISE_HZ :: 190
SPECTRUM_NOISE_STEP_HZ :: 47
SPECTRUM_NOISE_SAMPLES :: 32 // either side, every bin at 85 ms

// Named, the loudest ones this far over the noise and not this far under the loudest
SPECTRUM_MAX_LABELS :: 5
SPECTRUM_PROMINENCE_DB :: 15
SPECTRUM_LABEL_RANGE_DB :: 40

SpectrumPeak :: struct {
    freq:  f32,
    db:    f32, // over the noise
    level: f32, // dBFS
    shown: f32, // its height on the plot
}

SpectrumView :: struct {
    using node: core.AudioCaptureNode, // its own samples, read whole however long a frame takes
    // The detector's, so it's what the detection hears, see core.PitchDetector
    highpass:   core.Biquad,
    lowpass:    core.Biquad,
    transform:  core.WindowedSpectrum, // of the latest samples, as long as the Window setting says
    power:      []f32, // of each bin, averaged
    levels:     []f32, // the same in dBFS
    over:       []f32, // dB over the noise around each bin
}

init_spectrum_view :: proc(sample_rate: f32 = core.DEFAULT_SAMPLE_RATE) -> (self: SpectrumView) {
    core.init_audio_capture_node(&self, "spectrum", sample_rate)
    size_spectrum_filters(&self)
    return
}

destroy_spectrum_view :: proc(self: ^SpectrumView) {
    core.destroy_audio_capture_node(self)
    core.destroy_windowed_spectrum(&self.transform)
    delete(self.power)
    delete(self.levels)
    delete(self.over)
}

// The input opened at another rate, the filters are made for it and everything starts over like for another
// input, the transform is made at the next update
set_spectrum_view_sample_rate :: proc(self: ^SpectrumView, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    size_spectrum_filters(self)
    reset_spectrum_view(self)
}

size_spectrum_filters :: proc(self: ^SpectrumView) {
    self.highpass = core.init_highpass(core.PITCH_HIGHPASS_HZ, self.sample_rate)
    self.lowpass = core.init_lowpass(core.pitch_lowpass_hz(self.sample_rate), self.sample_rate)
}

// Another input's signal is unrelated to the previous one's, like core.reset_pitch_detector: the samples
// start out silent, the filters from rest and the average from nothing
reset_spectrum_view :: proc(self: ^SpectrumView) {
    slice.zero(self.transform.samples)
    slice.zero(self.power)
    core.reset_biquad(&self.highpass)
    core.reset_biquad(&self.lowpass)
}

// Every frame, the new spectrum of what came in since the one before. windows is the window's length in the
// detector's, the Window setting. While another display shows nothing reads here, the ring buffer fills up
// and the first read back skips what's stale, see core.audio_capture_read.
update_spectrum_view :: proc(self: ^SpectrumView, windows: f32) {
    window := int(windows) * core.pitch_window(self.sample_rate)
    if len(self.transform.samples) != window {
        core.destroy_windowed_spectrum(&self.transform)
        delete(self.power)
        delete(self.levels)
        delete(self.over)
        self.transform = core.init_windowed_spectrum(window)
        self.power = make([]f32, len(self.transform.spectrum))
        self.levels = make([]f32, len(self.transform.spectrum))
        self.over = make([]f32, len(self.transform.spectrum))
    }

    // The newest samples at the end of the history, all of them however long the frame took
    transform := &self.transform
    read, elapsed := core.audio_capture_read(self, transform.samples)
    if read == 0 do return

    // Samples went by that the history didn't get, the filters start from rest on the new ones
    if i64(read) < elapsed {
        core.reset_biquad(&self.highpass)
        core.reset_biquad(&self.lowpass)
    }
    new_samples := transform.samples[len(transform.samples) - read:]
    core.biquad_process(&self.highpass, new_samples, new_samples)
    core.biquad_process(&self.lowpass, new_samples, new_samples)
    core.run_windowed_spectrum(transform)

    full_scale_db := 20 * math.log10(transform.full_scale)
    average_s := f32(window) / self.sample_rate
    alpha := 1 - math.exp(-f32(elapsed) / self.sample_rate / average_s)

    // Only up to the plot's top and the noise window past it, the rest up to Nyquist is never shown, e.g.
    // 1800 of the 8192 bins at 48 kHz
    bin_hz := self.sample_rate / f32(transform.fft_size)
    noise_bins := int(SPECTRUM_NOISE_HZ / bin_hz)
    used := min(int(core.pitch_lowpass_hz(self.sample_rate) / bin_hz) + noise_bins + 1, len(self.power))

    // The first bin packs DC and Nyquist, see core.square_spectrum
    for &power, bin in self.power[:used] {
        if bin > 0 do power += alpha * (real(transform.spectrum[bin]) - power)
        self.levels[bin] = max(10 * math.log10(max(power, 1e-20)) - full_scale_db, SPECTRUM_FLOOR_DB)
    }

    // The noise at every few bins of every stride-th, the span held in at the ends
    stride := max(noise_bins / SPECTRUM_NOISE_SAMPLES, 1)
    step := max(int(SPECTRUM_NOISE_STEP_HZ / bin_hz), 1)
    levels := self.levels[:used]
    around := make([]f32, 2 * (noise_bins / stride) + 1, context.temp_allocator)
    noise_at :: proc(levels, around: []f32, bin, stride: int) -> f32 {
        span := stride * (len(around) - 1)
        start := clamp(bin - span / 2, 0, len(levels) - 1 - span)
        for &value, index in around do value = levels[start + index * stride]
        slice.sort(around)
        return around[len(around) / 2]
    }

    below_bin := 0
    below := noise_at(levels, around, 0, stride)
    for below_bin < len(levels) {
        above_bin := min(below_bin + step, len(levels) - 1)
        above := noise_at(levels, around, above_bin, stride)
        for bin in below_bin ..= above_bin {
            noise := math.lerp(below, above, f32(bin - below_bin) / f32(max(above_bin - below_bin, 1)))
            self.over[bin] = max(levels[bin] - noise, 0)
        }

        if above_bin == len(levels) - 1 do break
        below_bin, below = above_bin, above
    }
}

// Across the plot, low notes on the left on a log scale
spectrum_x :: proc(freq, low_hz, high_hz: f32, plot: gfx.Rect) -> f32 {
    return plot.x + plot.width * math.ln(freq / low_hz) / math.ln(high_hz / low_hz)
}

// Up the plot, range is its bottom and top in dB
spectrum_y :: proc(db: f32, range: [2]f32, plot: gfx.Rect) -> f32 {
    return plot.y + plot.height * (1 - clamp((db - range[0]) / (range[1] - range[0]), 0, 1))
}

// Low notes on the left on a log scale, a C every octave. track_hz are the strobe tracks' partials, marked
// and lit while the tuner has the note.
draw_spectrum_view :: proc(
    self: ^SpectrumView,
    display: ^StrobeDisplay,
    rect: gfx.Rect,
    track_hz: []f32,
    active: bool,
    config: ^Config,
    line_color, band_color, background: gfx.Color,
) {
    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

    // Room for the labels above the peaks and the octaves under the plot
    PADDING_TOP :: 40
    PADDING_BOTTOM :: 28
    plot := gfx.Rect{rect.x, rect.y + PADDING_TOP, rect.width, rect.height - PADDING_TOP - PADDING_BOTTOM}
    if len(self.levels) == 0 || plot.width <= 0 || plot.height <= 0 do return
    low_hz: f32 = SPECTRUM_LOW_HZ
    high_hz := core.pitch_lowpass_hz(self.sample_rate)
    bin_hz := self.sample_rate / f32(self.transform.fft_size)
    pitch_standard := config.pitch_standard

    // What's drawn, and the plot's bottom and top in it
    shown, range := self.over, SPECTRUM_SNR_DB
    if config.spectrum_scale == .DBFS do shown, range = self.levels, SPECTRUM_DBFS_DB

    // The octaves' Cs and the tracks' partials across the plot
    octave_x := make([dynamic][2]f32, context.temp_allocator) // x and the octave
    for octave in 1 ..= 8 {
        c_hz := core.freq_at_cents(pitch_standard, f32((octave - 4) * 1200 - 900))
        if c_hz >= low_hz && c_hz <= high_hz do append(&octave_x, [2]f32{spectrum_x(c_hz, low_hz, high_hz, plot), f32(octave)})
    }
    track_x := make([dynamic]f32, context.temp_allocator)
    for freq in track_hz {
        if freq >= low_hz && freq <= high_hz do append(&track_x, spectrum_x(freq, low_hz, high_hz, plot))
    }

    // The curve, a point every couple of points across: the loudest bin under it, or between two bins where
    // the low notes spread a bin over several columns
    STEP :: 2
    points := make([dynamic][2]f32, context.temp_allocator)
    for x: f32 = 0; x <= plot.width; x += STEP {
        from := low_hz * math.pow(high_hz / low_hz, x / plot.width) / bin_hz
        to := low_hz * math.pow(high_hz / low_hz, (x + STEP) / plot.width) / bin_hz
        last := len(shown) - 1

        db := range[0]
        if to - from >= 1 {
            for bin in int(math.ceil(from)) ..= min(int(to), last) do db = max(db, shown[bin])
        } else {
            below := min(int(from), last - 1)
            db = math.lerp(shown[below], shown[below + 1], from - f32(below))
        }
        append(&points, [2]f32{plot.x + x, spectrum_y(db, range, plot)})
    }

    // With the retro glow the curve glows like the scope's beam, the bloom added once: the scope's thin
    // beam takes it a few times over, the curve's thicker and busier
    if config.strobe_glow {
        begin_glow(display, rect, background)
        draw_plot(plot, points[:], octave_x[:], track_x[:], active, line_color, band_color, background)
        end_glow(display, rect, 1)
    }

    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if !config.strobe_glow do draw_plot(plot, points[:], octave_x[:], track_x[:], active, line_color, band_color, background)

    // The text over it, sharp. Each C under its line, held inside the edges, C8's near the right one.
    font := pixel_fonts.band_label_small
    for octave in octave_x {
        text := fmt.ctprintf("C%d", int(octave.y))
        width := measure_label(font, text).x
        x := clamp(octave.x - width / 2, plot.x + 4, plot.x + plot.width - width - 4)
        draw_label(font, text, {x, plot.y + plot.height + 6}, text_color_muted)
    }

    peaks := find_peaks(self, shown, low_hz, high_hz, bin_hz)
    if config.spectrum_peak_level do draw_peak_level(peaks, plot, range, background)
    if config.spectrum_labels != .OFF {
        draw_peak_labels(peaks, plot, range, low_hz, high_hz, pitch_standard, config.spectrum_labels, background)
    }

    // On a pill of the background, the lines and the curve don't run through the text
    draw_label_pill :: proc(bounds: gfx.Rect, background: gfx.Color) {
        PADDING :: [2]f32{8, 3}
        pill := background
        pill.a = 220
        gfx.draw_pill({bounds.x - PADDING.x, bounds.y - PADDING.y, bounds.width + 2 * PADDING.x, bounds.height + 2 * PADDING.y}, pill)
    }

    // A line across at the loudest peak, its level in dBFS at the right end over it
    draw_peak_level :: proc(peaks: []SpectrumPeak, plot: gfx.Rect, range: [2]f32, background: gfx.Color) {
        if len(peaks) == 0 do return

        loudest := peaks[0]
        for peak in peaks do if peak.level > loudest.level do loudest = peak

        y := spectrum_y(loudest.shown, range, plot)
        line := text_color_muted
        line.a = 140
        gfx.draw_rect({plot.x, y - 0.5}, {plot.width, 1}, line)

        font := pixel_fonts.label_small
        text := fmt.ctprintf("%.0f dBFS", loudest.level)
        size := measure_label(font, text)
        position := [2]f32{plot.x + plot.width - size.x - 12, y - size.y - 6}
        draw_label_pill({position.x, position.y, size.x, size.y}, background)
        draw_label(font, text, position, text_color_muted)
    }

    // The octaves' lines and the tracks' marks behind the curve, filled solid under it so they stay behind.
    // The curve like the trace's line, a soft glow under a thin line, both of anti-aliased dots.
    draw_plot :: proc(
        plot: gfx.Rect,
        points: [][2]f32,
        octave_x: [][2]f32,
        track_x: []f32,
        active: bool,
        line_color, band_color, background: gfx.Color,
    ) {
        grid := band_color
        grid.a = 70
        for octave in octave_x do gfx.draw_rect({octave.x, plot.y}, {1, plot.height}, grid)

        mark := accent_color
        mark.a = 160 if active else 60
        for x in track_x do gfx.draw_rect({x - 0.5, plot.y}, {1.5, plot.height}, mark)

        fill := lerp_color(background, line_color, 0.2)
        fill.a = 255
        bottom := plot.y + plot.height
        for index in 0 ..< len(points) - 1 {
            point := points[index]
            gfx.draw_rect({point.x, point.y}, {points[index + 1].x - point.x, bottom - point.y}, fill)
        }

        // Thinner than the trace's, a spectrum is jagged and the fill under it carries the shape. The glow's
        // dots are half its radius apart, the thin line is straight pieces, its dots would take thousands.
        GLOW_RADIUS :: 2.5
        LINE_WIDTH :: 1.2
        glow := line_color
        glow.a = 16
        pen := Pen {
            radius = GLOW_RADIUS,
            color  = glow,
        }
        pen_start(&pen, points[0])
        for point in points[1:] do pen_line_to(&pen, point)

        for index in 1 ..< len(points) {
            gfx.draw_line(points[index - 1], points[index], LINE_WIDTH, line_color)
        }
    }

    // The peaks that stand out over the noise, the one most over it first
    find_peaks :: proc(self: ^SpectrumView, shown: []f32, low_hz, high_hz, bin_hz: f32) -> []SpectrumPeak {
        // The highest past the main lobe, 4 bins either side under the Hann window, its first sidelobes 31 dB down
        SIDE_BINS :: 6
        peaks := make([dynamic]SpectrumPeak, context.temp_allocator)
        over := self.over
        first := max(int(low_hz / bin_hz), SIDE_BINS)
        last := min(int(high_hz / bin_hz), len(over) - 1 - SIDE_BINS)
        for bin in first ..= last {
            db := over[bin]
            if db < SPECTRUM_PROMINENCE_DB do continue

            highest := true
            for other in bin - SIDE_BINS ..= bin + SIDE_BINS {
                if over[other] > db || (over[other] == db && other < bin) do highest = false
            }
            if !highest do continue

            offset, value := core.parabolic(over[bin - 1], db, over[bin + 1])
            append(&peaks, SpectrumPeak{(f32(bin) + offset) * bin_hz, value, self.levels[bin], shown[bin]})
        }
        slice.sort_by(peaks[:], proc(a, b: SpectrumPeak) -> bool {return a.db > b.db})
        return peaks[:]
    }

    // The loudest peaks named by their note and Hz, over the curve as it's shown. The loudest first, one
    // that would cover a louder one's label is left out.
    draw_peak_labels :: proc(
        peaks: []SpectrumPeak,
        plot: gfx.Rect,
        range: [2]f32,
        low_hz, high_hz, pitch_standard: f32,
        labels: SpectrumLabels,
        background: gfx.Color,
    ) {
        if len(peaks) == 0 do return
        loudest := peaks[0].db

        name_font, hz_font := pixel_fonts.band_label, pixel_fonts.band_label_small
        placed := make([dynamic]gfx.Rect, context.temp_allocator)
        for peak in peaks {
            if len(placed) == SPECTRUM_MAX_LABELS || peak.db < loudest - SPECTRUM_LABEL_RANGE_DB do break

            // The note, its Hz under it, or either alone
            name, hz: cstring
            if labels != .HZ do name = fmt.ctprintf("%s", core.note_name(core.freq_to_note(peak.freq, pitch_standard)))
            if labels != .NOTE do hz = fmt.ctprintf("%.0fHz", peak.freq)
            name_size := measure_label(name_font, name) if name != nil else {}
            hz_size := measure_label(hz_font, hz) if hz != nil else {}

            // Centered over the peak, inside the plot's sides
            GAP :: 4
            width := max(name_size.x, hz_size.x)
            height := name_size.y + hz_size.y + (GAP if labels == .BOTH else 0)
            x := spectrum_x(peak.freq, low_hz, high_hz, plot)
            top := max(spectrum_y(peak.shown, range, plot) - height - 6, plot.y - height)
            bounds := gfx.Rect{clamp(x - width / 2, plot.x + 4, plot.x + plot.width - width - 4), top, width, height}

            covers := false
            for other in placed {
                if bounds.x < other.x + other.width + 8 && other.x < bounds.x + bounds.width + 8 &&
                   bounds.y < other.y + other.height && other.y < bounds.y + bounds.height {
                    covers = true
                }
            }
            if covers do continue
            append(&placed, bounds)

            draw_label_pill(bounds, background)
            if name != nil do draw_label(name_font, name, {bounds.x + (width - name_size.x) / 2, bounds.y}, text_color_light)
            if hz != nil {
                hz_y := bounds.y + bounds.height - hz_size.y
                draw_label(hz_font, hz, {bounds.x + (width - hz_size.x) / 2, hz_y}, text_color_muted)
            }
        }
    }
}
