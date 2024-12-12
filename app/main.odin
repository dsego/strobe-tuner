package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

import "../core"
import rl "vendor:raylib"


main :: proc() {
    target_freq_hz: f32 = 110.0

    freq_changed_manually := true
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}
    detected_note := core.Note{}
    selected_note := core.Note{}

    timestamp := time.now()


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    phase_tracker := core.init_phase_tracker(
        target_freq_hz,
        f32(config.samplerate),
        config.strobe_count,
        config.strobe_window_size,
        config.strobe_mode,
    )
    defer core.destroy_phase_tracker(phase_tracker)

    phase_tracker_display := init_phase_tracker_display()
    defer destroy_phase_tracker_display(&phase_tracker_display)


    pitch_detector := core.init_pitch_detector(config.samplerate, config.pitch_detect_fft_size)
    defer core.destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(u32(config.samplerate))
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    init_drawing_context()
    defer destroy_drawing_context()

    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, phase_tracker)
    start_audio_capture(audio_capture)

    core.set_phase_tracker_freq(phase_tracker, target_freq_hz)


    measured_freq: f32 = 0.0
    measured_cents: f32 = 0.0

    phase_points: [1024]rl.Vector2 = {}

    for !rl.WindowShouldClose() {
        // seconds_elapsed := time.duration_seconds(time.since(timestamp))

        // refresh_measurements := false
        // if seconds_elapsed > 0.1 {
        //     refresh_measurements = true
        //     timestamp = time.now()
        // }

        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // Keep previous measurement if there is no detected note
        if core.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                target_freq_hz = pitch_info.detected_note.frequency
                core.set_phase_tracker_freq(phase_tracker, target_freq_hz)
            }
            freq_estimation_active = true
            // core.reset_ewma(&cents_ewma)
            // core.reset_ewma(&freq_ewma)
        }

        if core.is_weak_pitch(pitch_info) {
            freq_estimation_active = false
        }

        // prev_note := core.prev_note_in_scale(detected_note)
        // prev_note_2 := core.prev_note_in_scale(prev_note)
        // next_note := core.next_note_in_scale(detected_note)
        // next_note_2 := core.next_note_in_scale(next_note)
        core.run_dft_analysis(phase_tracker)


        // TODO

        // keep track of previous N phases ---->  only calculate phase diff every X refresh_measurements


        //  ring buffer on display tracker to store all phases from band zero
        //      phase_buffer
        //  I can then optionally display this buffer as a tracking line

        // ---- can even draw all the phase measurements as a graph
        // -- instead of just the note names draw a "ruler" with dashes and notes, and a line

        // eg phase in time x - phase in time y = phase diff -> cents offset

        // this should happen in the phase tracker bands, eg refresh this 10 times a second, meaning cca every 4k samples

        // measured_phase = phase_tracker.bands[0].phase


        // if refresh_measurements && freq_estimation_active {
        //     measured_freq = phase_tracker.bands[0].estimated_freq_hz
        //     measured_cents = phase_tracker.bands[0].err_cents
        //     freq_smooth = core.ewma_filter(&freq_ewma, measured_freq)
        //     cents_err_smooth = core.ewma_filter(&cents_ewma, measured_cents)
        // }

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            draw_phase_tracker_display(&phase_tracker_display, phase_tracker)
            draw_note(
                detected_note,
                {280, 340},
                96,
                rl.WHITE if freq_estimation_active else rl.GRAY,
            )

            // rl.DrawTextEx(
            //     font,
            //     fmt.ctprintf("%+.1fc", cents_err_smooth),
            //     {400, 340},
            //     24,
            //     0,
            //     rl.WHITE,
            // )

            data_points := phase_tracker.data_points


            x: f32 = 10
            i := phase_tracker.data_write_head

            // the idea is that phase gives bogus readings for random noise
            // --- need to somehow fade out the display if it's noise, eg low amplitude

            for i >= 0 {
                y := 500 - phase_tracker.data_points[i].err_cents * 5
                x += 0.5
                rl.DrawPixelV(
                    {x, y},
                    rl.ColorAlpha(rl.GREEN, phase_tracker.data_points[i].amp * 10),
                )
                i -= 1
            }

            i = len(phase_tracker.data_points) - 1

            for i > phase_tracker.data_write_head {
                y := 500 - phase_tracker.data_points[i].err_cents * 5
                x += 0.5
                // phase_points[i] = {x, y}
                rl.DrawPixelV(
                    {x, y},
                    rl.ColorAlpha(rl.GREEN, phase_tracker.data_points[i].amp * 10),
                )
                i -= 1
            }

            // measured_cents = phase_tracker.bands[0].

            // band.freq_diff_hz = -(band.phase_diff / time_delta) / math.TAU
            // band.estimated_freq_hz = band.freq_hz + band.freq_diff_hz
            // band.err_cents = freq_to_cents(band.estimated_freq_hz) - freq_to_cents(band.freq_hz)

            base_band := phase_tracker.bands[0]

            // phase_points: [MAX_SPECTRUM_DISPLAY_LEN]rl.Vector2 = {}
            rl.DrawLineV({10.0, 500.0}, {522.0, 500.0}, rl.GRAY)


            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.2fc", base_band.err_cents),
                {400, 340},
                24,
                0,
                rl.LIGHTGRAY,
            )

            // rl.DrawTextEx(font, fmt.ctprintf("%+.1fHz", freq_smooth), {400, 400}, 24, 0, rl.WHITE)
            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.2fHz", base_band.estimated_freq_hz),
                {400, 400},
                24,
                0,
                rl.LIGHTGRAY,
            )
            //////////////////////////////////////////

            // rl.DrawLineStrip(raw_data(phase_points[:]), i32(len(phase_points)), rl.LIME)

            // Detected note
            /*
            draw_note(prev_note_2, {160, 460}, 48, rl.GRAY, false)
            draw_note(prev_note, {220, 460}, 48, rl.GRAY, false)
            draw_note(detected_note, {280, 460}, 48, rl.GRAY, false)
            draw_note(next_note, {340, 460}, 48, rl.GRAY, false)
            draw_note(next_note_2, {400, 460}, 48, rl.GRAY, false)
            */
        }
    }
}
