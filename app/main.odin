package app

import rl "vendor:raylib"
import "core:fmt"
import "core:strings"

target_freq: f64

// running average to smooth out detected freq
detected_freq_avg: f32 = 1.0

main :: proc() {

    bass_freqs: []f64 = {
        41.20344, // E1
        55.00000,  // A1
        73.41619, // D2
        97.99886, // G2
    }

    guitar_freqs: []f64 = {
        82.40689, // E2
        110.0000, // A2
        146.8324, // D3
        195.9977, // G3
        246.9417, // B3
        329.6276, // E4
    }

    ukulele_freqs: []f64 = {
        391.9954, // G4
        261.6256, // C4
        329.6276, // E4
        440.0000, // A4
    }

    freqs_idx := 0

    freqs: []f64 = bass_freqs

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
    defer delete(new_samples)

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
        new_count := read_ringbuffer(&pitch_ringbuffer, new_samples, FFT_SIZE/2)

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
        detected_note_spectrum := find_note(detected_freq_spectrum)

        // fmt.println(detected_freq_spectrum)

        // detected_freq_hps := pitch_detect_hps(pitch)
        // detected_note_hps := find_note(detected_freq_hps)


        // aim at a double interval, to show more of the wave shape and slow down the strobe movement
        // TODO: pad fft for better precision, eg 4096 samples = 8192 padded fft size
        target_interval := 2.0 * f64(SAMPLERATE) / target_freq


        // limit to note range 20Hz - 8kHz
        flatness := spectral_flatness(pitch.spectrum[2:750])


        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            draw_strobe_display(target_interval, show_pattern)

            // fmt.println(target_freq, note)
            draw_note(&note, {20, 20}, 64)


            // run_strobe(strobe_band, )
            // fmt.println(note.name, note.semitone_index)
            // rl.DrawText("A1", 10, 10, 30, rl.PURPLE)


            // Show target frequency & interval
            rl.DrawTextEx(font, fmt.ctprintf("%.1fHz", target_freq), {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, fmt.ctprintf("%.2f", target_interval), {20, 150}, 16, 0, rl.SKYBLUE)


            // Detected note - auto correlation
            if freq_in_range(detected_freq_ac) {
                draw_note(&detected_note_ac, {20, 180}, 48)
                rl.DrawTextEx(font, fmt.ctprintf("%.1fHz", detected_freq_ac), {20, 230}, 24, 0, rl.PURPLE)
            }

            // cents_diff := freq_to_cents(detected_freq_ac) - f32(detected_note_ac.cents)
            // rl.DrawTextEx(font, fmt.ctprintf("%.1fc", cents_diff), {20, 260}, 24, 0, rl.ORANGE)

            draw_autocorrelation(rl.Rectangle{160, 180, SCREEN_WIDTH-180, 120}, &pitch, lag, val)

            // Spectrum
            if freq_in_range(detected_freq_spectrum) {
                draw_note(&detected_note_spectrum, {20, 350}, 48)
                rl.DrawTextEx(font, fmt.ctprintf("%.1fHz", detected_freq_spectrum), {20, 400}, 24, 0, rl.PURPLE)
            }

            draw_freq_spectrum(rl.Rectangle{160, 350, SCREEN_WIDTH-180, 120}, &pitch)
            draw_cepstrum(rl.Rectangle{160, 520, SCREEN_WIDTH-180, 120}, &pitch)


            // TODO: use the AC for detecting the fundamental, find the freq peak in that area and feed to the meter
            // draw_note_meter(rl.Rectangle{50, 500, 400, 100}, &detected_note_spectrum, detected_freq_spectrum)

            // rl.DrawTextEx(font, fmt.ctprintf("%.4f", flatness), {500, 500}, 24, 0, rl.PINK)
            // rl.DrawRectangleV({500, 550}, {100 * flatness, 4.0}, rl.PINK)



        }
    }
}


spectral_flatness :: proc (spectrum: []f32) -> f32 {
    flatness := geometric_mean(spectrum) / arithmetic_mean(spectrum)
    return flatness
}
