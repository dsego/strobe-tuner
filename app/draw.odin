package app

import rl "vendor:raylib"
import "core:strings"
import "core:fmt"
import "core:path/filepath"

// Root directory relative to this file
root_dir := filepath.dir(#file)

sharp : cstring = "♯"
font_atlas := "ABCDEFGHz♯♭/-1234567890.ms"
font: rl.Font


init_drawing_context :: proc() {
    count := i32(0)
    codepoints := rl.LoadCodepoints(raw_data(font_atlas), &count)
    defer rl.UnloadCodepoints(codepoints)

    path := filepath.join({root_dir, "../assets/NotoSansMono-Medium.ttf"})
    font_path := strings.clone_to_cstring(path)
    font = rl.LoadFontEx(font_path, 128, codepoints, count)
}


destroy_drawing_context :: proc() {
    rl.UnloadFont(font)
}

draw_note :: proc(note: ^Note) {
    if note.is_accidental {
        rl.DrawTextEx(font, cstring(&note.name), {20, 20}, 64, 0, rl.PURPLE)
        rl.DrawTextEx(font, sharp, {50, 20}, 32, 0, rl.PURPLE)
        rl.DrawTextEx(font, sharp, {50, 20}, 32, 0, rl.PURPLE)
    } else {
        rl.DrawTextEx(font, cstring(&note.name), {20, 20}, 64, 0, rl.PURPLE)
    }
}


points: [4096]rl.Vector2 = {}

draw_autocorrelation :: proc(
    rect: rl.Rectangle,
    pitch_config: ^PitchConfig,
    lag: f32,
    val: f32,
) {

    l := len(pitch_config.autocorrelation)

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(l - 1)

    x := rect.x
    gain: = 1.0 / pitch_config.autocorrelation[0]

    for i in 0..<l {
        y := rect.y + (rect.height/2.0) - pitch_config.autocorrelation[i] * (rect.height / 2.0) * gain
        points[i] = { x, y }
        x += px_per_sample
    }

    draw_time_plot(rect, l, 9.0)
    rl.DrawLineStrip(raw_data(points[:]), i32(l), rl.GOLD)

    // Mark lag position with a cross
    cx := rect.x + lag * f32(rect.width) / f32(l - 1)
    cy := rect.y + (rect.height/2.0) - val * (rect.height / 2.0)

    rl.DrawLineEx({rect.x, cy}, {rect.x+rect.width, cy}, 0.5, rl.GRAY)
    rl.DrawLineEx({cx-7.0, cy}, {cx+7.0, cy}, 2.0, rl.PINK)
    rl.DrawLineEx({cx, cy-7.0}, {cx, cy+7.0}, 2.0, rl.PINK)
}


draw_time_plot :: proc(using rect: rl.Rectangle, len_samples: int, div_ms: f32) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height/2}, {x+width, y+height/2}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "0", {x-16, y+height/2-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "-1", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every x ms
    len_ms : f32 = 1000.0 * f32(len_samples) / f32(SAMPLERATE)
    px_per_ms := f32(width) / len_ms

    for d := f32(0); d < len_ms; d += div_ms {
        px := x + d * px_per_ms
        rl.DrawLineEx({px, y}, {px, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.0fms", d), {px, y+height+8}, 16, 0, rl.GRAY)
    }
}
