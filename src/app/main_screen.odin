// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package app

import "core:fmt"

import "../audio"
import "../core"
import "../gfx"

draw_main_screen :: proc(app: ^App, layout: Layout, reading: Reading, menu: MenuCommand) {
    config := app.config

    draw_strobe_area(app, layout)
    draw_tuning_arrows(&app.displays, &app.measurement.note_target, layout, reading)
    draw_note_controls(app, layout, reading, menu)

    // The strobe's reading, none before a track settled, and nothing to measure on another note than a locked
    // one. The gauge points the way without one.
    draw_measurements(
        layout.measurements,
        reading.steady.detected_freq,
        reading.steady.err_cents,
        reading.strobe_readout,
        app.measurement.note_target.active,
    )

    // The displays in a cycle, the number keys go straight to one
    if gui_display_button(layout.display, config.strobe_display_type) {
        config.strobe_display_type = next_display(config.strobe_display_type)
    }

    // Opens on the settings, not the display's options it was closed on
    if gui_settings_button(layout.settings) do open_settings_sheet(&app.sheets)

    if gui_instrument_button(layout.instrument, config) do app.sheets.instrument.open = true

    // The input level, the microphone icon marks it as the input. The level is the rounded track cut off flat
    // where it ends.
    icon_y := f32(LEVEL_METER_HEIGHT - ICON_SIZE) / 2
    draw_icon(ICON_MICROPHONE, layout.level_meter + {0, icon_y}, icon_color)

    // A slow input, a Bluetooth headset's microphone at 16 or 24 kHz, gets a warning before the icon. The high
    // notes and the partials over its Nyquist are out of reach, their tracks show empty.
    WARNING_GAP :: 4
    if sample_rate := app.input.capture.sample_rate; sample_rate > 0 && sample_rate < core.LOW_SAMPLE_RATE {
        draw_icon(ICON_WARNING, layout.level_meter + {-ICON_SIZE - WARNING_GAP, icon_y}, warning_color)
    }

    meter := layout.level_meter + {LEVEL_BAR_OFFSET, 0}
    track := gfx.Rect{meter.x, meter.y, LEVEL_BAR_WIDTH, LEVEL_METER_HEIGHT}
    gfx.draw_rounded_rect(track, LEVEL_METER_HEIGHT / 2, level_track_color)

    // Empty until something was measured, e.g. without an input, a reading that isn't one would be 0 dBFS
    if reading.pitch.measured {
        level := LEVEL_BAR_WIDTH + clamp(reading.pitch.rms_dbfs, -LEVEL_BAR_WIDTH, 0)
        gfx.begin_scissor({meter.x, meter.y, level, LEVEL_METER_HEIGHT})
        gfx.draw_rounded_rect(track, LEVEL_METER_HEIGHT / 2, accent_color)
        gfx.end_scissor()
    }

    // The warning, the icon and the level open the input's sheet, a finger tall around the thin meter. Its
    // levels show right away, not after the first hold, and its list has what's connected now.
    left := layout.level_meter.x - ICON_SIZE - WARNING_GAP
    if gui_button({left, meter.y + LEVEL_METER_HEIGHT / 2 - 22, LEVEL_METER_WIDTH + ICON_SIZE + WARNING_GAP, 44}) {
        app.sheets.input.open = true
        app.input.stats_age = INPUT_STATS_HOLD_S
        app.input.refresh = true
    }

    when DEBUG_STATS do draw_debug_stats(app, layout, reading.pitch, meter)
}

// The strobe, or the trace or the scope's view in its place. Tapping a track opens its sheet, tapping the scope
// flips its sweep.
draw_strobe_area :: proc(app: ^App, layout: Layout) {
    strobe, view := layout.strobe, layout.strobe_view

    // The selected track stands out as its sheet comes up
    app.displays.strobe.selected_track = app.sheets.selected_track
    app.displays.strobe.selection = app.sheets.track.slide

    // The background of the whole area, darker than the panel, the part behind the notch included. The
    // strobe's tracks reach up behind the notch too, the trace and the scope's views start under it.
    gfx.draw_rect({strobe.x, strobe.y}, {strobe.width, strobe.height}, gfx.hex(strobe_bg_color))

    switch app.config.strobe_display_type {
    case .STROBE:
        draw_strobe_with_tracks(app, layout)
    case .TRACE:
        draw_trace_area(app, view)
    case .SPECTRUM:
        draw_spectrum_area(app, view)
    case .SCOPE, .LAMP:
        draw_scope_area(app, strobe, view)
    }

    // Over the whole strobe area, the part behind the notch included
    draw_strobe_shadow(strobe)

    if title, hint, missing := no_input_reason(app); missing do gui_no_input_message(app, strobe, title, hint)
}

// Turned by the lock-in or by the lamp's screen. Tapping a track opens its sheet, in vernier mode every track
// shows the same pitch and there's nothing to set on one.
draw_strobe_with_tracks :: proc(app: ^App, layout: Layout) {
    config, measurement, strobe := app.config, &app.measurement, layout.strobe
    lock_in := measurement.strobe_lock_in
    bands := lock_in.bands[:]
    if config.strobe_source == .LAMP {
        bands = core.strobe_lamp_bands(&measurement.strobe_lamp, &measurement.scope, bands, measurement.pitch_detector.snr_db)
    }

    displays := &app.displays
    draw_strobe_display(&displays.strobe, &displays.glow_targets, layout, bands, lock_in, config)

    if config.strobe_mode == .HARMONIC && !input_missing(app) && gui_button(strobe) {
        track := strobe_track_at(config.strobe_shape, layout, len(bands), gfx.mouse_position())
        if track >= 0 {
            app.sheets.selected_track = track
            app.sheets.track.open = true
        }
    }
}

draw_trace_area :: proc(app: ^App, view: gfx.Rect) {
    displays := &app.displays
    draw_trace_display(&displays.trace, &displays.glow_targets, view, app.config)
}

draw_spectrum_area :: proc(app: ^App, view: gfx.Rect) {
    displays := &app.displays
    track_hz := strobe_track_hz(app.measurement.strobe_lock_in)
    active := app.measurement.note_target.active
    draw_spectrum_display(&displays.spectrum, &displays.glow_targets, view, track_hz, active, app.config)
}

// The partials the strobe's tracks follow, until the end of the frame
strobe_track_hz :: proc(lock_in: ^core.StrobeLockIn) -> []f32 {
    track_hz := make([]f32, len(lock_in.bands), context.temp_allocator)
    for band, index in lock_in.bands do track_hz[index] = band.freq_hz
    return track_hz
}

// The scope or the lamp. Tapped, the scope flips between the wave over time and the Lissajous figure, the
// lamp between the one lamp and the split one, its two halves.
draw_scope_area :: proc(app: ^App, strobe, view: gfx.Rect) {
    config, measurement := app.config, &app.measurement
    draw_scope_display(&app.displays.scope, &app.displays.glow_targets, &measurement.scope, view, config, measurement.pitch_detector.snr_db)
    if input_missing(app) || !gui_button(strobe) do return

    if config.strobe_display_type == .SCOPE {
        config.scope_sweep = .XY if config.scope_sweep == .TIME else .TIME
    } else {
        config.lamp_shape = .HALF_RECTIFIED if config.lamp_shape == .SPLIT else .SPLIT
    }
}

// A denied microphone only gives silence, an input that didn't open gives nothing. The strobe would just
// stand still, it says why instead.
no_input_reason :: proc(app: ^App) -> (title, hint: cstring, missing: bool) {
    if audio.microphone_denied() do return "Microphone access is off", "Tap to allow it in Settings", true
    if len(app.input.devices) == 0 do return "No input found", "Connect one and tap to look again", true
    if audio.input_failed(app.input.capture) do return "The input didn't open", "Tap to try again", true

    return
}

// Over the strobe area. Tapped it tries again on what's connected now, or asks for the microphone.
gui_no_input_message :: proc(app: ^App, strobe: gfx.Rect, title, hint: cstring) {
    gfx.draw_rect({strobe.x, strobe.y}, {strobe.width, strobe.height}, gfx.hex(strobe_bg_color))
    center := [2]f32{strobe.x + strobe.width / 2, strobe.y + strobe.height / 2}
    title_size := measure_label(pixel_fonts.title, title)
    hint_size := measure_label(pixel_fonts.label, hint)
    draw_label(pixel_fonts.title, title, center - {title_size.x / 2, title_size.y + 4}, text_color_white)
    draw_label(pixel_fonts.label, hint, center - {hint_size.x / 2, -4}, text_color_muted)

    if !gui_button(strobe) do return

    if audio.microphone_denied() do audio.allow_microphone()
    else do app.input.restart, app.input.refresh = true, true
}

// The strobe area says why there's no input instead, see draw_strobe_area
input_missing :: proc(app: ^App) -> bool {
    return audio.microphone_denied() || audio.input_failed(app.input.capture)
}

// An arrow on the side the pitch is off to, pointing inwards the way to tune: flat on the left pointing right
// to tune up, like higher notes are to the right on the ruler
draw_tuning_arrows :: proc(displays: ^Displays, note_target: ^core.NoteTarget, layout: Layout, reading: Reading) {
    // Only the strong readings, a fading note drifts and would flash the arrows. The strobe's close to the
    // note, like the readout. On another note than the locked one, as far as the notes are apart.
    cents := core.target_cents_off(note_target, note_target.last_good_pitch.detected_freq)
    if reading.strobe_readout do cents = reading.steady.err_cents
    if reading.out_of_range do cents = core.out_of_range_cents(note_target)

    distance := abs(cents)
    measures_target := core.measures_target(note_target)

    // Without a lock or a string, further than half a semitone is a neighbouring note that isn't confirmed yet
    if !note_target.active || (!measures_target && distance > 50) do return

    displays.flat_arrow = core.schmitt_trigger_neg(displays.flat_arrow, cents, -8, -10)
    displays.sharp_arrow = core.schmitt_trigger(displays.sharp_arrow, cents, 8, 10)

    arrow := pixel_fonts.strobe_arrow

    // A turned strobe's stripes climb when sharp, see strobe_upright: flat at the bottom pointing up, sharp
    // at the top pointing down, in the middle
    if layout.strobe_turned {
        strobe, view := layout.strobe, layout.strobe_view
        glyph: cstring = "▲" if displays.flat_arrow else "▼"
        x := strobe.x + (strobe.width - gfx.measure_text(arrow.font, glyph, arrow.size, 0).x) / 2
        if displays.flat_arrow {
            gfx.draw_text(arrow.font, glyph, snap_to_pixels({x, view.y + view.height - 10 - arrow.size}), arrow.size, 0, accent_color)
        } else if displays.sharp_arrow {
            gfx.draw_text(arrow.font, glyph, snap_to_pixels({x, view.y + 10}), arrow.size, 0, accent_color)
        }
        return
    }

    arrow_y := layout.strobe_view.y + 10

    if displays.flat_arrow {
        gfx.draw_text(arrow.font, "▶", snap_to_pixels({layout.strobe.x + 10, arrow_y}), arrow.size, 0, accent_color)
    } else if displays.sharp_arrow {
        width := gfx.measure_text(arrow.font, "◀", arrow.size, 0).x
        position := snap_to_pixels({layout.strobe.x + layout.strobe.width - 10 - width, arrow_y})
        gfx.draw_text(arrow.font, "◀", position, arrow.size, 0, accent_color)
    }
}

// The target note on the ruler with the gauge under it, the lock, and the note's offset. The lock button (or
// space, or tapping the note) locks the note, tapping another note on the ruler locks that one instead.
draw_note_controls :: proc(app: ^App, layout: Layout, reading: Reading, menu: MenuCommand) {
    config, note_target := app.config, &app.measurement.note_target
    setup := current_setup(config)
    string_mode := setup.instrument != .CHROMATIC

    // A transposing instrument reads the written note, only what's shown moves, the steps are relative and
    // work the same either way. With a capo the strings sound higher and keep the names of the open strings,
    // like the chord shapes played over it.
    transpose := -capo_fret(setup) if string_mode else transpose_key(setup)
    shown_cents := note_target.target_note.cents
    shown_note := core.cents_to_note(f32(shown_cents + 100 * transpose), note_target.target_note.pitch_standard)

    // The strings, or every note of a piano with the target among them. There's always a target, load_config
    // holds the start note in A0 to C8.
    ruler_notes: []core.Note
    target: int
    if string_mode {
        ruler_notes = make([]core.Note, note_target.string_count, context.temp_allocator)
        for &note, index in ruler_notes {
            note = core.cents_to_note(f32(100 * (note_target.strings[index] + transpose)), shown_note.pitch_standard)
        }
        target = note_target.string_index
    } else {
        ruler_notes = make([]core.Note, core.NOTE_COUNT, context.temp_allocator)
        for &note, index in ruler_notes {
            note = core.cents_to_note(f32(100 * (core.LOWEST_NOTE + index + transpose)), shown_note.pitch_standard)
        }
        target = clamp(shown_cents / 100 - core.LOWEST_NOTE, 0, core.NOTE_COUNT - 1)
    }
    step, note_tapped, swiping := gui_note_ruler(layout.ruler, ruler_notes, target, note_target.active)

    // Within half a semitone of the note, or a few semitones of a string. Another note than a locked one
    // pins it at the end on that side.
    cents := reading.steady.err_cents
    lit := note_target.active && (reading.steady.measured || reading.out_of_range)

    if reading.out_of_range do cents = 1200 * core.out_of_range_side(note_target)

    // Further than the gauge reaches from any string, e.g. a guitar's low E on a ukulele, it says so instead
    // of the gauge stuck at its end, and which way
    if string_mode && lit && abs(cents) > 100 * GAUGE_SEMITONE_TICKS {
        label: cstring = "TOO FLAT" if cents < 0 else "TOO SHARP"
        width := measure_label(pixel_fonts.label, label, 1).x
        label_y := layout.gauge.y + (GAUGE_HEIGHT - LABEL_SIZE) / 2
        draw_label(pixel_fonts.label, label, {layout.gauge.x - width / 2, label_y}, text_color_light, 1)
    } else {
        draw_cents_gauge(layout.gauge, cents, lit, string_mode, gfx.hex(strobe_colors(config).x))
    }

    lock_toggled := gui_lock_toggle(layout.lock, note_target.locked) || note_tapped
    if !gui.disabled {
        if gfx.key_pressed(.SPACE) || menu == .LOCK_NOTE do lock_toggled = true
        if gfx.key_pressed(.LEFT) do step = -1
        if gfx.key_pressed(.RIGHT) do step = 1
    }

    // A swipe locks the note in the middle as it goes, the one it started on right away, rather than the
    // target following the detected note under the finger
    if swiping do lock_toggled = !note_target.locked
    if lock_toggled || step != 0 do app.quiet_time = 0

    retune_target := lock_toggled && core.toggle_note_lock(note_target)

    if core.step_target_note(note_target, step) do retune_target = true
    if retune_target do retune(&app.measurement, config)

    // A note that's tuned off pitch says so between the letter and the lock, the strobe and the readout are on
    // the offset note, see gui_note_offsets.
    if offset := core.note_offset_cents(note_target, note_target.target_note); offset != 0 {
        text := offset_cents_text(offset)
        width := measure_label(pixel_fonts.label, text, 1).x

        // Like the note, white while there's a pitch
        color := text_color_white if note_target.active else text_color_muted
        draw_label(pixel_fonts.label, text, layout.note_offset - {width / 2, LABEL_SIZE / 2}, color, 1)
    }
}

// The levels next to the input meter and the NSDF plots on the right
draw_debug_stats :: proc(app: ^App, layout: Layout, pitch: core.PitchInfo, meter: [2]f32) {
    stat :: proc(text: cstring, position: [2]f32, color := text_color_white, large := false) {
        font := pixel_fonts.label_large if large else pixel_fonts.label_small
        gfx.draw_text(font.font, text, position, 16 if large else 12, 0, color)
    }

    floor_level := core.dbfs(pitch.noise_floor)
    gfx.draw_rect(meter + {0, LEVEL_METER_HEIGHT}, {LEVEL_BAR_WIDTH, 3}, gfx.hex(strobe_bg_color))
    gfx.draw_rect(meter + {0, LEVEL_METER_HEIGHT}, {LEVEL_BAR_WIDTH + floor_level, 3}, gfx.PURPLE)

    base_band := app.measurement.strobe_lock_in.bands[0]
    stat(fmt.ctprintf("Band SNR %.1f", base_band.snr_db), layout.stats)
    stat(fmt.ctprintf("Band NF %.1f", core.dbfs(base_band.noise_floor.level)), layout.stats + {0, 15})
    stat(fmt.ctprintf("Band drift %.1f", base_band.drift_cents), layout.stats + {0, 30})
    stat(fmt.ctprintf("RMS %.1f", pitch.rms_dbfs), layout.stats + {130, 0})
    stat(fmt.ctprintf("NF %.1f", floor_level), layout.stats + {130, 15})
    stat(fmt.ctprintf("SNR %.1f", pitch.snr_db), layout.stats + {130, 30})

    stat(fmt.ctprintf("Clarity %.3f", pitch.clarity), {500, 10}, large = true)
    if pitch.is_strong_pitch do stat("strong", {600, 10}, gfx.ORANGE, large = true)
    if pitch.is_weak_pitch do stat("weak", {600, 10}, gfx.PURPLE, large = true)

    font := pixel_fonts.label_small.font
    draw_nsdf(gfx.Rect{520, 40, 660, 200}, &app.measurement.pitch_detector.nsdf, font)
    draw_freq_plot(gfx.Rect{520, 300, 660, 200}, &app.measurement.pitch_detector.nsdf, font)
}
