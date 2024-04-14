// Testing autocorrelation


package ac

import "core:fmt"
import "core:log"
import "core:os"
import "core:math"
import "core:mem"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"

import "../../pffft"


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
    // path: cstring = "./media/acoustic_A2.wav"
    // path: cstring = "./media/bass_A1.wav"
    path: cstring = "./media/strat_A2.wav"

    samples := make([]f32, SAMPLE_COUNT)
    defer delete(samples)

    fft := make([]complex64, SAMPLE_COUNT)
    defer delete(fft)

    fft_conj_product := make([]complex64, SAMPLE_COUNT)
    defer delete(fft_conj_product)

    autocorrelation := make([]f32, SAMPLE_COUNT)
    defer delete(autocorrelation)

    read_wav(path=path, from=0, to=SAMPLE_COUNT, samples=samples)


    // Taking the FFT of the segment of interest,
    // multiplying it by its complex conjugate,
    // then taking the inverse FFT will give us the cyclic auto-correlation.

    pffft_setup := pffft.new_setup(SAMPLE_COUNT, pffft.Transform.REAL)

    pffft.transform_ordered(
        pffft_setup,
        raw_data(samples),
        raw_data(mem.slice_data_cast([]f32, fft)),
        nil,
        pffft.Direction.FORWARD
    )

    for i in 0..<len(fft) {
        fft_conj_product[i] = fft[i] * conj(fft[i])
    }

    pffft.transform_ordered(
        pffft_setup,
        raw_data(mem.slice_data_cast([]f32, fft_conj_product)),
        raw_data(autocorrelation),
        nil,
        pffft.Direction.BACKWARD
    )


    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rect := rl.Rectangle{20, 20, SCREEN_WIDTH-40, 300}
        div_ms := f32(1000.0 / 110.0)
        draw_time_plot(rect, len(samples), div_ms)
        draw_samples(rect, samples, rl.PINK, 1.0)
        draw_samples(rect, autocorrelation, rl.GOLD, 1.0/200000)
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
