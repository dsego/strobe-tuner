package helpers

import "core:fmt"
import rl "vendor:raylib"

draw_samples :: proc(
    rect: rl.Rectangle,
    samples: []f32,
    color: rl.Color,
    gain: f32 = 1.0,
) {
    l := len(samples)
    points := make([]rl.Vector2, l)
    defer delete(points)

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(l - 1)

    x := rect.x
    for i in 0..<l {
        y := rect.y + (rect.height/2.0) - samples[i] * (rect.height / 2.0) * gain
        points[i] = { x, y }
        x += px_per_sample
    }
    rl.DrawLineStrip(raw_data(points), i32(l), color)
}

draw_time_plot :: proc(using rect: rl.Rectangle, len_samples: int, div_ms: f32, samplerate: int, font: rl.Font) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height/2}, {x+width, y+height/2}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "0", {x-16, y+height/2-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(font, "-1", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every X ms
    // eg sample rate = 44100, line every 9ms, 44100 * 0.009 = 396.9 samples
    div_samples := f32(samplerate) * div_ms * 0.001
    px_per_sample := f32(width) / f32(len_samples)
    px_per_div := px_per_sample * div_samples

    label_ms: f32= 0
    for d := f32(0); d < width; d += px_per_div {
        rl.DrawLineEx({x+d, y}, {x+d, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(font, fmt.ctprintf("%.0fms", label_ms), {x+d, y+height+8}, 16, 0, rl.GRAY)
        label_ms += div_ms
    }
}
