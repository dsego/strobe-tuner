package resonator

import "core:fmt"
import "core:log"
import "core:os"
import "core:math"
import "core:mem"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"

import "../resonator"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100
SAMPLE_COUNT :: 2048


AppContext :: struct {
    font: rl.Font,
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
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples), frames_to_read, nil)
}

init :: proc() {
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
    init()
    defer cleanup()

    // path: cstring = "./media/ukulele_A4.wav"
    path: cstring = "./media/acoustic_A2.wav"
    // path: cstring = "./media/bass_A0.wav"
    // path: cstring = "./media/strat_A2.wav"

    samples := make([]f32, SAMPLE_COUNT)
    defer delete(samples)

    // read_wav(path=path, from=0, to=SAMPLE_COUNT, samples=samples)

    samples_1 := make([]f32, SAMPLE_COUNT)
    defer delete(samples_1)

    samples_2 := make([]f32, SAMPLE_COUNT)
    defer delete(samples_2)

    samples_3 := make([]f32, SAMPLE_COUNT)
    defer delete(samples_3)

    samples_4 := make([]f32, SAMPLE_COUNT)
    defer delete(samples_4)


    band_1 := make([]f32, SAMPLE_COUNT)
    defer delete(band_1)

    band_2 := make([]f32, SAMPLE_COUNT)
    defer delete(band_2)

    band_3 := make([]f32, SAMPLE_COUNT)
    defer delete(band_3)

    band_4 := make([]f32, SAMPLE_COUNT)
    defer delete(band_4)


    phase := f32(0.0)


    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {
            phase -= math.PI / 8.0
        }
        else if rl.IsKeyDown(rl.KeyboardKey.LEFT) {
            phase += math.PI / 8.0
        }
        for i in 0..<SAMPLE_COUNT {
            samples_1[i] = 0.5 * math.sin(phase + (2.0 * math.PI * 55.0) * f32(i) / SAMPLERATE)
            samples_2[i] = 0.5 * math.sin(phase + (2.0 * math.PI * 110.0) * f32(i) / SAMPLERATE)
            samples_3[i] = 0.2 * math.sin(phase + (2.0 * math.PI * 220.0) * f32(i) / SAMPLERATE)
            samples_4[i] = 0.2 * math.sin(phase + (2.0 * math.PI * 440.0) * f32(i) / SAMPLERATE)
            samples[i] = (
                samples_1[i] +
                samples_2[i] +
                samples_3[i] +
                samples_4[i]
            )
        }

        res_1 := biquad_resonator(55.0 / SAMPLERATE, 5.0 / SAMPLERATE)
        res_2 := biquad_resonator(110.0 / SAMPLERATE, 20.0 / SAMPLERATE)
        res_3 := biquad_resonator(220.0 / SAMPLERATE, 50.0 / SAMPLERATE)
        res_4 := biquad_resonator(440.0 / SAMPLERATE, 100.0 / SAMPLERATE)


        biquad_process(&res_1, samples, band_1)
        biquad_process(&res_2, samples, band_2)
        biquad_process(&res_3, samples, band_3)
        biquad_process(&res_4, samples, band_4)


        rect := rl.Rectangle{20, 20, SCREEN_WIDTH-40, 100}
        div_ms := f32(1000.0 / 110.0)
        draw_time_plot(rect, len(samples), div_ms)
        draw_samples(rect, samples, rl.PINK, 1.0)

        rect = rl.Rectangle{20, 150, SCREEN_WIDTH-40, 100}
        draw_time_plot(rect, len(samples), div_ms)
        draw_samples(rect, samples_1, rl.VIOLET, 1.0)
        draw_samples(rect, band_1, rl.GOLD, 5.0)

        rect = rl.Rectangle{20, 300, SCREEN_WIDTH-40, 100}
        draw_time_plot(rect, len(samples), div_ms)
        draw_samples(rect, samples_2, rl.VIOLET, 1.0)
        draw_samples(rect, band_2, rl.GOLD, 1.0)

        rect = rl.Rectangle{20, 450, SCREEN_WIDTH-40, 100}
        draw_time_plot(rect, len(samples), div_ms)
        draw_samples(rect, samples_3, rl.VIOLET, 1.0)
        draw_samples(rect, band_3, rl.GOLD, 1.0)

        rect = rl.Rectangle{20, 600, SCREEN_WIDTH-40, 100}
        draw_time_plot(rect, len(samples), div_ms)
        draw_samples(rect, samples_4, rl.VIOLET, 1.0)
        draw_samples(rect, band_4, rl.GOLD, 1.0)

    }
}

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

    // fmt.println(px_per_sample)

    x := rect.x
    for i in 0..<l {
        y := rect.y + (rect.height/2.0) - samples[i] * (rect.height / 2.0) * gain
        points[i] = { x, y }
        x += px_per_sample
    }
    rl.DrawLineStrip(raw_data(points), i32(l), color)
}


draw_time_plot :: proc(using rect: rl.Rectangle, len_samples: int, div_ms: f32) {
    // Horizontal lines at 1,0,-1
    rl.DrawLineEx({x, y}, {x+width, y}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "1", {x-16, y-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height/2}, {x+width, y+height/2}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "0", {x-16, y+height/2-8}, 16, 0, rl.GRAY)

    rl.DrawLineEx({x, y+height}, {x+width, y+height}, 0.5, rl.GRAY)
    rl.DrawTextEx(ctx.font, "-1", {x-24, y+height-8}, 16, 0, rl.GRAY)

    // Vertical lines every x ms
    len_ms : f32 = 1000.0 * f32(len_samples) / f32(SAMPLERATE)
    px_per_ms := f32(width) / len_ms

    for d := f32(0); d < len_ms; d += div_ms {
        px := x + d * px_per_ms
        rl.DrawLineEx({px, y}, {px, y+height}, 0.5, rl.GRAY)
        rl.DrawTextEx(ctx.font, fmt.ctprintf("%.0fms", d), {px, y+height+8}, 16, 0, rl.GRAY)
    }
}
