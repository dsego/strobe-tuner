package main

import "core:fmt"
import "core:mem"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"

import "../pffft"


SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
SAMPLERATE :: u32(48000)
SIZE :: 4096

samples: [SIZE]f32
// bq_filtered: [4][SIZE]f32
// fir_filtered: [4][SIZE]f32
magnitude_data: [SIZE*2]f32
filtered_signal: [SIZE*2]f32
points: [SIZE]rl.Vector2

filtered_cpx: [SIZE]complex64

impulse: [SIZE]f32
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

main :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({rl.ConfigFlags.WINDOW_HIGHDPI})

    read_wav()

    signal_dft: [SIZE*4]f32
    filter_dft: [SIZE*4]f32
    result_dft: [SIZE*4]f32
    zero_padded: [SIZE*2]f32


    goertzel := goertzel_init(110/44100)


    nwindow := u32(32)
    // Filter the data using a sliding window
    for n in 0..len(samples) - nwindow {
        filtered_cpx[n+nwindow/2] = goertzel_process(goertzel, samples[n:], nwindow)
    }

    for n in 0..<SIZE do filtered_signal[n] = 0.04 * real(filtered_cpx[n])

    // ----
    /*
    filter_dft[21] = 1.0
    // filter_dft[42] = 1.0
    // filter_dft[81] = 1.0
    // filter_dft[163] = 1.0

    mem.copy(raw_data(zero_padded[:]), raw_data(samples[:]), len(samples))

    setup := pffft.new_setup(SIZE*2, pffft.Transform.REAL)
    defer pffft.destroy_setup(setup)

    pffft.transform(setup, raw_data(zero_padded[:]), raw_data(signal_dft[:]), nil, pffft.Direction.FORWARD)
    pffft.zconvolve_accumulate(setup, raw_data(signal_dft[:]), raw_data(filter_dft[:]), raw_data(result_dft[:]), 1.0)
    pffft.transform_ordered(setup, raw_data(result_dft[:]), raw_data(filtered_signal[:]), nil, pffft.Direction.BACKWARD)
    // pffft.transform(setup, raw_data(signal_dft[:]), raw_data(filtered_signal[:]), nil, pffft.Direction.BACKWARD)
    */
    // ------


    // impulse: [SIZE]f32

    // run_filter(samples, impulse, filtered_signal)

    // j := 0
    // for m, i in magnitude_data {
    //     magnitude_data[i] = magnitude(fft[j], fft[j+1])
    //     j += 2
    // }




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

draw_screen :: proc() {
    // fmt.println(drift)
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.BLACK)

    rl.ClearBackground(rl.BLACK)

    // Draw grid lines
    dy := i32(50)
    for y := i32(0); y < SCREEN_HEIGHT; y += dy {
        rl.DrawLine(0, y, SCREEN_WIDTH, y, rl.DARKGRAY)
    }

    dx := i32(50)
    for x := i32(0); x < SCREEN_WIDTH; x += dx {
        rl.DrawLine(x, 0, x, SCREEN_HEIGHT, rl.DARKGRAY)
    }


    draw_samples(samples[:SIZE], 0, 0, SCREEN_WIDTH, 100, rl.PINK, 2.0)

    draw_samples(filtered_signal[:SIZE], 0, 110, SCREEN_WIDTH, 100, rl.ORANGE)
    // draw_samples(bq_filtered[0][:SIZE], 0, 110, SCREEN_WIDTH, 100, rl.ORANGE)
    // draw_samples(bq_filtered[1][:SIZE], 0, 230, SCREEN_WIDTH, 100, rl.SKYBLUE)


    // draw_samples(fir_filtered[0][:SIZE], 0, 340, SCREEN_WIDTH, 100, rl.YELLOW)
    // draw_samples(fir_filtered[1][:SIZE], 0, 450, SCREEN_WIDTH, 100, rl.YELLOW)
}
