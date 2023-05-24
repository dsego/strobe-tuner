package main

import "core:fmt"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"

import "../pffft"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: u32(48000)
SIZE :: 4096

samples: [SIZE]f32
samples_filtered: [SIZE]f32
points: [SIZE]rl.Vector2

impulse: [SIZE]f32
// spectrum: [N]f32

decoder: ma.decoder

dft_filter :: proc() {

}



magnitude :: proc(re: f32, im: f32) -> f32 {
    return math.sqrt(re * re + im * im)
}




// TODO: kaiser, chebyshev
// Applies the Blackman window to a set of samples
blackman_window :: proc(buffer: []f32) {
    N := f32(len(buffer))
    for d, i in buffer {
        k := f32(i)
        buffer[i] *= (
            0.42 - 0.5 * math.cos(2.0 * math.PI * k / (N-1)) +
            0.08 * math.cos(4.0 * math.PI * k / (N-1))
        )
    }
}


// For FIR filters, the impulse response is equivalent to filter coefficients
generate_lowpass_impulse :: proc(
    out_impulse: []f32
    center_freq: f32,
    cutoff_freq: f32,
    samplerate: f32,
) {

    // Algebraic expression: h(k) = ( 1 / N ) (sin(πk K / N) / sin(πk / N))
    K := cutoff_freq
    N := samplerate

    taps := u32(len(out_impulse))

    // low-pass magnitude response
    out_impulse[taps/2] = K / N
    for k := u32(1); k < taps/2; k+=1 {
        out_impulse[taps/2+k] = math.sin(math.PI * f32(k) * K / N) / (math.PI * f32(k) / N) / N
        // out_impulse[taps/2+k] = math.sin(math.PI * f32(k) * K / N) / math.sin(math.PI * f32(k) / N) / N
        out_impulse[taps/2-k] = out_impulse[taps/2+k]
    }
    // for k := u32(0); k < taps; k+=1 {
    //     shifted_sinusoid := math.sin(math.PI * f32(k) * samplerate / center_freq)
    //     out_impulse[k] *= shifted_sinusoid
    // }

    // fmt.println(out_impulse[taps/2+1])
    // fmt.println(out_impulse[taps/2+2])
}






read_wav :: proc() {
    // path: cstring = "./media/acoustic_A1.wav"
    path: cstring = "./media/strat_A1.wav"
    config := ma.decoder_config_init(ma.format.f32, 1, 44100)
    if ma.decoder_init_file(path, &config, &decoder) != ma.result.SUCCESS {
        fmt.println("Failed to decode wav file '%s'.", path)
        return
    }
    defer ma.decoder_uninit(&decoder)

    frames_to_read : u64 = SIZE
    frames : [SIZE]f32
    frames_read: u64
    ma.decoder_read_pcm_frames(&decoder, raw_data(frames[:]), frames_to_read, &frames_read)


    for f, i in frames {
        samples[i] = f32(f)
    }
}

run_filter :: proc(samples: []f32, impulse: []f32, out: []f32) {
    taps := len(impulse)
    for n in taps..<len(samples) {
        for k in 0..<taps {
            samples_filtered[n] += samples[n-k] * impulse[k]
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

    // num_taps := u32(255)
    // generate_lowpass_impulse(
    //     out_impulse=impulse[:num_taps],
    //     center_freq=440,
    //     cutoff_freq=10,
    //     samplerate=44100,
    // )
    // blackman_window(impulse[:num_taps])


    bq := biquad_init_resonator(110.0/44100.0, 5.0/44100.0)

    fmt.println(bq)
    biquad_process(&bq, samples[:], samples_filtered[:])
    // fmt.println(samples_filtered)



    // run_filter(samples[:], impulse[:num_taps], samples_filtered[:])




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
    // pffft.transform_ordered(setup, raw_data(impulse[:]), raw_data(freq_response[:]), nil, pffft.direction_t.FORWARD)

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
    color: rl.Color
) {
    l := len(samples)

    // find max
    max := f32(0)
    for i in 0..<l {
        abs := math.abs(samples[i])
        if abs > max do max = abs
    }
    // stretch to fit the box height
    gain := (height / 2) / max

    // stretch samples to fit the box width
    resolution := f32(width) / f32(l -1)

    x := x1
    for i in 0..<l {
        y := y1 + (height/2) - samples[i] * gain
        points[i] = { x, y }
        x += resolution
    }
    rl.DrawRectangleLines(i32(x1), i32(y1), i32(width), i32(height), rl.DARKGRAY)
    rl.DrawLineStrip(raw_data(points[:]), i32(l), color)
}

draw_screen :: proc() {
    // fmt.println(drift)
    rl.BeginDrawing()
    defer rl.EndDrawing()

    frame_count: u32 = 4096
    rl.ClearBackground(rl.BLACK)

    draw_samples(samples[:frame_count], 0, 0, SCREEN_WIDTH, 200, rl.PINK)

    draw_samples(impulse[:], 0, 210, SCREEN_WIDTH, 200, rl.ORANGE)
    draw_samples(samples_filtered[:frame_count], 0, 420, SCREEN_WIDTH, 200, rl.ORANGE)
}
