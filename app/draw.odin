package app

import rl "vendor:raylib"
import "core:strings"
import "core:fmt"
import "core:path/filepath"

// Root directory relative to this file
root_dir := filepath.dir(#file)

SHARP :: "♯"

font_atlas : cstring = "ABCDEFGHIJKLMNOPQRSTUVWYZabcdefghijklmnopqrstuwvxyzz♯♭/-1234567890.:"
font: rl.Font


init_drawing_context :: proc() {
    count := i32(0)
    codepoints := rl.LoadCodepoints(font_atlas, &count)
    defer rl.UnloadCodepoints(codepoints)

    path := filepath.join({root_dir, "../assets/NotoSansMono-Medium.ttf"})
    font_path := strings.clone_to_cstring(path)
    font = rl.LoadFontEx(font_path, 128, codepoints, count)
}


destroy_drawing_context :: proc() {
    rl.UnloadFont(font)
}


draw_note :: proc(note: Note, pos: [2]f32, size: f32, color: rl.Color = rl.PURPLE) {
    // Note name
    rl.DrawTextEx(font, fmt.ctprintf("%v", note.name), pos, size, 0, color)

    // Sharp sign
    if note.is_accidental {
        rl.DrawTextEx(font, SHARP, {pos.x+size/2, pos.y}, size/1.5, 0, color)
    }

    // Octave number
    rl.DrawTextEx(font, fmt.ctprintf("%v", note.octave), {pos.x+size/2, pos.y+size/2}, size/2.5, 0, color)
}


draw_autocorrelation :: proc(
    rect: rl.Rectangle,
    ac: ^AcConfig,
) {
    points: [FFT_SIZE]rl.Vector2 = {}

    start := 0 // enables me to move the start to zoom into a portion of the graph
    end := len(ac.autocorr)
    len := end - start

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(len - 1)

    x := rect.x
    gain: = 1.0 / ac.autocorr[0]

    for i in 0..<len {
        y := rect.y + (rect.height/2.0) - ac.autocorr[start+i] * (rect.height / 2.0) * gain
        points[i] = { x, y }
        x += px_per_sample
    }

    draw_time_plot(rect, len, 256)
    rl.DrawLineStrip(raw_data(points[:]), i32(len), rl.GOLD)

    // Mark peak positions with a cross
    for peak in ac.autocorr_peaks {
        val := ac.autocorr[peak] / ac.autocorr[0]
        rel_lag := f32(peak) - f32(start)

        cx := rect.x + rel_lag * f32(rect.width) / f32(len - 1)
        cy := rect.y + (rect.height/2.0) - val * (rect.height / 2.0)

        // Horizontal ruler
        rl.DrawLineEx({rect.x, cy}, {cx, cy}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.1f", val), {rect.x, cy}, 16, 0, rl.GRAY)

        // Vertical ruler
        rl.DrawLineEx({cx, cy}, {cx, rect.y+rect.height}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.1f", f32(peak)), {cx, rect.y+rect.height-16}, 16, 0, rl.GRAY)

        // X marker - cross
        rl.DrawLineEx({cx-7.0, cy}, {cx+7.0, cy}, 2.0, rl.PINK)
        rl.DrawLineEx({cx, cy-7.0}, {cx, cy+7.0}, 2.0, rl.PINK)
    }

    rl.DrawTextEx(font, fmt.ctprintf("%.2f",  ac.autocorr[0]), {rect.x, rect.y}, 16, 0, rl.BLUE)
}

draw_nsdf :: proc(
    rect: rl.Rectangle,
    ac: ^AcConfig,
    peak: Vec2,
) {
    points: [FFT_SIZE/2]rl.Vector2 = {}

    start := 0 // enables me to move the start to zoom into a portion of the graph
    end := len(ac.nsdf)
    len := end - start

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(len - 1)

    x := rect.x
    gain: = 1.0 / ac.nsdf[0]

    for i in 0..<len {
        y := rect.y + (rect.height/2.0) - ac.nsdf[start+i] * (rect.height / 2.0) * gain
        points[i] = { x, y }
        x += px_per_sample
    }

    draw_time_plot(rect, len, 100)
    rl.DrawLineStrip(raw_data(points[:]), i32(len), rl.GOLD)

    // Mark peak positions with a cross
    for peak, i in ac.nsdf_peaks {
        val := peak.y / ac.nsdf[0]
        rel_lag := f32(peak.x) - f32(start)

        cx := rect.x + rel_lag * f32(rect.width) / f32(len - 1)
        cy := rect.y + (rect.height/2.0) - val * (rect.height / 2.0)

        /*
        // Horizontal ruler
        rl.DrawLineEx({rect.x, cy}, {cx, cy}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.1f", val), {rect.x, cy}, 16, 0, rl.GRAY)

        // Vertical ruler
        rl.DrawLineEx({cx, cy}, {cx, rect.y+rect.height}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.1f", f32(peak.x)), {cx, rect.y+rect.height-16}, 16, 0, rl.GRAY)
        */

        // X marker - cross
        color := rl.GRAY
        if ac.chosen_peak_idx == i {
            color = rl.PINK
        }
        rl.DrawLineEx({cx-7.0, cy}, {cx+7.0, cy}, 2.0, color)
        rl.DrawLineEx({cx, cy-7.0}, {cx, cy+7.0}, 2.0, color)
    }

    rl.DrawTextEx(font, fmt.ctprintf("%.2f",  ac.nsdf[0]), {rect.x, rect.y}, 16, 0, rl.BLUE)
}

draw_cepstrum :: proc(
    rect: rl.Rectangle,
    buffer: []f32,
    lag: f32,
    val: f32,
) {
    points: [FFT_SIZE]rl.Vector2 = {}
    l := len(buffer) / 2

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(l - 1)

    x := rect.x

    for i in 0..<l {
        y := rect.y + (rect.height/2.0) - buffer[i] * (rect.height / 2.0)
        points[i] = { x, y }
        x += px_per_sample
    }

    draw_time_plot(rect, l, 100)
    rl.DrawLineStrip(raw_data(points[:]), i32(l), rl.GOLD)

    // Mark lag position with a cross
    cx := rect.x + lag * f32(rect.width) / f32(l - 1)
    cy := rect.y + (rect.height/2.0) - val * (rect.height / 2.0)

    rl.DrawLineEx({rect.x, cy}, {rect.x+rect.width, cy}, 0.5, rl.GRAY)
    rl.DrawLineEx({cx-7.0, cy}, {cx+7.0, cy}, 2.0, rl.PINK)
    rl.DrawLineEx({cx, cy-7.0}, {cx, cy+7.0}, 2.0, rl.PINK)
}


draw_time_plot :: proc(using rect: rl.Rectangle, len_samples: int, div_samples: int) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height/2}, {x+width, y+height/2}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "0", {x-16, y+height/2-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "-1", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every x samples
    px_per_sample := width / f32(len_samples)

    for d := 0; d < len_samples; d += div_samples {
        px := x + f32(d) * px_per_sample
        rl.DrawLineEx({px, y}, {px, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%v", d), {px, y+height+8}, 16, 0, rl.GRAY)
    }
    rl.DrawLineEx({x + width, y}, {x + width, y+height}, 0.5, rl.GRAY)
}


draw_freq_plot :: proc(using rect: rl.Rectangle, len_hz: f32, div_hz: f32) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "0", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every x Hz
    px_per_hz := f32(width) / len_hz

    for d := f32(0); d < len_hz; d += div_hz {
        px := x + d * px_per_hz
        rl.DrawLineEx({px, y}, {px, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.1fkHz", d/1000.0), {px, y+height+8}, 16, 0, rl.GRAY)
    }
}


draw_freq_spectrum :: proc(rect: rl.Rectangle, spectrum: []f32, fft_size: int, samplerate: int) {
    l := len(spectrum)

    // TODO: allocate on the heap ?
    spectrum_points: [MAX_SPECTRUM_DISPLAY_LEN]rl.Vector2 = {}

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(l - 1)
    x := rect.x

    for i in 0..<l {
        y := rect.y + rect.height - spectrum[i] * rect.height * 0.1 // HARDCODED gain
        spectrum_points[i] = { x, y }
        x += px_per_sample
    }

    bin_hz := f32(samplerate) / f32(fft_size)
    len_hz := f32(l) * bin_hz // number of bins * Hz covered by bin

    div_hz:f32 = 500.0 // show division every 0.5kHz

    draw_freq_plot(rect, len_hz, div_hz)
    rl.DrawLineStrip(raw_data(spectrum_points[:]), i32(l), rl.LIME)
}


// TODO: draw past good note/position greyed out if new pitch is not found
draw_note_meter :: proc (rect: rl.Rectangle, pitch_info: PitchInfo, cents_error: f32) {

    // outline for visual debugging
    // rl.DrawRectangleLinesEx(rect, 1.0, rl.ORANGE)

    if pitch_info.found {
        draw_note(pitch_info.detected_note, {rect.x + rect.width/2.0 - 20.0, rect.y}, 64)
        rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", pitch_info.detected_freq), {20, 450}, 24, 0, rl.GREEN)
    }

    px := rect.width / 100.0
    pos := rect.width/2 + cents_error * px

    // "needle"
    needle_width:f32 = 6.0
    needle_height: f32 = 24.0

    // horizontal line, ie "rail"
    rail_y := rect.y + rect.height - needle_height/2
    rl.DrawRectangleV({rect.x, rail_y - 2.0}, {rect.width, 4.0}, rl.GRAY)

    // vertical notches
    rl.DrawRectangleV({rect.x + rect.width/2.0 - 0.5, rail_y - 10.0}, {1.0, 20.0}, rl.GRAY)
    rl.DrawRectangleV({rect.x, rail_y - 10.0}, {1.0, 20.0}, rl.GRAY)
    rl.DrawRectangleV({rect.x + rect.width - 0.5, rail_y - 10.0}, {1.0, 20.0}, rl.GRAY)

    // draw needle
    if pitch_info.found {
        rl.DrawRectangleV(
            {rect.x + pos - needle_width/2.0, rect.y + rect.height - needle_height},
            {needle_width, needle_height},
            rl.ColorAlpha(rl.PURPLE, 1.0),
            // rl.ColorAlpha(rl.PURPLE, pitch_info.clarity),
        )
    }
}
