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
// The power is averaged over a quarter of the window, see SPECTRUM_AVERAGE_WINDOWS, and the curve smoothed
// on top, see SPECTRUM_SMOOTHING_S. One frame of noise spikes 10 dB here and there, it evens out while a
// steady tone stays, and a sound that stops falls away within half a second.
// The detector's band, after its highpass and lowpass, a bass E1's fundamental or the mains look weaker
// than they are. Its own samples, not the detector's window: a frame that takes longer than the window,
// e.g. a debug build's at the longest setting, reads one whole window and skips the rest, and a history
// of those showed a comb at the window's spacing, 12 Hz, with the note between its teeth.

// Of each of the glow's two strips, picked in the app a little brighter than the dots they replaced:
// -define:SPECTRUM_GLOW_ALPHA=n to try another
SPECTRUM_GLOW_ALPHA :: #config(SPECTRUM_GLOW_ALPHA, 48)

// How long the curve takes to follow, a time constant, up and down alike: the noise high up holds still
// instead of boiling. -define:SPECTRUM_SMOOTHING_S=n to try another, 0 is off.
SPECTRUM_SMOOTHING_S :: #config(SPECTRUM_SMOOTHING_S, 0.1)

// A point of the curve holds its height while its level moves less than this either way and follows only
// past it, a note's peaks stand still through the 1 or 2 dB a frame wobbles by and a decay slides down
// smoothly, this far behind. Down on the noise they go all the way, the spectrum still disappears.
SPECTRUM_HOLD_DB :: 2

// The power of each bin averaged over this many of its windows, see update_spectrum_display:
// -define:SPECTRUM_AVERAGE_WINDOWS=n to try another
SPECTRUM_AVERAGE_WINDOWS :: #config(SPECTRUM_AVERAGE_WINDOWS, 0.25)

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

// Named, the loudest ones this far over the noise and not this far under the loudest. 40 under named a
// quiet note's strays down along the noise, their bubbles cut off at the plot's bottom.
SPECTRUM_MAX_LABELS :: 5
SPECTRUM_PROMINENCE_DB :: 15
SPECTRUM_LABEL_RANGE_DB :: 20

// How long a name takes to come and to go, a change reads as one and not as a blink
SPECTRUM_LABEL_FADE_S :: 0.2

// A peak named in the frame before keeps its name this far under the prominence and ranks this far louder,
// a new one has to beat it clearly. Picked afresh every frame the names came and went with the peaks near
// the prominence and swapped between near-equal ones. Its Hz holds within SPECTRUM_LABEL_HOLD_HZ.
SPECTRUM_LABEL_HOLD_DB :: 6
SPECTRUM_LABEL_HOLD_HZ :: 1

SpectrumPeak :: struct {
    freq:  f32,
    db:    f32, // over the noise
    level: f32, // dBFS
    shown: f32, // its height on the plot
}

// The one further over the noise first
louder_peak :: proc(first, second: SpectrumPeak) -> bool {
    return first.db > second.db
}

SpectrumDisplay :: struct {
    using node: core.AudioCaptureNode, // its own samples, read whole however long a frame takes
    // The detector's, so it's what the detection hears, see core.PitchDetector
    highpass:   core.Biquad,
    lowpass:    core.Biquad,
    transform:  core.WindowedSpectrum, // of the latest samples, as long as the Window setting says
    power:      []f32, // of each bin, averaged
    levels:     []f32, // the same in dBFS
    over:       []f32, // dB over the noise around each bin
    columns:    [dynamic]f32, // the curve's height at each of its points as drawn, 0 to 1, see SPECTRUM_SMOOTHING_S
    peak_line:  f32, // the line at the loudest peak as drawn, its dB as shown, see SPECTRUM_HOLD_DB
    named:      [dynamic]NamedPeak, // the names of the frame before, coming and going, see SPECTRUM_LABEL_HOLD_DB
}

// A peak's name on the plot, while it fades in and once it's dropped while it fades out where it was
NamedPeak :: struct {
    freq:   f32,
    hz:     f32, // as shown, see SPECTRUM_LABEL_HOLD_HZ
    alpha:  f32, // 0 to 1, see SPECTRUM_LABEL_FADE_S
    shown:  bool, // picked this frame, fading in or there, not fading out
    bounds: gfx.Rect,
}

// Where it is while value stays within hold of it either way, only as far as value moves past that
held_within :: proc(held, value, hold: f32) -> f32 {
    return clamp(held, value - hold, value + hold)
}

init_spectrum_display :: proc(sample_rate: f32 = core.DEFAULT_SAMPLE_RATE) -> (self: SpectrumDisplay) {
    core.init_audio_capture_node(&self, sample_rate)
    size_spectrum_filters(&self)
    return
}

destroy_spectrum_display :: proc(self: ^SpectrumDisplay) {
    core.destroy_audio_capture_node(self)
    core.destroy_windowed_spectrum(&self.transform)
    delete(self.power)
    delete(self.levels)
    delete(self.over)
    delete(self.columns)
    delete(self.named)
}

// The input opened at another rate, the filters are made for it and everything starts over like for another
// input, the transform is made at the next update
set_spectrum_display_sample_rate :: proc(self: ^SpectrumDisplay, sample_rate: f32) {
    if sample_rate == self.sample_rate do return

    self.sample_rate = sample_rate
    size_spectrum_filters(self)
    reset_spectrum_display(self)
}

size_spectrum_filters :: proc(self: ^SpectrumDisplay) {
    self.highpass = core.init_highpass(core.PITCH_HIGHPASS_HZ, self.sample_rate)
    self.lowpass = core.init_lowpass(core.pitch_lowpass_hz(self.sample_rate), self.sample_rate)
}

// Another input's signal is unrelated to the previous one's, like core.reset_pitch_detector: the samples
// start out silent, the filters from rest and the average from nothing
reset_spectrum_display :: proc(self: ^SpectrumDisplay) {
    slice.zero(self.transform.samples)
    slice.zero(self.power)

    // The floor, 0 dB is the bottom of the SNR scale but the top of the dBFS one
    slice.fill(self.levels, SPECTRUM_FLOOR_DB)
    slice.zero(self.over)
    clear(&self.columns)
    clear(&self.named)
    core.reset_biquad(&self.highpass)
    core.reset_biquad(&self.lowpass)
}

// Every frame, the new spectrum of what came in since the one before. windows is the window's length in the
// detector's, the Window setting. While another display shows nothing reads here, the ring buffer fills up
// and the first read back skips what's stale, see core.audio_capture_read.
update_spectrum_display :: proc(self: ^SpectrumDisplay, windows: f32) {
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
        slice.fill(self.levels, SPECTRUM_FLOOR_DB)
    }

    // The newest samples at the end of the history, all of them however long the frame took
    transform := &self.transform
    read, elapsed := core.audio_capture_read_filtered(self, transform.samples, &self.highpass, &self.lowpass)

    // The stale skip coming back from another display, the picture and the filters start over on what's next
    if read == 0 && elapsed > 0 do reset_spectrum_display(self)
    if read == 0 do return

    core.run_windowed_spectrum(transform)

    full_scale_db := 20 * math.log10(transform.full_scale)
    // An average of the power falls a fixed number of dB a second, 4.3 over its time constant: over the whole
    // window a peak 40 dB up took about 2 s to sink after the sound stopped. The curve's own smoothing keeps
    // the noise calm, see SPECTRUM_SMOOTHING_S.
    average_s := SPECTRUM_AVERAGE_WINDOWS * f32(window) / self.sample_rate
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
draw_spectrum_display :: proc(
    self: ^SpectrumDisplay,
    targets: ^GlowTargets,
    rect: gfx.Rect,
    track_hz: []f32,
    active: bool,
    config: ^Config,
) {
    colors := strobe_colors(config)
    line_color, band_color, background := gfx.hex(colors.x), gfx.hex(colors.y), gfx.hex(strobe_bg_color)

    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, background)

    padding: f32 = SPECTRUM_PADDING_TOP + SPECTRUM_PADDING_BOTTOM
    plot := gfx.Rect{rect.x, rect.y + SPECTRUM_PADDING_TOP, rect.width, rect.height - padding}
    if len(self.levels) == 0 || plot.width <= 0 || plot.height <= 0 do return

    low_hz: f32 = SPECTRUM_LOW_HZ
    high_hz := core.pitch_lowpass_hz(self.sample_rate)
    bin_hz := self.sample_rate / f32(self.transform.fft_size)

    // What's drawn, and the plot's bottom and top in it
    shown, range := self.over, SPECTRUM_SNR_DB
    if config.spectrum_scale == .DBFS do shown, range = self.levels, SPECTRUM_DBFS_DB

    octaves := spectrum_octaves(config.pitch_standard, low_hz, high_hz, plot)
    track_x := spectrum_track_marks(track_hz, low_hz, high_hz, plot)
    points := update_spectrum_curve(self, shown, range, plot, low_hz, high_hz, bin_hz)

    // The curve's glow and the labels' pills reach past the sides. The glow's offscreen drawing isn't cut, see
    // gfx.begin_render_target.
    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    // With the retro glow the curve glows like the scope's beam, the bloom added once: the scope's thin
    // beam takes it a few times over, the curve's thicker and busier
    if config.strobe_glow {
        begin_glow(targets, rect, background)
        draw_spectrum_plot(plot, points, octaves, track_x, active, line_color, band_color, background)
        end_glow(targets, rect, 1)
    } else {
        draw_spectrum_plot(plot, points, octaves, track_x, active, line_color, band_color, background)
    }

    // The text over it, sharp
    draw_spectrum_octave_labels(octaves, plot)

    peaks := find_spectrum_peaks(self, shown, low_hz, high_hz, bin_hz)
    if config.spectrum_peak_level do draw_spectrum_peak_level(&self.peak_line, peaks, plot, range, config.spectrum_scale, background)
    if config.spectrum_labels != .OFF {
        draw_peak_labels(self, peaks, plot, low_hz, high_hz, config.pitch_standard, config.spectrum_labels, background)
    } else {
        clear(&self.named)
    }
}

// Room for the labels above the peaks and the octaves under the plot
SPECTRUM_PADDING_TOP :: 40
SPECTRUM_PADDING_BOTTOM :: 28

SPECTRUM_COLUMN_STEP :: 2 // points between the curve's points across the plot

// An octave's C on the plot
SpectrumOctave :: struct {
    x:      f32,
    octave: int,
}

// The octaves' Cs across the plot, those within it
spectrum_octaves :: proc(pitch_standard, low_hz, high_hz: f32, plot: gfx.Rect) -> []SpectrumOctave {
    octaves := make([dynamic]SpectrumOctave, context.temp_allocator)
    for octave in 1 ..= 8 {
        c_hz := core.freq_at_cents(pitch_standard, f32((octave - 4) * 1200 - 900))
        if c_hz >= low_hz && c_hz <= high_hz do append(&octaves, SpectrumOctave{spectrum_x(c_hz, low_hz, high_hz, plot), octave})
    }
    return octaves[:]
}

// The tracks' partials across the plot, those within it
spectrum_track_marks :: proc(track_hz: []f32, low_hz, high_hz: f32, plot: gfx.Rect) -> []f32 {
    track_x := make([dynamic]f32, context.temp_allocator)
    for freq in track_hz {
        if freq >= low_hz && freq <= high_hz do append(&track_x, spectrum_x(freq, low_hz, high_hz, plot))
    }
    return track_x[:]
}

// The curve, a point every SPECTRUM_COLUMN_STEP across, see spectrum_column_db. High up a column is the
// loudest of dozens of bins, of the noise a different one every frame: each point follows over
// SPECTRUM_SMOOTHING_S, up and down alike, the noise settles near its middle. Rising at once and only
// falling slowly held it at the top of its peaks, stuck under the plot's ceiling. Within SPECTRUM_HOLD_DB
// of where it is a point holds. Kept in self.columns, the points live until the end of the frame.
update_spectrum_curve :: proc(
    self: ^SpectrumDisplay,
    shown: []f32,
    range: [2]f32,
    plot: gfx.Rect,
    low_hz, high_hz, bin_hz: f32,
) -> [][2]f32 {
    count := int(plot.width / SPECTRUM_COLUMN_STEP) + 1
    if len(self.columns) != count {
        clear(&self.columns)
        resize(&self.columns, count)
    }
    follow: f32 = 1
    when SPECTRUM_SMOOTHING_S > 0 do follow = 1 - math.exp(-gfx.frame_time() / SPECTRUM_SMOOTHING_S)

    points := make([dynamic][2]f32, context.temp_allocator)
    for column in 0 ..< count {
        x := f32(column) * SPECTRUM_COLUMN_STEP
        from := low_hz * math.pow(high_hz / low_hz, x / plot.width) / bin_hz
        to := low_hz * math.pow(high_hz / low_hz, (x + SPECTRUM_COLUMN_STEP) / plot.width) / bin_hz
        db := spectrum_column_db(shown, from, to, range[0])

        height := &self.columns[column]
        level := clamp((db - range[0]) / (range[1] - range[0]), 0, 1)
        hold := SPECTRUM_HOLD_DB / (range[1] - range[0])
        target := held_within(height^, level, hold) if level > 0 else 0
        height^ += (target - height^) * follow
        append(&points, [2]f32{plot.x + x, plot.y + plot.height * (1 - height^)})
    }
    return points[:]
}

// The loudest bin under a column from bin from to bin to, or between two bins where the low notes spread a
// bin over several columns. Nothing louder is floor.
spectrum_column_db :: proc(shown: []f32, from, to, floor: f32) -> f32 {
    last := len(shown) - 1
    if to - from < 1 {
        below := min(int(from), last - 1)
        return math.lerp(shown[below], shown[below + 1], from - f32(below))
    }

    db := floor
    for bin in int(math.ceil(from)) ..= min(int(to), last) do db = max(db, shown[bin])
    return db
}

// The octaves' lines and the tracks' marks behind the curve, filled solid under it so they stay behind.
// The curve like the trace's line, a soft glow under a thin line, both of anti-aliased dots.
draw_spectrum_plot :: proc(
    plot: gfx.Rect,
    points: [][2]f32,
    octaves: []SpectrumOctave,
    track_x: []f32,
    active: bool,
    line_color, band_color, background: gfx.Color,
) {
    grid := band_color
    grid.a = 70
    for octave in octaves do gfx.draw_rect({octave.x, plot.y}, {1, plot.height}, grid)

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

    // Thinner than the trace's, a spectrum is jagged and the fill under it carries the shape. The glow is
    // two strips, the narrow one over the wide one for a softer edge.
    GLOW_RADIUS :: 2.5
    LINE_WIDTH :: 1.2
    glow := line_color
    glow.a = SPECTRUM_GLOW_ALPHA
    gfx.draw_polyline(points, 2 * GLOW_RADIUS, glow)
    gfx.draw_polyline(points, GLOW_RADIUS, glow)

    for index in 1 ..< len(points) {
        gfx.draw_line(points[index - 1], points[index], LINE_WIDTH, line_color)
    }
}

// Each C under its line, held inside the edges, C8's near the right one
draw_spectrum_octave_labels :: proc(octaves: []SpectrumOctave, plot: gfx.Rect) {
    font := pixel_fonts.band_label_small
    for octave in octaves {
        text := fmt.ctprintf("C%d", octave.octave)
        width := measure_label(font, text).x
        x := clamp(octave.x - width / 2, plot.x + 4, plot.x + plot.width - width - 4)
        draw_label(font, text, {x, plot.y + plot.height + 6}, text_color_muted)
    }
}

// On a pill of the background, the lines and the curve don't run through the text
draw_spectrum_label_pill :: proc(bounds: gfx.Rect, background: gfx.Color, alpha: f32 = 1) {
    PADDING :: [2]f32{8, 3}
    pill := background
    pill.a = u8(220 * alpha)
    gfx.draw_pill({bounds.x - PADDING.x, bounds.y - PADDING.y, bounds.width + 2 * PADDING.x, bounds.height + 2 * PADDING.y}, pill)
}

// A line across at the loudest peak, at the right end over it how high, as the scale says: its SNR or
// its level in dBFS. The reading was its level on both, on SNR the line stood still while it fell with
// the recording's own noise. It holds within SPECTRUM_HOLD_DB like the curve, the reading jumped every
// frame and with it the line.
draw_spectrum_peak_level :: proc(
    held: ^f32,
    peaks: []SpectrumPeak,
    plot: gfx.Rect,
    range: [2]f32,
    scale: SpectrumScale,
    background: gfx.Color,
) {
    if len(peaks) == 0 do return

    loudest := peaks[0]
    for peak in peaks do if peak.level > loudest.level do loudest = peak

    held^ = held_within(held^, loudest.shown, SPECTRUM_HOLD_DB)
    y := spectrum_y(held^, range, plot)
    line := text_color_muted
    line.a = 140
    gfx.draw_rect({plot.x, y - 0.5}, {plot.width, 1}, line)

    font := pixel_fonts.label_small
    text := fmt.ctprintf("%.0f dB SNR" if scale == .SNR else "%.0f dBFS", held^)
    size := measure_label(font, text)
    position := [2]f32{plot.x + plot.width - size.x - 12, y - size.y - 6}
    draw_spectrum_label_pill({position.x, position.y, size.x, size.y}, background)
    draw_label(font, text, position, text_color_muted)
}

// The peaks that stand out over the noise, the one most over it first
find_spectrum_peaks :: proc(self: ^SpectrumDisplay, shown: []f32, low_hz, high_hz, bin_hz: f32) -> []SpectrumPeak {
    // The highest past the main lobe, 4 bins either side under the Hann window, its first sidelobes 31 dB down
    SIDE_BINS :: 6
    peaks := make([dynamic]SpectrumPeak, context.temp_allocator)
    over := self.over
    first := max(int(low_hz / bin_hz), SIDE_BINS)
    last := min(int(high_hz / bin_hz), len(over) - 1 - SIDE_BINS)
    for bin in first ..= last {
        db := over[bin]
        // As low as a named peak keeps its name, the labels pick from these
        if db < SPECTRUM_PROMINENCE_DB - SPECTRUM_LABEL_HOLD_DB do continue

        highest := true
        for other in bin - SIDE_BINS ..= bin + SIDE_BINS {
            if over[other] > db || (over[other] == db && other < bin) do highest = false
        }
        if !highest do continue

        offset, value := core.parabolic(over[bin - 1], db, over[bin + 1])
        append(&peaks, SpectrumPeak{(f32(bin) + offset) * bin_hz, value, self.levels[bin], shown[bin]})
    }
    slice.sort_by(peaks[:], louder_peak)
    return peaks[:]
}

// A peak that could be named this frame, see draw_peak_labels
PeakLabelCandidate :: struct {
    peak:   SpectrumPeak,
    rank:   f32, // its dB over the noise, higher if it was shown
    hz:     f32, // as shown
    alpha:  f32,
    before: Maybe(int), // its name in the frame before
}

// The note, its Hz under it, or either alone, and the bubble's size
PeakLabelText :: struct {
    name, hz:                 cstring,
    name_size, hz_size, size: [2]f32,
}

// The loudest peaks named by their note and Hz, over the curve as it's drawn. The loudest first, the
// ones named in the frame before kept and ranked higher, see SPECTRUM_LABEL_HOLD_DB. One beside a louder
// one's name is left out, whatever their heights: kept apart only where the bubbles overlapped, a run of
// partials a few semitones apart stacked up a cluster of names. A name fades in, and a dropped one fades
// out where it was, see SPECTRUM_LABEL_FADE_S.
draw_peak_labels :: proc(
    self: ^SpectrumDisplay,
    peaks: []SpectrumPeak,
    plot: gfx.Rect,
    low_hz, high_hz, pitch_standard: f32,
    labels: SpectrumLabels,
    background: gfx.Color,
) {
    fade_step := gfx.frame_time() / SPECTRUM_LABEL_FADE_S
    named_before := slice.clone(self.named[:], context.temp_allocator)
    clear(&self.named)

    candidates := peak_label_candidates(peaks, named_before)
    loudest := peaks[0].db if len(peaks) > 0 else 0
    carried := pick_named_peaks(self, candidates, loudest, len(named_before), plot, low_hz, high_hz, pitch_standard, labels, fade_step)
    fade_dropped_peak_labels(self, named_before, carried, fade_step)

    for named in self.named do if !named.shown do draw_named_peak(named, pitch_standard, labels, background)
    for named in self.named do if named.shown do draw_named_peak(named, pitch_standard, labels, background)
}

// Into self.named, up to SPECTRUM_MAX_LABELS of the candidates in their order, within
// SPECTRUM_LABEL_RANGE_DB of the loudest and not beside one already picked. Returns which of the frame
// before's names were carried over.
pick_named_peaks :: proc(
    self: ^SpectrumDisplay,
    candidates: []PeakLabelCandidate,
    loudest: f32,
    before_count: int,
    plot: gfx.Rect,
    low_hz, high_hz, pitch_standard: f32,
    labels: SpectrumLabels,
    fade_step: f32,
) -> (
    carried: []bool,
) {
    carried = make([]bool, before_count, context.temp_allocator)
    shown_count := 0
    for candidate in candidates {
        peak := candidate.peak
        if shown_count == SPECTRUM_MAX_LABELS do break
        if peak.db < loudest - SPECTRUM_LABEL_RANGE_DB do continue

        size := peak_label_text(candidate.hz, pitch_standard, labels).size
        bounds := peak_label_bounds(self, plot, spectrum_x(peak.freq, low_hz, high_hz, plot), size)
        if beside_named_peak(self.named[:], bounds) do continue

        if before, ok := candidate.before.?; ok do carried[before] = true
        alpha := min(candidate.alpha + fade_step, 1)
        append(&self.named, NamedPeak{peak.freq, candidate.hz, alpha, true, bounds})
        shown_count += 1
    }
    return
}

// The peaks that can be named, the most over the noise first. The frame before's name within half a semitone
// carries over, its Hz held from there, and its rank if it was shown.
peak_label_candidates :: proc(peaks: []SpectrumPeak, named_before: []NamedPeak) -> []PeakLabelCandidate {
    candidates := make([dynamic]PeakLabelCandidate, context.temp_allocator)
    for peak in peaks {
        candidate := PeakLabelCandidate{peak, peak.db, peak.freq, 0, nil}
        was_shown := false
        for before, index in named_before {
            if abs(math.log2(peak.freq / before.freq)) > 1.0 / 24 do continue

            candidate.hz = held_within(before.hz, peak.freq, SPECTRUM_LABEL_HOLD_HZ)
            candidate.alpha = before.alpha
            candidate.before = index
            was_shown = before.shown
            if before.shown do candidate.rank += SPECTRUM_LABEL_HOLD_DB
            break
        }

        if was_shown || peak.db >= SPECTRUM_PROMINENCE_DB do append(&candidates, candidate)
    }
    slice.sort_by(candidates[:], proc(first, second: PeakLabelCandidate) -> bool { return first.rank > second.rank })
    return candidates[:]
}

// Centered over the peak at x, inside the plot's sides, on the curve's point there as drawn, it holds still,
// the peak's level a frame wobbles
peak_label_bounds :: proc(self: ^SpectrumDisplay, plot: gfx.Rect, x: f32, size: [2]f32) -> gfx.Rect {
    point := clamp(int((x - plot.x) / SPECTRUM_COLUMN_STEP + 0.5), 0, len(self.columns) - 1)
    curve := plot.y + plot.height * (1 - self.columns[point])
    top := max(curve - size.y - 6, plot.y - size.y)
    return {clamp(x - size.x / 2, plot.x + 4, plot.x + plot.width - size.x - 4), top, size.x, size.y}
}

// Too close beside a louder one's name, whatever their heights
beside_named_peak :: proc(named: []NamedPeak, bounds: gfx.Rect) -> bool {
    GAP :: 8
    for other in named {
        if bounds.x < other.bounds.x + other.bounds.width + GAP && other.bounds.x < bounds.x + bounds.width + GAP do return true
    }
    return false
}

// The dropped ones fade out where they were, under the shown ones
fade_dropped_peak_labels :: proc(self: ^SpectrumDisplay, named_before: []NamedPeak, carried: []bool, fade_step: f32) {
    for before, index in named_before {
        if carried[index] do continue

        faded := before
        faded.alpha -= fade_step
        faded.shown = false
        if faded.alpha > 0 do append(&self.named, faded)
    }
}

peak_label_text :: proc(hz, pitch_standard: f32, labels: SpectrumLabels) -> (text: PeakLabelText) {
    GAP :: 4
    if labels != .HZ do text.name = fmt.ctprintf("%s", core.note_name(core.freq_to_note(hz, pitch_standard)))
    if labels != .NOTE do text.hz = fmt.ctprintf("%.0fHz", hz)
    if text.name != nil do text.name_size = measure_label(pixel_fonts.band_label, text.name)
    if text.hz != nil do text.hz_size = measure_label(pixel_fonts.band_label_small, text.hz)

    text.size = {max(text.name_size.x, text.hz_size.x), text.name_size.y + text.hz_size.y + (GAP if labels == .BOTH else 0)}
    return
}

draw_named_peak :: proc(named: NamedPeak, pitch_standard: f32, labels: SpectrumLabels, background: gfx.Color) {
    text := peak_label_text(named.hz, pitch_standard, labels)
    bounds := named.bounds
    name_color, hz_color := text_color_light, text_color_muted
    name_color.a = u8(f32(name_color.a) * named.alpha)
    hz_color.a = u8(f32(hz_color.a) * named.alpha)

    draw_spectrum_label_pill(bounds, background, named.alpha)
    if text.name != nil {
        draw_label(pixel_fonts.band_label, text.name, {bounds.x + (text.size.x - text.name_size.x) / 2, bounds.y}, name_color)
    }
    if text.hz != nil {
        hz_y := bounds.y + bounds.height - text.hz_size.y
        draw_label(pixel_fonts.band_label_small, text.hz, {bounds.x + (text.size.x - text.hz_size.x) / 2, hz_y}, hz_color)
    }
}
