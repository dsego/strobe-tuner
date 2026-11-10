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


import "core:strings"

import "../audio"
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
    SPECTRUM, // what the pitch detection hears, its peaks named, see src/app/spectrum_display.odin
}

StrobeShape :: enum {
    FLAT, // the curved tracks straightened, the top of each arc
    WHEEL,
    CURVED,
}

// The partials a track can follow, 1½ is the fifth above the fundamental
TRACK_PARTIALS :: [?]f32{1, 1.5, 2, 3, 4, 5, 6, 7, 8}
TRACK_OFFSET_MAX_CENTS :: 50
TRACK_OFFSET_STEP_CENTS :: 0.5

// Strobe speeds per cent of detuning, fast spins 2× faster for the final adjustment
STROBE_SPEED :: 0.025
STROBE_SPEED_FAST :: 0.05

strobe_speed :: proc(config: ^Config) -> f32 {
    return STROBE_SPEED_FAST if config.strobe_fast else STROBE_SPEED
}

// A track's own spin rate on top of the strobe's, its sheet's Spin rate
TRACK_SPEED_STEPS :: [4]f32{0.25, 0.5, 1, 2}

// The readout's fit time, the Readout speed setting, see core.READOUT_FIT_S. Its weight averages twice as far
// back: the longer spans several cycles of a vibrato and reads the mean pitch, and shows a string being tuned about a
// second later
READOUT_FIT_STEPS_S :: [2]f32{core.READOUT_FIT_S, 0.4}

// What the readout reads, the Readout setting. On a guitar or piano string the partials run a little sharp,
// each track reads its own cents, and the whole wave reads a blend of them, the way most tuners measure.
ReadoutSource :: enum {
    FUNDAMENTAL, // the 1× track, see core.strobe_readout_track
    OCTAVE, // the 2× track, the fundamental's without one
    BLEND, // the pitch detection's, the period of the whole wave or the harmonic stack's same mix, the louder partials count more, see core.readout_pitch
}

// Concert A, from French baroque's 392 to Venetian's 466 with room either side. Much over 480 C8 nears the
// pitch detection's low-pass, see core.PITCH_LOWPASS_HZ
PITCH_STANDARD_MIN :: 390
PITCH_STANDARD_MAX :: 480

// The Concert A presets, a tap back to 440 from anything else: the standard, the orchestras' 442, and 432
CONCERT_A_PRESETS_HZ :: [3]f32{440, 442, 432}

// The lamp's persistence and the scope's averaging, off, short, medium and long, in periods of the strobe's
// frequency, the Persistence and Averaging settings, one each. A detuned wave drifts across the screen by the
// cycles it slips, as many a second as the note is high: in milliseconds a high note smears further and
// averages more cycles than a low one off by the same cents, in periods they look the same. Medium is 40 ms
// at A4, about the window of the old narrow bands.
PERSISTENCE_STEPS_PERIODS :: [4]f32{0, 7, 18, 66}

// The trace's span, short, medium and long, and its range from the middle to the edge, narrow and wide.
// Narrow for an instrument's pluck settling, wide for a voice's vibrato, half a semitone is as far as a
// note can be off before it's the next one.
TRACE_SPAN_STEPS_S :: [3]f32{1, 2, 5}
TRACE_RANGE_STEPS_CENTS :: [2]f32{25, 50}

// The spectrum's window, as many of the detector's: 85, 170 and 340 ms at 48 kHz. Longer, two partials closer
// together come apart and a pluck takes longer to show, the power is averaged over as long.
SPECTRUM_WINDOW_STEPS :: [3]f32{1, 2, 4}

// The Gain of the scope and of the lamp, each its own: the wave drawn from as high as its loudness says to four
// times as high, a quarter a step. A hum at half the height fills it at 200%, a louder note runs off the
// screen, on the lamp its crest is lit wider.
SCOPE_GAIN_MIN :: 1
SCOPE_GAIN_MAX :: 4
SCOPE_GAIN_STEP :: 0.25

// The scope's beam, see draw_scope_screen
ScopeBeam :: enum {
    SOLID, // one line through the sweeps averaged over scope_averaging_periods
    PHOSPHOR, // the same line as bright as the beam stays, dim where it moves fast like an analog scope's
}

// The spectrum's height, see src/app/spectrum_display.odin
SpectrumScale :: enum {
    SNR, // each bin over the noise around it, the room flat along the bottom
    DBFS, // the level, sloping down with the room, how loud the input is
}

// What's written over the spectrum's peaks
SpectrumLabels :: enum {
    OFF,
    NOTE,
    HZ,
    BOTH,
}


// Grouped by topic. The order is free, every field is its own key in the ini, see load_config.
// Only what the musician picks. What's tuned in the code, e.g. the pitch detection's thresholds, are
// constants: every field is saved, a saved value would keep an install from getting a better one.
Config :: struct {
    // --- Tuning ---

    // The strobe's note at the start, the one it was on at the end
    target_freq_hz:               f32,

    // Concert A, e.g. 440 Hz
    pitch_standard:               f32,

    // What's tuned to: the built-in instrument, or a preset counted from 0. See gui_instrument.
    // Every note, or only an instrument's strings in one of its TUNINGS, or a custom preset's notes.
    instrument:                   Instrument,
    preset:                       Maybe(int),
    // per built-in instrument: the tuning counted from 0 in its TUNINGS, and the fret a capo is on, the
    // strings sound that many semitones up, 0 is none
    instrument_tunings:           [Instrument]int,
    instrument_capos:             [Instrument]int,
    // chromatic, semitones the note is shown above the sounding pitch, 0 to 11, a Bb instrument reads 2
    transpose:                    int,

    // Per preset slot like the built-ins: its Instrument, tuning, capo and transpose
    preset_instruments:           [PRESET_SLOTS]Instrument,
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

    // The partial of each track, harmonic mode, the tracks are the ones of 1 and more, 0 is no track
    strobe_intervals:             [core.MAX_BANDS]f32,
    // per track, harmonic mode: the target this many cents off the exact partial, eg a stretched octave
    strobe_offsets_cents:         [core.MAX_BANDS]f32,
    // per track, harmonic mode: on top of strobe_speed, 1 leaves it as is
    strobe_speeds:                [core.MAX_BANDS]f32,

    // The Spin rate setting, 200% turns at STROBE_SPEED_FAST per cent of detuning instead of STROBE_SPEED
    strobe_fast:                  bool,

    // The Readout speed setting, how long the readout's fit through the phase averages, see READOUT_FIT_STEPS_S
    readout_fit_s:                f32,

    // The Readout setting, the track or the whole wave the readout, the gauge and the trace read
    readout_source:               ReadoutSource,

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

    // how long the lamp's screen remembers, in periods of the strobe's frequency, 0 keeps the newest sweep only
    screen_persistence_periods:   f32,
    // what the lamp shows, the positive half of the wave like a lamp, the wave as it is, or the two halves
    // split, tapping it goes round them in that order
    lamp_shape:                   core.ScopeShape,
    // the lamp's own low-pass, the scope's filter: the room's hiss and the fine wiggles out of the stripes
    lamp_lowpass:                 bool,
    // the scope over time or round a circle, tapping it flips them
    scope_sweep:                  core.ScopeSweep,
    // how many periods of the strobe's frequency the scope shows across or round the circle, 1 to
    // core.SCOPE_MAX_PERIODS, the lamp always core.SCOPE_PERIODS
    scope_periods:                int,
    // the scope's wave this many times as high as its loudness says, SCOPE_GAIN_MIN to SCOPE_GAIN_MAX, and the
    // lamp's the same way
    scope_gain:                   f32,
    lamp_gain:                    f32,
    // the scope view keeps the first few partials of the wave and drops the fine wiggles above them
    scope_lowpass:                bool,
    // how many periods of the strobe's frequency the scope's sweeps are averaged over, the lamp's persistence
    // is its own, 0 draws the newest sweep only
    scope_averaging_periods:      f32,
    // the scope's beam through the averaged sweeps, a solid line or an analog scope's phosphor, as bright as
    // the beam stays
    scope_beam:                   ScopeBeam,

    // Trace display: how many seconds it shows, and how many cents from the middle to its edges
    trace_seconds:                f32,
    trace_range_cents:            f32,

    // Spectrum display: its window as many of the detector's, see SPECTRUM_WINDOW_STEPS, its height and what
    // the peaks are labelled with
    spectrum_windows:             f32,
    spectrum_scale:               SpectrumScale,
    spectrum_labels:              SpectrumLabels,
    // a line across at the loudest peak with how high it is, its SNR or its level in dBFS as the scale says
    spectrum_peak_level:          bool,

    // --- Input ---

    // The input picked by its name, "" follows the system's default. One that isn't connected waits for it
    // on the default. Owned by the config, see set_input_device.
    input_device:                 string,
    // its channel measured, counted from 1, or audio.MIX_CHANNELS for all of them averaged. A device without
    // as many averages them and the pick stays for the one it was made on, another device picked by hand
    // starts on the average.
    input_channel:                int,

    // --- Window ---

    // The desktop window's size as it was last used, in points. 0 opens it at the strobe's size and puts it
    // back there: what a reset or Cmd+0 leaves. A phone leaves it 0. See follow_window_size.
    window_size:                  [2]int,
    // and where its top left corner was, in the system's points across the displays. Only with a size, a
    // window not on any display any more opens in the middle of the main one.
    window_position:              [2]int,

    // --- Unlock ---

    // How many of the free minutes before the reminder are used, kept through a reset, see UNLOCK_FREE_S
    unlock_free_s:                f32,
}

// In the order of Config
config_defaults :: Config {
    // --- Tuning ---
    target_freq_hz               = 110.0,
    pitch_standard               = 440.0,
    instrument                   = .CHROMATIC,
    preset                       = nil,
    transpose                    = 0,

    // --- Strobe ---
    strobe_mode                  = .HARMONIC,
    strobe_intervals             = {1, 2, 4, 0, 0},
    strobe_offsets_cents         = {0, 0, 0, 0, 0},
    strobe_speeds                = {1, 1, 1, 1, 1},
    strobe_fast                  = false,
    readout_fit_s                = core.READOUT_FIT_S,
    readout_source               = .FUNDAMENTAL,

    // --- Display ---
    strobe_display_type          = .STROBE,
    strobe_shape                 = .CURVED,
    strobe_colorway              = .VIBRANT_RED,
    strobe_glow                  = true,
    partial_labels               = .MULTIPLES,
    show_band_cents              = false,
    screen_persistence_periods   = 18,
    lamp_shape                   = .SPLIT,
    lamp_lowpass                 = true,
    scope_sweep                  = .TIME,
    scope_periods                = core.SCOPE_PERIODS,
    scope_gain                   = 1,
    lamp_gain                    = 1,
    scope_lowpass                = true,
    // Short, 16 ms at A4: the noise and the circle's step at its top where a changing wave doesn't close smooth
    // out, and the line follows a string being tuned. Off, the line steps there whenever the wave changes in a
    // sweep and it read as a glitch.
    scope_averaging_periods      = 7,
    scope_beam                   = .SOLID,
    trace_seconds                = 2,
    trace_range_cents            = 50,
    spectrum_windows             = 2,
    spectrum_scale               = .SNR,
    spectrum_labels              = .BOTH,
    spectrum_peak_level          = true,

    // --- Input ---
    input_device                 = "",
    input_channel                = audio.MIX_CHANNELS,

    // --- Window ---
    window_size                  = {},
    window_position              = {},

    // --- Unlock ---
    unlock_free_s                = 0,
}


// Back to the defaults, on chromatic. The presets stay, their note offsets are tuned in by hand, and the
// input, it's picked on its own sheet.
reset_config :: proc(config: ^Config) {
    kept := config^
    config^ = config_defaults
    config.preset_instruments = kept.preset_instruments
    config.preset_tunings, config.preset_capos = kept.preset_tunings, kept.preset_capos
    config.preset_transposes = kept.preset_transposes
    config.note_offset_counts, config.note_offset_notes = kept.note_offset_counts, kept.note_offset_notes
    config.note_offset_cents = kept.note_offset_cents
    config.input_device, config.input_channel = kept.input_device, kept.input_channel
    config.unlock_free_s = kept.unlock_free_s
}

// The config's own copy of the name, the one it had is freed. Not while a copy of the config still points
// at it, see follow_input.
set_input_device :: proc(config: ^Config, name: string) {
    if name == config.input_device do return

    if len(config.input_device) > 0 {
        delete(config.input_device)
    }

    config.input_device = strings.clone(name) if len(name) > 0 else ""
}
