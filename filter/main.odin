package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:mem"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


import sdl "vendor:sdl2"
import ttf "vendor:sdl2/ttf"


import "../pffft"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100
SIZE :: 4096


AppContext :: struct {
    window: ^sdl.Window,
    renderer: ^sdl.Renderer,
    font: ^ttf.Font,
}

ctx := AppContext{}


samples: [SIZE]f32
// bq_filtered: [4][SIZE]f32
// fir_filtered: [4][SIZE]f32
magnitude_data: [SIZE*2]f32
filtered_signal: [SIZE*2]f32

filtered_cpx: [SIZE]complex64

impulse: [SIZE]f32
gauss: [SIZE]f32
// spectrum: [N]f32

decoder: ma.decoder

dft_filter :: proc() {

}

magnitude :: proc(re: f32, im: f32) -> f32 {
    return math.sqrt(re * re + im * im)
}

read_wav :: proc() {
    // path: cstring = "./media/ukulele_A3.wav"
    path: cstring = "./media/acoustic_A1.wav"
    // path: cstring = "./media/bass_A0.wav"
    // path: cstring = "./media/strat_A1.wav"
    config := ma.decoder_config_init(ma.format.f32, 1, 44100)
    if ma.decoder_init_file(path, &config, &decoder) != ma.result.SUCCESS {
        fmt.println("Failed to decode wav file '%s'.", path)
        return
    }
    defer ma.decoder_uninit(&decoder)

    frames_to_read : u64 = SIZE
    frames : [SIZE]f32
    frames_read: u64

    ma.decoder_seek_to_pcm_frame(&decoder, 1000)
    ma.decoder_read_pcm_frames(&decoder, raw_data(frames[:]), frames_to_read, &frames_read)


    for f, i in frames {
        samples[i] = f32(f)
    }
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

generate_averager :: proc(out_impulse: []f32) {
    taps := len(out_impulse)
    for i in 0..<taps {
        impulse[i] = 1.0 / f32(taps)
    }
}

gaussian :: proc(data: []f32, amp: f32, spread: f32) {
    len := f32(len(data))
    for d, i in data {
        x := f32(i) - len/2.0
        data[i] = amp * math.exp(-x * x / spread)
    }
}

init_sdl :: proc() -> (ok: bool) {
    if sdl_res := sdl.Init(sdl.INIT_VIDEO); sdl_res < 0 {
        log.errorf("sdl.Init returned %v.", sdl_res)
        return false
    }

    ctx.window = sdl.CreateWindow(
        "Filter",
        sdl.WINDOWPOS_CENTERED,
        sdl.WINDOWPOS_CENTERED,
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        {sdl.WindowFlag.ALLOW_HIGHDPI, sdl.WindowFlag.METAL}
    )
    if ctx.window == nil {
        log.errorf("sdl.CreateWindow failed.")
        return false
    }

    ctx.renderer = sdl.CreateRenderer(ctx.window, -1, {.ACCELERATED})
    if ctx.renderer == nil {
        log.errorf("sdl.CreateRenderer failed.")
        return false
    }

    info: sdl.RendererInfo
    sdl.GetRendererInfo(ctx.renderer, &info)
    fmt.println("Renderer: ", info.name)

    if ttf.Init() < 0 {
        log.errorf("ttf.Init failed")
        return false
    }
    ctx.font = ttf.OpenFont("./media/JetBrainsMono-Regular.ttf", 32)
    ttf.SetFontHinting(ctx.font, ttf.Hinting.LIGHT)

    return true
}

sdl_cleanup :: proc() {
    sdl.DestroyWindow(ctx.window)
    ttf.CloseFont(ctx.font)
    ttf.Quit()
    sdl.Quit()
}

main :: proc() {

    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Filter")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({rl.ConfigFlags.WINDOW_HIGHDPI})

    // if res := init_sdl(); !res {
    //     log.errorf("Initialization failed.")
    //     os.exit(1)
    // }
    // defer sdl_cleanup()


    read_wav()

    signal_dft: [SIZE*4]f32
    filter_dft: [SIZE*4]f32
    result_dft: [SIZE*4]f32
    zero_padded: [SIZE*2]f32




    // ----
    // for d, i in gauss {
    //     gauss[i] = 1
    // }
    // gaussian(gauss[:], 1, 4096)

    mem.copy(raw_data(zero_padded[:]), raw_data(samples[:]), len(samples))

    setup := pffft.new_setup(SIZE*2, pffft.Transform.REAL)
    defer pffft.destroy_setup(setup)

    pffft.transform_ordered(setup, raw_data(zero_padded[:]), raw_data(signal_dft[:]), nil, pffft.Direction.FORWARD)
    // pffft.zconvolve_accumulate(setup, raw_data(signal_dft[:]), raw_data(filter_dft[:]), raw_data(result_dft[:]), 1.0)
    // pffft.transform_ordered(setup, raw_data(result_dft[:]), raw_data(filtered_signal[:]), nil, pffft.Direction.BACKWARD)


    // ------


    // impulse: [SIZE]f32

    // run_filter(samples, impulse, filtered_signal)

    j := 0
    for m, i in magnitude_data {
        magnitude_data[i] = magnitude(signal_dft[j], signal_dft[j+1])
        j += 2
    }




    // for v, i in samples {
    //     buffer[i] = samples[i] * math.sin(f32(2.0 * math.PI * f32(i) * 110.0 / 44100.0))
    // }


    /*
        bq1 := biquad_init_resonator(110.0/44100.0, 5.0/44100.0, 1)

        biquad_process(&bq1, samples[:], bq_filtered[0][:])


        bq2 := biquad_init_resonator(220.0/44100.0, 5.0/44100.0, 1)

        biquad_process(&bq2, samples[:], bq_filtered[1][:])
    */



    // freq response of our filter impulse -> FFT
    // audio samples -> FFT
    // multiply FFTs and do inverse transform



    // low-pass frequency response, interleaved complex numbers
    // for i := 0; i < 256; i += 2 {
    //     freq_response[i] = 1
    //     freq_response[i+1] = 0
    // }



    // setup := pffft.new_setup(N, pffft.transform_t.REAL)
    // defer pffft.destroy_setup(setup)
    // pffft.transform_ordered(setup, raw_data(impulse[:]), raw_data(freq_response[:]), nil, pffft.Direction.FORWARD)

    // i := 0
    // j := 0
    // for i < 2*N-1 {
    //     spectrum[j] = magnitude(freq_response[i], freq_response[i+1])
    //     i += 2
    //     j += 1
    // }


    // fmt.println(freq_response)



    for !rl.WindowShouldClose() {
        draw_screen()
    }


    // main_loop: for {
    //     e: sdl.Event
    //     for sdl.PollEvent(&e) {
    //         #partial switch(e.type) {
    //         case .WINDOWEVENT:
    //             if (e.window.event == .CLOSE) do break main_loop
    //         case .QUIT:
    //             break main_loop
    //         case .KEYDOWN:
    //             #partial switch(e.key.keysym.sym) {
    //             case .ESCAPE:
    //                 break main_loop
    //             }
    //         }
    //     }
    //     draw_screen()
    // }
}

draw_samples :: proc(
    samples: []f32,
    x1: f32,
    y1: f32,
    width: f32,
    height: f32,
    color: rl.Color,
    gain: f32 = 1.0,
) {
    l := len(samples)
    points: []rl.Vector2

    // stretch samples to fit the box width
    resolution := f32(width) / f32(l -1)

    x := x1
    for i in 0..<l {
        // stretch to fit the box height and apply gain
        y := y1 + (height/2) - samples[i] * (height / 2) * gain
        points[i] = { x, y }
        x += resolution
    }
    rl.DrawLineStrip(raw_data(points[:]), i32(l), color)
}

draw_grid :: proc() {
    // DrawTextEx(Font font, const char *text, Vector2 position, float fontSize, float spacing, Color tint)
    // DrawLineEx(Vector2 startPos, Vector2 endPos, float thick, Color color)
}

draw_screen :: proc() {

    /*---
    sdl.SetRenderDrawColor(ctx.renderer, 0, 0, 0, 0xff)
    sdl.RenderClear(ctx.renderer)




    // font := sdl.OpenFont("./media/JetBrainsMono-Regular.ttf", 24, 254, 254)
    surface := ttf.RenderText_Solid(ctx.font, "Hello! :)", sdl.Color{250, 250, 250, 255})


    // defer free(surface)
    texture := sdl.CreateTextureFromSurface(ctx.renderer, surface)


    w :i32 = 0
    h :i32 = 0
    sdl.QueryTexture(texture, nil, nil, &w, &h)

    dst_rect := sdl.Rect{ 0, 0, w, h }
    // defer free(texture)

    sdl.RenderCopy(ctx.renderer, texture, nil, &dst_rect)


    l := len(samples)
    points: [SIZE]sdl.FPoint
    width := f32(SCREEN_WIDTH)

    // stretch samples to fit the box width
    resolution := width / f32(l -1)

    x :f32 = 100.0
    height: f32 = 100.0
    gain: f32 = 1.0
    for i in 0..<l {
        // stretch to fit the box height and apply gain
        y := f32(200.0 + (height/2) - samples[i] * (height / 2) * gain)
        points[i] = { x, y }
        x += resolution
    }
    sdl.SetRenderDrawColor(ctx.renderer, 255, 255, 255, 255)
    sdl.RenderDrawLinesF(ctx.renderer, raw_data(points[:]), i32(l))



    sdl.RenderPresent(ctx.renderer)

    ----*/

    // fmt.println(drift)
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.BLACK)

    // font := rl.LoadFontEx("./media/JetBrainsMono-Regular.ttf", 96, nil, 0)
    // rl.DrawTextEx(font, "free fonts included with raylib", rl.Vector2{250, 20}, 24, 2, rl.LIGHTGRAY);

    // draw_samples(samples[:SIZE], 0, 0, SCREEN_WIDTH, 100, rl.PINK, 2.0)

    // draw_samples(magnitude_data[:], 0, 110, SCREEN_WIDTH, 100, rl.ORANGE)
    // draw_samples(bq_filtered[0][:SIZE], 0, 110, SCREEN_WIDTH, 100, rl.ORANGE)
    // draw_samples(bq_filtered[1][:SIZE], 0, 230, SCREEN_WIDTH, 100, rl.SKYBLUE)


    // draw_samples(fir_filtered[0][:SIZE], 0, 340, SCREEN_WIDTH, 100, rl.YELLOW)
    // draw_samples(fir_filtered[1][:SIZE], 0, 450, SCREEN_WIDTH, 100, rl.YELLOW)
}
