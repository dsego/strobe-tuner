package app

import rl "vendor:raylib"
import "core:fmt"
import "core:strings"


// Simplify by using a constant number of ringbuffers instead of a dynamic list.
// NOTE: Needs to be a power of 2 for portaudio ring buffers!
DEFAULT_RB_SIZE :: 65536

STROBE_COUNT :: 1

// FFT size for pitch detection
FFT_SIZE :: 4096

SAMPLERATE :: 44100
SAMPLE_SIZE :: 2048

SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768



target_freq: f64

// running average to smooth out detected freq
detected_freq_avg: f32 = 1.0


main :: proc() {

    guitar_freqs: []f64 = {
        82.40689, // E
        110.0000, // A
        146.8324, // D
        195.9977, // G
        246.9417, // B
        329.6276, // E
    }

    ukulele_freqs: []f64 = {
        391.9954, // G
        261.6256, // C
        329.6276, // E
        440.0000, // A
    }

    freqs_idx := 0

    freqs: []f64 = ukulele_freqs

    target_freq = freqs[0]


    // target_freq = 2500
    // target_freq = 88
    // target_freq = 1567.982
    // target_freq = 7902.133

    // target_freq = 440.0000 // A
    // target_freq = 329.6276 // E
    // target_freq = 261.6256 // C
    // target_freq = 391.9954 // G


    init_strobes(target_freq / SAMPLERATE)

    smooth_conf := init_smoothing(10)

    ok := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture()

    pitch := pitch_init(FFT_SIZE, SAMPLERATE)
    defer pitch_destroy(pitch)

    samples: []f32 = make([]f32, FFT_SIZE)
    new_samples: []f32 = make([]f32, FFT_SIZE)
    defer delete(samples)

    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    init_drawing_context()
    defer destroy_drawing_context()


    init_strobe_display()
    defer destroy_strobe_display()



    show_pattern := false

    for !rl.WindowShouldClose() {


        // Toggle between scope view and strobe view
        if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
            show_pattern = !show_pattern
        }


        freq_changed := false

        // Pick next or previous ukulele string
        if rl.IsKeyPressed(rl.KeyboardKey.RIGHT) {
            freqs_idx += 1
            freq_changed = true
        }
        if rl.IsKeyPressed(rl.KeyboardKey.LEFT) {
            freqs_idx -= 1
            freq_changed = true
        }

        if (freq_changed) {
            freqs_idx %= len(freqs)
            if freqs_idx < 0 do freqs_idx += len(freqs) // wrap around
            reset_framerate()
        }


        // Pitch detection, use the first ringbuffer
        new_count := read_ringbuffer(&pitch_ringbuffer, new_samples, FFT_SIZE/2, 1)

        if new_count > 0 {

            // move old samples back to make room for new samples
            copy(samples, samples[new_count:])

            // copy over new samples into the freed space
            copy(samples[FFT_SIZE-new_count:], new_samples[:new_count])

        }


        // TODO: no need to run pitch detect if samples haven't changed
        detected_freq_ac, lag, val := pitch_detect_ac(pitch, samples)
        detected_note_ac := find_note(detected_freq_ac)

        // TODO: Smooth out the detected freq?
        // detected_freq_avg = smooth(&smooth_conf, detected_freq_ac)


        target_freq = freqs[freqs_idx]
        note := find_note(f32(target_freq))


        // Find spectrum peak
        detected_freq_spectrum := pitch_detect_spectrum(pitch, samples)

        // fmt.println(detected_freq_spectrum)

        detected_freq_hps := pitch_detect_hps(pitch)
        detected_note_spectrum := find_note(detected_freq_spectrum)
        detected_note_hps := find_note(detected_freq_hps)


        // aim at a double interval, to show more of the wave shape and slow down the strobe movement
        target_interval := 2.0 * f64(SAMPLERATE) / target_freq

        frame_count, drift := read_samples(
            rb_ptr=&strobe_ringbuffer,
            samples=strobe_samples[:],
            target_interval=target_interval,
        )



        load_strobe_texture(frame_count)
        defer unload_strobe_texture()

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            draw_strobes(
                target_interval,
                drift,
                frame_count,
                show_pattern,
            )

            // fmt.println(target_freq, note)
            draw_note(&note, {20, 20}, 64)


            // run_strobe(strobe_band, )
            // fmt.println(note.name, note.semitone_index)

            // rl.DrawText("A1", 10, 10, 30, rl.PURPLE)




            // Show target frequency & interval

            formatted_freq := strings.clone_to_cstring(fmt.aprintf("%.1fHz", target_freq))
            formatted_interval := strings.clone_to_cstring(fmt.aprintf("%.2f", target_interval))
            rl.DrawTextEx(font, formatted_freq, {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, formatted_interval, {20, 150}, 16, 0, rl.SKYBLUE)


            // Detected note - auto correlation
            draw_note(&detected_note_ac, {20, 180}, 48)
            formatted_detected_freq := strings.clone_to_cstring(fmt.aprintf("%.1fHz", detected_freq_ac))
            rl.DrawTextEx(font, formatted_detected_freq, {20, 230}, 24, 0, rl.PURPLE)


            cents_diff := freq_to_cents(detected_freq_ac) - f32(detected_note_ac.cents)
            formatted_cents_diff := strings.clone_to_cstring(fmt.aprintf("%.1fc", cents_diff))
            rl.DrawTextEx(font, formatted_cents_diff, {20, 260}, 24, 0, rl.ORANGE)

            draw_autocorrelation(
                rl.Rectangle{160, 180, SCREEN_WIDTH-180, 160},
                &pitch,
                lag,
                val
            )


            // Spectrum
            draw_note(&detected_note_spectrum, {20, 400}, 48)
            detected_freq_spectrum_str := strings.clone_to_cstring(fmt.aprintf("%.1fHz", detected_freq_spectrum))
            rl.DrawTextEx(font, detected_freq_spectrum_str, {20, 450}, 24, 0, rl.PURPLE)

            // HPS
            draw_note(&detected_note_hps, {20, 500}, 48)
            detected_freq_hps_str := strings.clone_to_cstring(fmt.aprintf("%.1fHz", detected_freq_spectrum))
            rl.DrawTextEx(font, detected_freq_hps_str, {20, 550}, 24, 0, rl.PURPLE)


            // TODO: draw in log format
            draw_freq_spectrum(rl.Rectangle{160, 400, SCREEN_WIDTH-180, 160}, &pitch)


            // window: [100]rl.Vector2 = {}
            // for i in 0..<100 {
            //     // window[i] = blackman_harris(f32(i), f32(100))
            //     window[i] = { f32(40 + i), 700 - 100.0 * blackman_harris(f32(i), f32(100))}
            // }
            // // fmt.println(window)
            // rl.DrawLineStrip(raw_data(window[:]), 100, rl.BLUE)

        }
    }
}



