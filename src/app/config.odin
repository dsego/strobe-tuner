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


import "../core"


PartialLabelType :: enum {
    NONE,
    MULTIPLES,
    FREQUENCY,
    NOTE_NAMES,
}

// The views in the settings' display list, in its order
StrobeDisplayType :: enum {
    STROBE, // the tracks, in one of the StrobeShapes
    SCOPE, // the wave itself, like an oscilloscope synced to the strobe's frequency, see src/core/scope.odin
    TRACE, // a line of the cents over the last few seconds
    LAMP, // the scope from above, stripes as bright as the wave is high, the lamp of a mechanical strobe
}

StrobeShape :: enum {
    FLAT, // the curved tracks straightened, the top of each arc
    WHEEL,
    CURVED,
}

// What turns the tracks
StrobeSource :: enum {
    LOCK_IN, // each track's DFT on the samples, against a reference at its partial, see src/core/phase.odin
    LAMP, // the lamp's screen, a DFT bin of it for each track's partial, see lamp_bands
}

// The track presets the I key steps through
INTERVAL_OPTIONS: [3][core.MAX_BANDS]f32 : {
    {1, 2, 4, 0, 0},
    {1, 1.5, 2, 0, 0},
    {1, 2, 3, 0, 0},
}

// The partials a track can follow, 1½ is the fifth above the fundamental like in the 1 1½ 2 preset
TRACK_PARTIALS :: [?]f32{1, 1.5, 2, 3, 4, 5, 6, 7, 8}
TRACK_OFFSET_MAX_CENTS :: 50
TRACK_OFFSET_STEP_CENTS :: 0.5

// Strobe speeds per cent of detuning, fast spins 2× faster for the final adjustment
STROBE_SPEED :: 0.025
STROBE_SPEED_FAST :: 0.05

strobe_speed :: proc(config: ^Config) -> f32 {
    return STROBE_SPEED_FAST if config.strobe_fast else STROBE_SPEED
}

PITCH_STANDARD_MIN :: 400
PITCH_STANDARD_MAX :: 480

// The scope's and the lamp's persistence, short, medium and long
SCOPE_PERSISTENCE_STEPS_MS :: [3]f32{15, 40, 150}

// The trace's span, short, medium and long, and its range from the middle to the edge, narrow and wide.
// Narrow for an instrument's pluck settling, wide for a voice's vibrato, half a semitone is as far as a
// note can be off before it's the next one.
TRACE_SPAN_STEPS_S :: [3]f32{1, 2, 5}
TRACE_RANGE_STEPS_CENTS :: [2]f32{25, 50}


// Grouped by topic. The order is free, every field is its own key in the ini, see load_config.
// Only what the musician picks. What's tuned in the code, e.g. the pitch detection's thresholds, are
// constants: every field is saved, a saved value would keep an install from getting a better one.
Config :: struct {
    // --- Tuning ---

    // The strobe's note at the start, the one it was on at the end
    target_freq_hz:               f32,

    // Concert A, e.g. 440 Hz
    pitch_standard:               f32,

    // What's tuned to: the built-in instrument, or a preset counted from 0, -1 for none. See gui_instrument.
    // Every note, or only an instrument's strings in one of its TUNINGS.
    instrument:                   Instrument,
    preset:                       int,
    // per built-in instrument, by its value: the tuning counted from 0 in its TUNINGS, and the fret a capo
    // is on, the strings sound that many semitones up, 0 is none
    instrument_tunings:           [len(Instrument)]int,
    instrument_capos:             [len(Instrument)]int,
    // chromatic, semitones the note is shown above the sounding pitch, 0 to 11, a Bb instrument reads 2
    transpose:                    int,

    // Per preset slot like the built-ins: its Instrument, tuning, capo and transpose
    preset_instruments:           [PRESET_SLOTS]int,
    preset_tunings:               [PRESET_SLOTS]int,
    preset_capos:                 [PRESET_SLOTS]int,
    preset_transposes:            [PRESET_SLOTS]int,
    // per preset, the rows of the note offsets: how many there are, the note of each counted from A0, and
    // the cents it's tuned off equal temperament. A row at 0 cents is kept. On a stringed instrument the
    // rows are its strings in the order they're tuned, only the cents are kept. See gui_note_offsets.
    note_offset_counts:           [PRESET_SLOTS]int,
    note_offset_notes:            [PRESET_SLOTS][MAX_NOTE_OFFSETS]int,
    note_offset_cents:            [PRESET_SLOTS][MAX_NOTE_OFFSETS]f32,

    // --- Strobe ---

    // A track per partial, or every track on the fundamental at more and more speed
    strobe_mode:                  core.StrobeMode,
    strobe_source:                StrobeSource,

    // The partial of each track, harmonic mode, the tracks are the ones of 1 and more, 0 is no track
    strobe_intervals:             [core.MAX_BANDS]f32,
    strobe_intervals_index:       int, // the last of INTERVAL_OPTIONS picked with the I key
    // per track, harmonic mode: the target this many cents off the exact partial, eg a stretched octave
    strobe_offsets_cents:         [core.MAX_BANDS]f32,
    // per track, harmonic mode: on top of strobe_speed, 1 leaves it as is
    strobe_speeds:                [core.MAX_BANDS]f32,

    // The FAST toggle, the strobe turns at STROBE_SPEED_FAST per cent of detuning instead of STROBE_SPEED
    strobe_fast:                  bool,

    // --- Display ---

    strobe_display_type:          StrobeDisplayType,
    strobe_shape:                 StrobeShape,

    strobe_colorway:              StrobeColorway,
    // lamp-lit look of the old mechanical strobe tuners in the colorway's hue, see glow_params
    strobe_glow:                  bool,

    // The label of each track, e.g. its partial 1×, its note A2 or its frequency 110 Hz
    partial_labels:               PartialLabelType,

    // How far off each track's partial is, next to the track
    show_band_cents:              bool,

    // Scope and lamp displays: how long the beam stays on the screen, 0 shows only what came in since
    // the previous frame
    scope_persistence_ms:         f32,
    // what the lamp shows, the positive half of the wave like a lamp or the wave as it is
    lamp_shape:                   core.ScopeShape,
    // the scope over time or as a Lissajous figure against the strobe's frequency, tapping it flips them
    scope_sweep:                  core.ScopeSweep,
    // the screen's height follows the level, or holds the note's loudest to show its decay
    scope_gain:                   core.ScopeGain,

    // Trace display: how many seconds it shows, and how many cents from the middle to its edges
    trace_seconds:                f32,
    trace_range_cents:            f32,
}

// In the order of Config
config_defaults :: Config {
    // --- Tuning ---
    target_freq_hz               = 110.0,
    pitch_standard               = 440.0,
    instrument                   = .CHROMATIC,
    preset                       = -1,
    transpose                    = 0,

    // --- Strobe ---
    strobe_mode                  = .HARMONIC,
    strobe_source                = .LOCK_IN,
    strobe_intervals             = INTERVAL_OPTIONS[0],
    strobe_intervals_index       = 0,
    strobe_offsets_cents         = {0, 0, 0, 0, 0},
    strobe_speeds                = {1, 1, 1, 1, 1},
    strobe_fast                  = false,

    // --- Display ---
    strobe_display_type          = .STROBE,
    strobe_shape                 = .CURVED,
    strobe_colorway              = .VIBRANT_RED,
    strobe_glow                  = true,
    partial_labels               = .MULTIPLES,
    show_band_cents              = false,
    scope_persistence_ms         = 40,
    lamp_shape                   = .HALF_RECTIFIED,
    scope_sweep                  = .TIME,
    scope_gain                   = .AUTO,
    trace_seconds                = 2,
    trace_range_cents            = 25,
}


// Back to the defaults, on chromatic. The presets stay, their note offsets are tuned in by hand.
reset_config :: proc(config: ^Config) {
    kept := config^
    config^ = config_defaults
    config.preset_instruments = kept.preset_instruments
    config.preset_tunings, config.preset_capos = kept.preset_tunings, kept.preset_capos
    config.preset_transposes = kept.preset_transposes
    config.note_offset_counts, config.note_offset_notes = kept.note_offset_counts, kept.note_offset_notes
    config.note_offset_cents = kept.note_offset_cents
}
