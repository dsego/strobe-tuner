// Copyright (C) 2026  Davorin Šego

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

import "core:math"

import "../core"
import "../gfx"

// Vernier mode, each track turns this much faster than the one under it
VERNIER_SPEED_MULTIPLIER :: 2


// What hears the input and what's read from it, from one frame to the next, see measure
Measurement :: struct {
    pitch_detector: core.PitchDetector, // follows the pitch standard, see apply_config
    note_target:    core.NoteTarget,
    strobe_lock_in: ^core.StrobeLockIn,
    scope:          core.Scope, // of the scope and the lamp display types, and the tracks the lamp turns
    strobe_lamp:    core.StrobeLamp, // the tracks the lamp turns, strobe_source LAMP

    readout_track:  int, // the strobe track the readout follows, see core.strobe_readout_track
    held_readout:   HeldReadout, // the last one shown while the note was lit, see measure
    traced_track:   int, // the track the readout followed, the trace stays on it while its stripes show

    // What sets the scope's scale again, see feed_scope: an attack on the input, or a note lit from silence
    input_attack:   core.InputAttack,
    attacked:       bool,
    was_active:     bool, // the note target's last frame
    note_lit:       bool,
}

// This frame's measurements, for the main screen
Reading :: struct {
    pitch:         core.PitchInfo, // the latest detection
    steady:        core.PitchInfo, // the readout, the strong detections averaged, or a track's
    readout_shown: bool, // the readout has a reading, none before a track settled, see measure
}

// The readout as the note went dark
HeldReadout :: struct {
    shown: bool,
    freq:  f32,
    cents: f32,
}


// The note target from the last run's note, the strobe's lock-in, the pitch detector and the scope's samples
init_measurement :: proc(measurement: ^Measurement, config: ^Config) {
    measurement.note_target = core.init_note_target(config.target_freq_hz, config.pitch_standard, prevent_octave_jumps = true)
    measurement.strobe_lock_in = core.init_strobe_lock_in(config.target_freq_hz, config.strobe_intervals[:], config.strobe_mode)
    measurement.pitch_detector = core.init_pitch_detector(config.pitch_standard)
    measurement.scope = core.init_scope(SCOPE_COLUMNS, SCOPE_ROWS)

    // Its spectrogram whichever way the pitch detection goes, see draw_debug_spectrogram
    when DEBUG_STATS do measurement.pitch_detector.stack_shown = true
}

destroy_measurement :: proc(measurement: ^Measurement) {
    core.destroy_scope(&measurement.scope)
    core.destroy_pitch_detector(&measurement.pitch_detector)
    core.destroy_strobe_lock_in(measurement.strobe_lock_in)
}

// The strobe on the target note with the current tracks, speed and mode
retune :: proc(measurement: ^Measurement, config: ^Config) {
    measurement.traced_track = -1 // the tracks are at another note now
    measurement.held_readout = {}
    measurement.strobe_lock_in.readout_fit_s = config.readout_fit_s
    core.set_strobe_lock_in_tracks(
        measurement.strobe_lock_in,
        config.strobe_intervals[:],
        config.strobe_offsets_cents[:],
        config.strobe_speeds[:],
    )
    core.set_strobe_lock_in_freq(
        measurement.strobe_lock_in,
        core.target_freq(&measurement.note_target),
        config.pitch_standard,
        strobe_speed(config),
        VERNIER_SPEED_MULTIPLIER,
        config.strobe_mode,
    )

    // The whole wave's readout averages as much longer as the tracks' fit, see core.READOUT_SMOOTHING_S
    measurement.note_target.readout_smoothing_s = core.READOUT_SMOOTHING_S * config.readout_fit_s / core.READOUT_FIT_S
}

// Started over on another input, the readout it held included
reset_measurement :: proc(measurement: ^Measurement) {
    core.reset_pitch_detector(&measurement.pitch_detector)
    core.reset_strobe_lock_in(measurement.strobe_lock_in)
    core.reset_scope(&measurement.scope)
    measurement.readout_track, measurement.traced_track = -1, -1
    measurement.held_readout = {}
    measurement.input_attack = {}
}

// The windows and filters sized for the input's sample rate
set_measurement_sample_rate :: proc(measurement: ^Measurement, sample_rate: f32) {
    core.set_pitch_detector_sample_rate(&measurement.pitch_detector, sample_rate)
    core.set_strobe_lock_in_sample_rate(measurement.strobe_lock_in, sample_rate)
    core.set_scope_sample_rate(&measurement.scope, sample_rate)
}

// The pitch detection, the strobe and the note target on the new audio
measure :: proc(app: ^App) -> (reading: Reading) {
    measurement, config := &app.measurement, app.config
    note_target, lock_in := &measurement.note_target, measurement.strobe_lock_in
    reading.pitch = core.run_pitch_detection(&measurement.pitch_detector, note_target.pitch)
    core.run_phase_detection(lock_in, reading.pitch.is_tonal)

    // The track the readout follows, the 2nd partial's or the fundamental's. The strobe keeps the note lit while
    // it shows it. Retuned to another note the tracks start over, their reading was from the note before.
    ready: bool
    partial: f32 = 2 if config.readout_source == .OCTAVE else 1
    measurement.readout_track, ready = core.strobe_readout_track(lock_in, measurement.readout_track, partial)
    if core.update_note_target(note_target, reading.pitch, core.strobe_shows_note(lock_in)) {
        retune(measurement, app.config)
        ready = false
    }

    // What sets the scope's scale again, see feed_scope: an attack on the input, its level clear of the noise
    // like a track's onset, or the note lit from silence, a swell or a bow easing in has no attack
    loud := reading.pitch.snr_db > core.NOISE_FLOOR_SNR_DB_THRESHOLD
    measurement.attacked = core.input_attack(&measurement.input_attack, reading.pitch.rms, loud, gfx.frame_time())
    measurement.note_lit = note_target.active && !measurement.was_active
    measurement.was_active = note_target.active

    out_of_range := core.out_of_range(note_target)
    reading.steady = core.readout_pitch(note_target)
    steady := &reading.steady

    // The whole wave's readout is the pitch detection's, from its first detection. A guitar or piano string's
    // partials run a little sharp, so it reads a few cents over the fundamental's track.
    // Otherwise the readout is the strobe's, 0 where the chosen partial's track stands still, none until a track
    // has settled after the pluck. The Hz move along with the cents. A fading note keeps its track's last
    // reading, also once the note target lets go of it.
    if config.readout_source == .BLEND {
        reading.readout_shown = note_target.steady_freq != 0 && !out_of_range
    } else {
        reading.readout_shown = ready && !out_of_range
        reading.readout_shown &&= abs(lock_in.bands[measurement.readout_track].err_cents) <= core.READOUT_RANGE_CENTS

        if reading.readout_shown {
            band := lock_in.bands[measurement.readout_track]
            steady.detected_freq = core.freq_at_cents(steady.detected_freq, band.err_cents - steady.err_cents)
            steady.err_cents = band.err_cents
        }
    }

    // The readout's cents, the strobe's so an in tune note is on the middle line, none before a track settled.
    // The track the readout followed carries on as the note decays and the readout gives way, the line as lit as
    // its stripes and dark with them, not the noisy weak detections.
    if reading.readout_shown && config.readout_source != .BLEND do measurement.traced_track = measurement.readout_track

    // Lit, the readout is the track's as it measures. Dark, it keeps the last one shown: the track goes on
    // measuring whatever passes through its band, the room's noise would read as a wandering pitch. Another
    // note starts over, see retune, and so does another note than a locked one, the reading is of that note
    // no more.
    held := &measurement.held_readout
    if note_target.active {
        if reading.readout_shown do held^ = {true, steady.detected_freq, steady.err_cents}
        if out_of_range do held^ = {}
    } else {
        reading.readout_shown = held.shown
        steady.detected_freq, steady.err_cents = held.freq, held.cents
    }

    light: f32 = 1
    traced_cents := math.nan_f32()

    // The whole wave's readout while the note is lit, as far out as a track's
    if config.readout_source == .BLEND {
        if note_target.active && reading.readout_shown && abs(steady.err_cents) <= core.READOUT_RANGE_CENTS {
            traced_cents = steady.err_cents
        }
    } else if measurement.traced_track >= 0 {
        band := lock_in.bands[measurement.traced_track]
        fade := core.STROBE_FADE_SNR_DB
        light = math.smoothstep(fade[0], fade[1], band.envelope_snr_db)
        if light == 0 || !band.in_range do measurement.traced_track = -1

        if measurement.traced_track >= 0 && !out_of_range && abs(band.err_cents) <= core.READOUT_RANGE_CENTS {
            traced_cents = band.err_cents
        }
    }

    record_trace(&app.displays.trace, traced_cents, light, reading.pitch.fresh, gfx.frame_time())

    // The spectrum of what came in, only while it's the display
    if config.strobe_display_type == .SPECTRUM do update_spectrum_display(&app.displays.spectrum, config.spectrum_windows)

    return
}

// The new audio onto the scope's screen, while its views or the tracks the lamp turns show it. strobe_shows
// is false while a sheet covers the whole strobe area.
feed_scope :: proc(app: ^App, strobe_shows: bool) {
    measurement, config := &app.measurement, app.config
    scope := &measurement.scope

    type := config.strobe_display_type
    shown := type == .SCOPE || type == .LAMP || (type == .STROBE && config.strobe_source == .LAMP)

    if !shown || !strobe_shows {
        core.skip_scope(scope)

        // The lamp's tracks start over on a dark screen too, the phases they turned by are stale
        measurement.strobe_lamp.freq_hz = 0
        return
    }

    // At the strobe's frequency, not the target note's: that one jumps an octave with the detection while
    // the strobe stays, and every change starts with a dark screen. The scale stays, a note that starts comes
    // with an attack: a dying low note's strobe hands over to its 2nd partial an octave up, and as a new note
    // its weak tail was set to the full height again. Still being set, it starts over at the new frequency, the
    // average it was following is gone. The first one sets it.
    strobe_hz := f64(measurement.strobe_lock_in.base_freq_hz)
    if scope.freq_hz != strobe_hz {
        autoset := scope.freq_hz == 0 || core.scope_autosetting(scope)
        core.set_scope_freq(scope, strobe_hz, autoset = autoset)
    }

    // The lamp is the screen from above, it needs the sweep over time, and so do the tracks it turns
    sweep := config.scope_sweep if config.strobe_display_type == .SCOPE else .TIME
    if scope.sweep != sweep do core.set_scope_sweep(scope, sweep)

    // In periods of the strobe's frequency, the smear and the waver per cent look the same on every note. The
    // scope view is the sweeps averaged over its own span, the lamp's screen fades over the lamp's, and so does
    // the screen the lamp's tracks turn by.
    periods := config.scope_averaging_periods if config.strobe_display_type == .SCOPE else config.screen_persistence_periods
    scope.persistence_s = f64(periods) / strobe_hz

    // Starts over, the average stopped while the screen faded and the other way round
    average_sweeps := config.strobe_display_type == .SCOPE
    if scope.average_sweeps != average_sweeps {
        scope.average_sweeps = average_sweeps
        core.clear_scope(scope)
        core.autoset_scope(scope)
    }

    // Starts over, the sweeps averaged so far are at the other gain
    uniform_gain := config.scope_gain == .UNIFORM
    if scope.uniform_gain != uniform_gain {
        scope.uniform_gain = uniform_gain
        core.clear_scope(scope)
        core.autoset_scope(scope)
    }

    // An attack on the input or a note lit from silence sets the scope's scale again, see measure. Not the
    // tracks' onsets: they start over as the strobe moves, and a violin's partials swing with its vibrato.
    if measurement.attacked || measurement.note_lit do core.autoset_scope(scope)

    // The lamp and its tracks take the wave as it comes. Turned on or off, the average starts over: the sweeps
    // in it went through the low-pass or didn't, and are placed by its delay or not, the next ones stepped
    // from them.
    lowpass := config.scope_lowpass && config.strobe_display_type == .SCOPE
    if scope.lowpass != lowpass {
        scope.lowpass = lowpass
        core.clear_scope(scope)
    }

    scope.noise_floor = measurement.pitch_detector.noise_floor.level
    scope.snr_db = measurement.pitch_detector.snr_db
    core.update_scope(scope)
}
