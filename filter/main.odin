package filter

import "core:fmt"
import "core:log"
import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


import "../pffft"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100


AppContext :: struct {
    font: rl.Font,
    samples: []f32,
    filtered_samples: []f32,
    filter_config: NarrowBandpassFilter,
}

ctx := AppContext{}


read_wav :: proc(path: cstring, from: u64, to: u64, samples: []f32) {
    assert(from < to, "`from` should be smaller than `to`")
    assert(to <= u64(len(samples)), "`to` should be less or equal to samples length")

    decoder: ma.decoder
    config := ma.decoder_config_init(ma.format.f32, 1, 44100)
    if ma.decoder_init_file(path, &config, &decoder) != ma.result.SUCCESS {
        fmt.println("Failed to decode wav file '%s'.", path)
        return
    }
    defer ma.decoder_uninit(&decoder)

    frames_to_read : u64 = to - from

    ma.decoder_seek_to_pcm_frame(&decoder, 1000)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples[:]), frames_to_read, nil)
}

run_filter :: proc(samples: []f32, impulse: []f32, out: []f32) {
    taps := len(impulse)

    // naive, can optimize by leveraging symmetry
    for n in taps..<len(samples) {
        for k in 0..<taps {
            out[n] += samples[n-k] * impulse[k]
        }
    }
}

init_window :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Filter")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    ctx.font = rl.LoadFontEx("./media/JetBrainsMono-Regular.ttf", 64, nil, 0)
}

cleanup :: proc() {
    rl.CloseWindow()
    rl.UnloadFont(ctx.font)
}

main :: proc() {
    init_window()
    defer cleanup()

    // path: cstring = "./media/ukulele_A3.wav"
    // path: cstring = "./media/acoustic_A1.wav"
    // path: cstring = "./media/bass_A0.wav"
    path: cstring = "./media/strat_A1.wav"
    ctx.samples = make([]f32, 4096)
    ctx.filtered_samples = make([]f32, 4096)
    defer delete(ctx.samples)
    defer delete(ctx.filtered_samples)

    read_wav(path=path, from=0, to=4096, samples=ctx.samples[:])


    ctx.filter_config = filter_init(4096, f32(110)/f32(SAMPLERATE))
    defer filter_destroy(ctx.filter_config)

    filter_process(ctx.filter_config, ctx.samples, ctx.filtered_samples)

    for !rl.WindowShouldClose() {
        draw_screen()
    }
}

draw_samples :: proc(
    rect: rl.Rectangle,
    samples: []f32,
    color: rl.Color,
    gain: f32 = 1.0,
    thick: f32 = 1.0
) {
    l := len(samples)
    points := make([]rl.Vector2, l)
    defer delete(points)

    // stretch samples to fit the box width
    px_per_sample := f32(rect.width) / f32(l - 1)

    // fmt.println(px_per_sample)

    x := rect.x
    for i in 0..<l {
        y := rect.y + (rect.height/2.0) - samples[i] * (rect.height / 2.0) * gain
        points[i] = { x, y }
        x += px_per_sample
    }
    rl.DrawLineStrip(raw_data(points[:]), i32(l), color)

    // TODO:
    //  if pixel frequency > sample frequency, connect with lines
    //  if pixel freq < sample freq, calculate min-max sample in group & draw vertical line

    // rl.DrawTriangleStrip(raw_data(points[:]), i32(l), color)

    // for px in 0..<rect.width {
        // get the avg of samples
    // }

    // DrawCircleV(Vector2 center, thick, color)
}


draw_time_plot :: proc(using rect: rl.Rectangle, len_samples: int, div_ms: f32) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height/2}, {x+width, y+height/2}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "0", {x-16, y+height/2-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "-1", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every 10ms
    len_ms : f32 = 1000.0 * f32(len_samples) / f32(SAMPLERATE)
    px_per_ms := f32(width) / len_ms

    for d := f32(0); d < len_ms; d += div_ms {
        px := x + d * px_per_ms
        rl.DrawLineEx({px, y}, {px, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(ctx.font, fmt.ctprintf("%.0fms", d), {px, y+height+8}, 16, 0, rl.GRAY)
    }
}

draw_freq_plot :: proc(using rect: rl.Rectangle, len_points: int, div_hz: f32) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height/2}, {x+width, y+height/2}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "0", {x-16, y+height/2-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "-1", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every 10Hz
    len_hz : f32 = f32(SAMPLERATE/64)
    px_per_hz := f32(width) / len_hz

    for d := f32(0); d < len_hz; d += div_hz {
        px := x + d * px_per_hz
        rl.DrawLineEx({px, y}, {px, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(ctx.font, fmt.ctprintf("%.0fHz", d), {px, y+height+8}, 16, 0, rl.GRAY)
    }
}


draw_screen :: proc() {
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.BLACK)

    // SAMPLERATE
    rect := rl.Rectangle{50, 50, SCREEN_WIDTH-100, 200}
    div_ms := f32(1000.0 / 110.0)
    draw_time_plot(rect, len(ctx.samples), div_ms)
    draw_samples(rect, ctx.samples, rl.PINK, 2.0, 5.0)

    magnitude: [8192]f32
    for f, i in ctx.filter_config.zero_padded_dft {
        magnitude[i] = 0.01 * math.sqrt(real(f) * real(f) + imag(f) * imag(f))
    }

    rect2 := rl.Rectangle{50, 350, SCREEN_WIDTH-100, 200}
    draw_freq_plot(rect2, len(magnitude[:256]), 55)
    draw_samples(rect2, magnitude[:256], rl.LIME, 1.0, 1.0)
    // draw_samples(rect, ctx.filtered_samples, rl.LIME, 2.0, 5.0)

}
