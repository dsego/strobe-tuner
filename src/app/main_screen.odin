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
import "core:math"

import "../audio"
import "../core"
import "../gfx"

draw_main_screen :: proc(app: ^App, layout: Layout, reading: Reading, menu_command: MenuCommand) {
    config := app.config

    draw_strobe_area(app, layout)
    draw_tuning_arrows(&app.strobe_area, &app.measurement.note_target, layout, reading, config)
    draw_tap_toast(&app.strobe_area.toast, config.strobe_display_type, layout.strobe_view)
    draw_note_controls(app, layout, reading, menu_command)

    // The strobe's reading or the whole wave's, none before a track settled, and nothing to measure on another note
    // than a locked one. The gauge points the way without one.
    draw_measurements(
        layout.measurements,
        reading.steady.detected_freq,
        reading.steady.err_cents,
        reading.readout_shown,
        app.measurement.note_target.active,
    )

    // Opens on the settings, not the display's options it was closed on
    if gui_settings_button(layout.settings) do open_settings_sheet(&app.sheets)

    if gui_instrument_button(layout.instrument, config) do app.sheets.instrument.open = true

    sample_rate := app.input.capture.sample_rate
    if gui_level_meter(layout.level_meter, reading.pitch, sample_rate) do open_input_sheet(app)

    // A menu of the displays, last so it opens over the controls under it. Tab goes through them and the number
    // keys straight to one.
    gui_pick_display(
        layout.display_picker,
        &config.strobe_display_type,
        &app.strobe_area.display_menu_open,
    )

    when DEBUG_STATS do draw_debug_stats(app, layout, reading.pitch)
}

// The input's level, the microphone icon marks it as the input. Returns true when the level, the icon or the
// warning before it is tapped.
gui_level_meter :: proc(position: [2]f32, pitch: core.PitchInfo, sample_rate: f32) -> bool {
    WARNING_GAP :: 4

    icon_y := f32(LEVEL_METER_HEIGHT - ICON_SIZE) / 2
    draw_icon(ICON_MICROPHONE, position + {0, icon_y}, icon_color)

    // A slow input, a Bluetooth headset's microphone at 16 or 24 kHz, gets a warning before the icon. The high
    // notes and the partials over its Nyquist are out of reach, their tracks show empty.
    if sample_rate > 0 && sample_rate < core.LOW_SAMPLE_RATE {
        draw_icon(ICON_WARNING, position + {-ICON_SIZE - WARNING_GAP, icon_y}, warning_color)
    }

    // The level is the rounded track cut off flat where it ends
    bar := position + {LEVEL_BAR_OFFSET, 0}
    track := gfx.Rect{bar.x, bar.y, LEVEL_BAR_WIDTH, LEVEL_METER_HEIGHT}
    gfx.draw_rounded_rect(track, LEVEL_METER_HEIGHT / 2, level_track_color)

    // Empty until something was measured, e.g. without an input, a reading that isn't one would be 0 dBFS
    if pitch.measured {
        level := LEVEL_BAR_WIDTH + clamp(pitch.rms_dbfs, -LEVEL_BAR_WIDTH, 0)
        gfx.begin_scissor({bar.x, bar.y, level, LEVEL_METER_HEIGHT})
        gfx.draw_rounded_rect(track, LEVEL_METER_HEIGHT / 2, accent_color)
        gfx.end_scissor()
    }

    // A finger tall around the thin bar, from the warning's left edge
    left := position.x - ICON_SIZE - WARNING_GAP
    width: f32 = LEVEL_METER_WIDTH + ICON_SIZE + WARNING_GAP
    return gui_button({left, bar.y + LEVEL_METER_HEIGHT / 2 - TOUCH_HEIGHT / 2, width, TOUCH_HEIGHT})
}

// The strobe, or the trace or the scope's view in its place. Tapping a track opens its sheet, tapping the scope
// flips its sweep.
draw_strobe_area :: proc(app: ^App, layout: Layout) {
    strobe, view := layout.strobe, layout.strobe_view

    // The selected track stands out as its sheet comes up
    app.strobe_area.strobe.selected_track = app.sheets.selected_track
    app.strobe_area.strobe.selection = app.sheets.track.slide

    // The background of the whole area, darker than the panel, the part behind the notch included. The
    // strobe's tracks reach up behind the notch too, the trace and the scope's views start under it.
    gfx.draw_rect({strobe.x, strobe.y}, {strobe.width, strobe.height}, gfx.hex(strobe_bg_color))

    switch app.config.strobe_display_type {
    case .STROBE:
        draw_strobe_with_tracks(app, layout)
    case .TRACE:
        draw_trace_area(app, strobe, view)
    case .SPECTRUM:
        draw_spectrum_area(app, strobe, view)
    case .SCOPE, .LAMP:
        draw_scope_area(app, strobe, view)
    }

    if title, hint, missing := no_input_reason(app); missing do gui_no_input_message(app, strobe, view, title, hint)

    // Over the whole strobe area, the part behind the notch included, and over the message, the area's edge shows
    draw_strobe_shadow(strobe)
}

// Turned by the lock-in. Tapping a track opens its sheet, in vernier mode every track shows the same pitch and
// there's nothing to set on one. Off the tracks a tap could have switched the shape, but the flat tracks fill
// the strobe and there it couldn't switch back.
draw_strobe_with_tracks :: proc(app: ^App, layout: Layout) {
    config, strobe := app.config, layout.strobe
    lock_in := app.measurement.strobe_lock_in
    bands := lock_in.bands[:]

    strobe_area := &app.strobe_area
    draw_strobe_display(&strobe_area.strobe, &strobe_area.glow_targets, layout, bands, lock_in, config)

    if config.strobe_mode == .HARMONIC && !input_missing(app) && gui_button(strobe) {
        track := strobe_track_at(config.strobe_shape, layout, len(bands), gfx.mouse_position())
        if track >= 0 {
            app.sheets.selected_track = track
            app.sheets.track.open = true
        }
    }
}

// Tapped, the range flips between its narrow and its wide step
draw_trace_area :: proc(app: ^App, strobe, view: gfx.Rect) {
    config, strobe_area := app.config, &app.strobe_area
    draw_trace_display(&strobe_area.trace, view, config)
    if input_missing(app) || !gui_button(strobe) do return

    steps, labels := TRACE_RANGE_STEPS_CENTS, RANGE_LABELS
    step := 1 if config.trace_range_cents == steps[0] else 0
    config.trace_range_cents = steps[step]
    show_tap_toast(&strobe_area.toast, .TRACE,"Range", labels[step])
}

// Tapped, the scale flips between the noise's and the level's
draw_spectrum_area :: proc(app: ^App, strobe, view: gfx.Rect) {
    config, strobe_area := app.config, &app.strobe_area
    track_hz := strobe_track_hz(app.measurement.strobe_lock_in)
    active := app.measurement.note_target.active
    draw_spectrum_display(&strobe_area.spectrum, view, track_hz, active, config)
    if input_missing(app) || !gui_button(strobe) do return

    config.spectrum_scale = .DBFS if config.spectrum_scale == .SNR else .SNR
    labels := SCALE_LABELS
    show_tap_toast(&strobe_area.toast, .SPECTRUM,"Scale", labels[int(config.spectrum_scale)])
}

// The partials the strobe's tracks follow, until the end of the frame
strobe_track_hz :: proc(lock_in: ^core.StrobeLockIn) -> []f32 {
    track_hz := make([]f32, len(lock_in.bands), context.temp_allocator)
    for band, index in lock_in.bands do track_hz[index] = band.freq_hz
    return track_hz
}

// The scope or the lamp. Tapped, the scope flips between the wave over time and the circle, the lamp goes
// round its rectifiers in the settings' order: the one lamp, the wave as it is, the two halves split.
draw_scope_area :: proc(app: ^App, strobe, view: gfx.Rect) {
    config, measurement := app.config, &app.measurement
    draw_scope_display(&app.strobe_area.scope, &app.strobe_area.glow_targets, &measurement.scope, view, config)
    if input_missing(app) || !gui_button(strobe) do return

    toast := &app.strobe_area.toast
    if config.strobe_display_type == .SCOPE {
        config.scope_sweep = .TIME if config.scope_sweep == .CIRCLE else .CIRCLE
        labels := SWEEP_LABELS
        show_tap_toast(toast, .SCOPE, "Sweep", labels[int(config.scope_sweep)])
    } else {
        config.lamp_shape = core.ScopeShape((int(config.lamp_shape) + 1) % len(core.ScopeShape))
        labels := RECTIFIER_LABELS
        show_tap_toast(toast, .LAMP, "Rectifier", labels[int(config.lamp_shape)])
    }
}

// The option a tap on a view changed and its new value, in the settings' own words, in a pill at the top of the
// view for a moment and then fading. Without it a tap changed the view silently, with no note playing nothing
// showed it at all. Another tap puts its own in its place, another display clears it.
TapToast :: struct {
    display:       StrobeDisplayType,
    option, value: cstring, // nil while none shows
    age_s:         f32,
}

TAP_TOAST_HOLD_S :: 1.0
TAP_TOAST_FADE_S :: 0.3

show_tap_toast :: proc(toast: ^TapToast, display: StrobeDisplayType, option, value: cstring) {
    toast^ = {display, option, value, 0}
}

// In white on the panel's dark, the view under it cut out. Over the tuning arrows: on a turned strobe the sharp
// arrow is at the top middle too, for the moment after a tap.
draw_tap_toast :: proc(toast: ^TapToast, display: StrobeDisplayType, view: gfx.Rect) {
    PAD :: 12
    HEIGHT :: 24
    TOP :: 10

    if toast.option == nil do return

    toast.age_s += gfx.frame_time()
    if toast.display != display || toast.age_s >= TAP_TOAST_HOLD_S + TAP_TOAST_FADE_S {
        toast^ = {}
        return
    }

    light := 1 - math.smoothstep(f32(TAP_TOAST_HOLD_S), TAP_TOAST_HOLD_S + TAP_TOAST_FADE_S, toast.age_s)
    font := pixel_fonts.label
    text := fmt.ctprintf("%s %s", toast.option, toast.value)
    width := 2 * PAD + measure_label(font, text, 1).x
    pill := gfx.Rect{view.x + (view.width - width) / 2, view.y + TOP, width, HEIGHT}
    gfx.draw_pill(pill, fade_color(gfx.hex(panel_bg_color), light))
    draw_label(font, text, {pill.x + PAD, pill.y + (HEIGHT - LABEL_SIZE) / 2}, fade_color(text_color_white, light), 1)
}

// A denied microphone only gives silence, an input that didn't open gives nothing. The strobe would just
// stand still, it says why instead.
no_input_reason :: proc(app: ^App) -> (title, hint: cstring, missing: bool) {
    // The Mac's are System Settings, a phone's Settings
    settings_hint: cstring = "Tap to allow it in Settings"
    when ODIN_OS == .Darwin && !gfx.IOS do settings_hint = "Tap to allow it in System Settings"

    if audio.microphone_denied() do return "Microphone access is off", settings_hint, true
    if len(app.input.devices) == 0 do return "No input found", "Connect one and tap to look again", true
    if audio.input_failed(app.input.capture) do return "The input didn't open", "Tap to try again", true

    when gfx.WEB {
        if audio.waiting_for_tap() do return "Tap to listen", "The browser starts the microphone after a tap", true
    }
    return
}

// Over the strobe area, in the middle of its view under the notch. Tapped it tries again on what's connected
// now, or asks for the microphone.
gui_no_input_message :: proc(app: ^App, strobe, view: gfx.Rect, title, hint: cstring) {
    gfx.draw_rect({strobe.x, strobe.y}, {strobe.width, strobe.height}, gfx.hex(strobe_bg_color))
    center := [2]f32{view.x + view.width / 2, view.y + view.height / 2}
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
    when gfx.WEB {
        if audio.waiting_for_tap() do return true
    }
    return audio.microphone_denied() || audio.input_failed(app.input.capture)
}

// An arrow on the side the pitch is off to, pointing inwards the way to tune, with the sharp or the flat on its
// outside: flat on the left pointing right to tune up, like higher notes are to the right on the ruler
draw_tuning_arrows :: proc(strobe_area: ^StrobeArea, note_target: ^core.NoteTarget, layout: Layout, reading: Reading, config: ^Config) {
    // Only the strong readings, a fading note drifts and would flash the arrows. The strobe's close to the
    // note, like the readout.
    cents := core.target_cents_off(note_target, note_target.last_good_pitch.detected_freq)
    if reading.readout_shown do cents = reading.steady.err_cents

    distance := abs(cents)
    measures_target := core.measures_target(note_target)

    // Without a lock or a string, further than the note holds is a neighbouring note that isn't confirmed yet
    if !note_target.active || (!measures_target && distance > core.NOTE_HOLD_CENTS) do return

    strobe_area.flat_arrow = core.schmitt_trigger_neg(strobe_area.flat_arrow, cents, -8, -10)
    strobe_area.sharp_arrow = core.schmitt_trigger(strobe_area.sharp_arrow, cents, 8, 10)
    if !strobe_area.flat_arrow && !strobe_area.sharp_arrow do return

    MARGIN :: 10
    strobe, view := layout.strobe, layout.strobe_view
    arrow := pixel_fonts.strobe_arrow
    flat, sharp := ArrowGlyph{pixel_fonts.arrow_flat, '♭'}, ArrowGlyph{pixel_fonts.arrow_sharp, '♯'}

    // Where sharp is up, a turned strobe's stripes climb when sharp, see strobe_upright, and the trace's line
    // rises: flat at the bottom pointing up, sharp at the top pointing down, the sign first. In the strobe's left
    // corners, away from its hub behind the panel, inside its labels. On the trace the arrow is over and under the
    // notches at now, pointing along them. The other views beside the panel aren't turned, sharp is still to the
    // right.
    trace := config.strobe_display_type == .TRACE
    turned := config.strobe_display_type == .STROBE && layout.strobe_turned
    if turned || trace {
        top, bottom: f32 = MARGIN, MARGIN
        if turned {
            label_top, label_bottom := turned_label_reach(config)
            top, bottom = max(top, label_top + MARGIN), max(bottom, label_bottom + MARGIN)
        }

        pair := [2]ArrowGlyph{flat, {arrow, '▲'}}
        middle_y := view.y + view.height - bottom - arrow.size / 2
        if strobe_area.sharp_arrow {
            pair = {sharp, {arrow, '▼'}}
            middle_y = view.y + top + arrow.size / 2
        }

        left := view.x + MARGIN
        if trace {
            plot := trace_plot(view)
            left = plot.x + plot.width - arrow_pair_width(pair) + arrow_glyph_ink(pair[1]).width / 2
        }
        draw_arrow_pair(pair, left, middle_y)
        return
    }

    middle_y := view.y + MARGIN + arrow.size / 2
    if strobe_area.flat_arrow {
        draw_arrow_pair({flat, {arrow, '▶'}}, strobe.x + MARGIN, middle_y)
    } else {
        pair := [2]ArrowGlyph{{arrow, '◀'}, sharp}
        draw_arrow_pair(pair, strobe.x + strobe.width - MARGIN - arrow_pair_width(pair), middle_y)
    }
}

// An arrow's glyph, or the sharp's or the flat's beside it
ArrowGlyph :: struct {
    font:      PixelFont,
    codepoint: rune,
}

// Between the arrow's ink and the sign's, -define:ARROW_SIGN_GAP=n to try another
ARROW_SIGN_GAP :: f32(#config(ARROW_SIGN_GAP, 4))

arrow_glyph_ink :: proc(glyph: ArrowGlyph) -> gfx.Rect {
    return gfx.glyph_ink(glyph.font.font, glyph.codepoint, glyph.font.size)
}

arrow_pair_width :: proc(pair: [2]ArrowGlyph) -> f32 {
    return arrow_glyph_ink(pair[0]).width + ARROW_SIGN_GAP + arrow_glyph_ink(pair[1]).width
}

// Left to right from left, their inks a gap apart and centred on middle_y: the sign's font sits differently in
// its line than the arrow's
draw_arrow_pair :: proc(pair: [2]ArrowGlyph, left, middle_y: f32) {
    x := left
    for glyph in pair {
        ink := arrow_glyph_ink(glyph)
        position := snap_to_pixels({x - ink.x, middle_y - ink.y - ink.height / 2})
        gfx.draw_text(glyph.font.font, fmt.ctprintf("%c", glyph.codepoint), position, glyph.font.size, 0, accent_color)
        x += ink.width + ARROW_SIGN_GAP
    }
}

// The target note on the ruler with the gauge under it, the lock, and the note's offset. The lock button (or
// space, or tapping the note) locks the note, tapping another note on the ruler locks that one instead.
// The semitones the shown notes are moved by. A transposing instrument reads the written note, only what's
// shown moves, the steps are relative and work the same either way. With a capo the strings sound higher and
// keep the names of the open strings, like the chord shapes played over it.
shown_transpose :: proc(config: ^Config) -> int {
    setup := current_setup(config)
    return -capo_fret(setup) if setup.instrument != .CHROMATIC else transpose_key(setup)
}

draw_note_controls :: proc(app: ^App, layout: Layout, reading: Reading, menu_command: MenuCommand) {
    config, note_target := app.config, &app.measurement.note_target
    string_mode := note_target.string_count > 0 // a custom preset's every note before its first row

    transpose := shown_transpose(config)
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
    step, note_tapped, swiping := gui_note_ruler(layout.ruler, ruler_notes, target, note_target.active, !string_mode)

    // Within half a semitone of the note, or a few semitones of a string or a locked note
    cents := reading.steady.err_cents
    lit := note_target.active && reading.steady.measured
    measures_target := core.measures_target(note_target)

    // Further than the gauge reaches from a string or a locked note, e.g. a guitar's low E on a ukulele, it says
    // so instead of the gauge stuck at its end, the note played and which way. Named like the ruler's notes.
    if measures_target && lit && abs(cents) > 100 * GAUGE_SEMITONE_TICKS {
        played := core.freq_to_note(reading.steady.detected_freq, shown_note.pitch_standard)
        played = core.cents_to_note(f32(played.cents + 100 * transpose), shown_note.pitch_standard)
        side := "FLAT" if cents < 0 else "SHARP"
        label := fmt.ctprintf("%s · TOO %s", core.note_name(played), side)
        width := measure_label(pixel_fonts.label, label, 1).x
        label_y := layout.gauge.y + (GAUGE_HEIGHT - LABEL_SIZE) / 2
        draw_label(pixel_fonts.label, label, {layout.gauge.x - width / 2, label_y}, text_color_light, 1)
    } else {
        draw_cents_gauge(layout.gauge, cents, lit, measures_target, gfx.hex(strobe_colors(config).x))
    }

    lock_toggled := gui_lock_toggle(layout.lock, note_target.locked) || note_tapped
    if !gui.disabled {
        if gfx.key_pressed(.SPACE) || menu_command == .LOCK_NOTE do lock_toggled = true
        if gfx.key_pressed(.LEFT) do step = -1
        if gfx.key_pressed(.RIGHT) do step = 1

        // An octave up and down on every note, the strings have no octaves
        if !string_mode && gfx.key_pressed(.UP) do step = ruler_step_octave(len(ruler_notes), target, 1)
        if !string_mode && gfx.key_pressed(.DOWN) do step = ruler_step_octave(len(ruler_notes), target, -1)
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

// The noise floor under the input's level bar, and on the right the pitch detection's latest detection, its
// NSDF or its harmonic stack, over the stack's spectrogram
draw_debug_stats :: proc(app: ^App, layout: Layout, pitch: core.PitchInfo) {
    stat :: proc(text: cstring, position: [2]f32, color := text_color_white, large := false) {
        font := pixel_fonts.label_large if large else pixel_fonts.label_small
        gfx.draw_text(font.font, text, position, 16 if large else 12, 0, color)
    }

    // Under the bar, at its scale, see gui_level_meter
    bar := layout.level_meter + {LEVEL_BAR_OFFSET, LEVEL_METER_HEIGHT}
    floor_level := core.dbfs(pitch.noise_floor)
    gfx.draw_rect(bar, {LEVEL_BAR_WIDTH, 3}, gfx.hex(strobe_bg_color))
    gfx.draw_rect(bar, {LEVEL_BAR_WIDTH + floor_level, 3}, gfx.PURPLE)

    base_band := app.measurement.strobe_lock_in.bands[0]
    stat(fmt.ctprintf("Band level %.2f", base_band.slat_level), layout.stats)
    stat(fmt.ctprintf("Band lit %.2f", base_band.visibility), layout.stats + {0, 15})
    stat(fmt.ctprintf("Band drift %.1f", base_band.drift_cents), layout.stats + {0, 30})
    stat(fmt.ctprintf("RMS %.1f", pitch.rms_dbfs), layout.stats + {130, 0})
    stat(fmt.ctprintf("NF %.1f", floor_level), layout.stats + {130, 15})
    stat(fmt.ctprintf("SNR %.1f", pitch.snr_db), layout.stats + {130, 30})

    if app.measurement.pitch_detector.method == .HARMONICS {
        stat(fmt.ctprintf("Stack %.1f dB", pitch.harmonics_db), {480, 10}, large = true)
    } else {
        stat(fmt.ctprintf("Clarity %.3f", pitch.clarity), {500, 10}, large = true)
    }
    if pitch.is_strong_pitch do stat("strong", {600, 10}, gfx.ORANGE, large = true)
    if pitch.is_weak_pitch do stat("weak", {600, 10}, gfx.PURPLE, large = true)

    font := pixel_fonts.label_small.font
    detector := &app.measurement.pitch_detector
    if detector.method == .HARMONICS {
        draw_stack_plot(gfx.Rect{520, 50, 660, 170}, &detector.stack, pitch, detector.sample_rate, font)
    } else {
        draw_nsdf(gfx.Rect{520, 40, 660, 180}, &detector.nsdf, font)
    }

    note_target := &app.measurement.note_target
    if pitch.fresh {
        record_debug_column(&debug_spectrogram, &detector.stack, pitch, note_target.active, note_target.target_note, detector.sample_rate)
    }
    draw_debug_spectrogram(&debug_spectrogram, gfx.Rect{520, 270, 660, 330}, detector.sample_rate, app.config.pitch_standard, font)
}
