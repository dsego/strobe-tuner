package app

import rl "vendor:raylib"
import "core:fmt"
import "core:strings"

target_freq: f64


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

    freqs: []f64 = guitar_freqs

    target_freq = freqs[0]
    target_interval := 0.0

    // target_freq = 2500
    // target_freq = 88
    // target_freq = 1567.982
    // target_freq = 7902.133

    // target_freq = 440.0000 // A
    // target_freq = 329.6276 // E
    // target_freq = 261.6256 // C
    // target_freq = 391.9954 // G


    init_strobes(target_freq / SAMPLERATE)

    smooth_conf := init_smoothing(30)

    ok := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture()

    ac := ac_init(FFT_SIZE, SAMPLERATE)
    defer ac_destroy(&ac)

    // spectrum := spectrum_init(FFT_SIZE, SAMPLERATE)
    // defer spectrum_destroy(&spectrum)

    cepstrum := ceps_init(FFT_SIZE, SAMPLERATE)
    defer ceps_destroy(&cepstrum)

    samples: []f32 = make([]f32, FFT_SIZE/2)
    defer delete(samples)

    new_samples: []f32 = make([]f32, FFT_SIZE/2)
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
    ac_lowpass := false

    // detected_freq_spectrum: f32
    // detected_note_spectrum: Note

    detected_freq_ac: f32
    ac_confidence: f32
    detected_note_ac: Note
    ac_lag: f32
    ac_val: f32

    // flatness: f32


    // detected_freq_ceps: f32
    // detected_note_ceps: Note
    // ceps_lag: f32
    // ceps_val: f32

    freq_estimate:f32 = 260.0
    freq_estimate_error:f32 = 0.5

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

        if freq_changed {
            freqs_idx %= len(freqs)
            if freqs_idx < 0 do freqs_idx += len(freqs) // wrap around
            reset_framerate()
        }

        // Pitch detection, use the first ringbuffer
        // TODO: run in a loop until all samples in ringbuffer are exhausted???
        // 44100 / 60fps = 735 samples, is 1000 a safe bet?
        new_count := read_ringbuffer(&pitch_ringbuffer, new_samples, 1000)

        if new_count > 0 {

            // move old samples back to make room for new samples
            copy(samples, samples[new_count:])

            // copy over new samples into the freed space
            copy(samples[u32(len(samples))-new_count:], new_samples[:new_count])

            // TODO: filter out high frequencies before autocorrelation?
            detected_freq_ac, ac_confidence = ac_pitch_detect(&ac, samples)

            detected_note_ac = find_note(detected_freq_ac)

            // Assume 1Hz error
            // freq_estimate, freq_estimate_error = kalman_filter(detected_freq_ac, freq_estimate, freq_estimate_error, 0.3)


            // fmt.println(freq_estimate)


            // Find spectrum peak
            // detected_freq_spectrum = spectrum_pitch_detect(&spectrum, samples)
            // detected_note_spectrum = find_note(detected_freq_spectrum)


            // limit to note range 20Hz - 8kHz
            // flatness = spectral_flatness(spectrum.spectrum[2:750])

            // Cepstrum
            // detected_freq_ceps, ceps_lag, ceps_val = ceps_pitch_detect(&cepstrum, samples)
            // detected_note_ceps = find_note(detected_freq_ceps)

            // if target_freq != f64(detected_note_ac.frequency) {
            //     reset_framerate()
            //     target_freq = f64(detected_note_ac.frequency)

            //     // for strobe aim at a double interval, to show more of the wave shape and slow down the strobe movement
            //     target_interval = 2.0 * f64(SAMPLERATE) / target_freq
            // }

        }

        target_freq = freqs[freqs_idx]
        note := find_note(f32(target_freq))

        // for strobe aim at a double interval, to show more of the wave shape and slow down the strobe movement
        target_interval = 2.0 * f64(SAMPLERATE) / target_freq

        // TODO: change to something meaningful
        target_interval = min(max(target_interval, 1), 1000)

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            rl.DrawFPS(700, 20)

            draw_strobe_display(target_interval, show_pattern)
            draw_note(&note, {20, 20}, 64)


            // Show target frequency & interval
            rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", target_freq), {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, fmt.ctprintf("%.2f", target_interval), {20, 150}, 16, 0, rl.SKYBLUE)


            // Detected note - auto correlation
            if freq_in_range(detected_freq_ac) {
                draw_note(&detected_note_ac, {20, 250}, 48)
                rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", detected_freq_ac), {20, 300}, 24, 0, rl.PURPLE)
            }

            // cents_diff := freq_to_cents(detected_freq_ac) - f32(detected_note_ac.cents)
            // rl.DrawTextEx(font, fmt.ctprintf("%.1fc", cents_diff), {20, 260}, 24, 0, rl.ORANGE)

            // draw_autocorrelation(rl.Rectangle{160, 180, SCREEN_WIDTH-180, 120}, ac.autocorr, ac_lag, ac_val)
            draw_autocorrelation(rl.Rectangle{160, 180, SCREEN_WIDTH-180, 250}, ac.autocorr[:], &ac)

            // Spectrum
            // if freq_in_range(detected_freq_spectrum) {
            //     draw_note(&detected_note_spectrum, {20, 500}, 48)
            //     rl.DrawTextEx(font, fmt.ctprintf("%.1fHz", detected_freq_spectrum), {20, 550}, 24, 0, rl.PURPLE)
            // }

            // draw_freq_spectrum(rl.Rectangle{160, 500, SCREEN_WIDTH-180, 120}, spectrum.spectrum[:200], FFT_SIZE, SAMPLERATE)

            // draw_cepstrum(rl.Rectangle{160, 500, SCREEN_WIDTH-180, 120}, cepstrum.cepstrum[:200], ceps_lag, ceps_val)

            // Cepstrum
            // if freq_in_range(detected_freq_ceps) {
            //     draw_note(&detected_note_ceps, {20, 500}, 48)
            //     rl.DrawTextEx(font, fmt.ctprintf("%.1fHz", detected_freq_ceps), {20, 550}, 24, 0, rl.PURPLE)
            // }

            // TODO: use the AC for detecting the fundamental, find the freq peak in that area and feed to the meter
            draw_note_meter(rl.Rectangle{400, 500, 400, 100}, &detected_note_ac, detected_freq_ac)
            // draw_note_meter(rl.Rectangle{400, 600, 400, 100}, &detected_note_ac, freq_estimate)

            // rl.DrawTextEx(font, fmt.ctprintf("%.4f", flatness), {20, 620}, 24, 0, rl.PINK)
            // rl.DrawRectangleV({20, 650}, {100 * flatness, 4.0}, rl.PINK)

            rl.DrawTextEx(font, fmt.ctprintf("%.4f", ac_val), {20, 660}, 24, 0, rl.LIME)
            rl.DrawRectangleV({20, 690}, {100 * ac_val, 4.0}, rl.LIME)
        }
    }
}

