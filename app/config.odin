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


import "base:intrinsics"
import "base:runtime"
import "core:encoding/ini"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"


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
    SCOPE, // the wave itself, like an oscilloscope synced to the strobe's frequency, see core/scope.odin
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
    LOCK_IN, // each track's DFT on the samples, against a reference at its partial, see core/phase.odin
    LAMP, // the lamp's screen, a DFT bin of it for each track's partial, see lamp_bands
}


Config :: struct {
    // The strobe's note at the start, the one it was on at the end
    target_freq_hz:               f32,

    // Concert A, e.g. 440 Hz
    pitch_standard:               f32,

    // The partial of each track, harmonic mode, the tracks are the ones of 1 and more, 0 is no track
    strobe_intervals:             [core.MAX_BANDS]f32,
    strobe_intervals_index:       int, // the last of INTERVAL_OPTIONS picked with the I key
    // per track, harmonic mode: the target this many cents off the exact partial, eg a stretched octave
    strobe_offsets_cents:         [core.MAX_BANDS]f32,
    // per track, harmonic mode: on top of strobe_speed, 1 leaves it as is
    strobe_speeds:                [core.MAX_BANDS]f32,

    // FFT length for the pitch detection, the window is half of it, e.g. 8192 for 4096 samples
    pitch_detect_fft_size:        int,

    // The input's sample rate, e.g. 48000 Hz
    samplerate:                   int,

    // A track per partial, or every track on the fundamental at more and more speed
    strobe_mode:                  core.StrobeMode,

    // How fast the strobe turns per cent of detuning, the FAST toggle steps through RESPONSE_SPEEDS
    strobe_speed:                 f32,

    // Fine mode, each track turns this much faster than the one under it
    speed_multiplier:             f32,

    strobe_display_type:          StrobeDisplayType,
    strobe_shape:                 StrobeShape,
    strobe_source:                StrobeSource,

    strobe_colorway:              StrobeColorway,
    strobe_blur:                  bool,
    // average the strobe pattern over its movement since the previous frame, reduces shimmer when it spins fast
    motion_blur:                  bool,
    // lamp-lit look of the old mechanical strobe tuners in the colorway's hue, see glow_params
    strobe_glow:                  bool,
    prevent_strobe_octave_jumps:  bool,

    // The label of each track, e.g. its partial 1×, its note A2 or its frequency 110 Hz
    partial_labels:               PartialLabelType,

    // all the notes in a sliding row, off shows just the note with arrows either side to step it
    chromatic_ruler:              bool,

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

    // The pitch detection: a strong pitch is this clear at least and this far over the noise floor, a weak one
    // less clear than clarity_low. The noise floors don't learn the level over their threshold.
    pitch_detection_clarity_low:  f32,
    pitch_detection_clarity_high: f32,
    noise_floor_snr_db_threshold: f32,
    pitch_detection_min_snr_db:   f32,

    // How long a new note is detected in a row before the strobe switches to it
    note_switch_s:                f32,

    // The high-pass before the pitch detection, it takes out DC and low frequency rumble, 0 for none
    highpass_cutoff_hz:           f32,

    // Add in the DFT bins 5 cents either side, a slightly detuned note keeps its level, see set_dft_freq
    use_phase_average:            bool,

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

config_defaults :: Config {
    target_freq_hz               = 110.0,
    pitch_standard               = 440.0,
    strobe_intervals             = INTERVAL_OPTIONS[0],
    strobe_intervals_index       = 0,
    strobe_offsets_cents         = {0, 0, 0, 0, 0},
    strobe_speeds                = {1, 1, 1, 1, 1},
    pitch_detect_fft_size        = 8192,
    samplerate                   = 48_000,
    strobe_mode                  = .HARMONIC,
    strobe_speed                 = 0.0125,
    speed_multiplier             = 2.0,
    strobe_display_type          = .STROBE,
    strobe_shape                 = .CURVED,
    strobe_source                = .LOCK_IN,
    strobe_colorway              = .VIBRANT_RED,
    strobe_blur                  = true,
    motion_blur                  = true,
    strobe_glow                  = true,
    prevent_strobe_octave_jumps  = true,
    partial_labels               = .MULTIPLES,
    chromatic_ruler              = true,
    instrument                   = .CHROMATIC,
    preset                       = -1,
    transpose                    = 0,
    pitch_detection_clarity_low  = 0.9,
    pitch_detection_clarity_high = 0.98,
    noise_floor_snr_db_threshold = 10,
    pitch_detection_min_snr_db   = 2,
    note_switch_s                = 0.05, // the last detection strong or the run steady, at 0 a note under hum flickers
    highpass_cutoff_hz           = 60, // below guitar low E (82Hz), lower notes read from their harmonics
    use_phase_average            = true,
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

// From the standard OS path, e.g. ~/Library/Application Support/<APP_NAME>/config.ini on macOS, see
// config_directory. What's missing or doesn't parse keeps its default.
load_config :: proc() -> Config {
    config := config_defaults

    ini_map, loaded := load_ini()
    defer if loaded do ini.delete_map(ini_map)
    section := ini_map[""]

    fields := reflect.struct_fields_zipped(Config)

    for field in fields {
        ptr := rawptr(uintptr(&config) + field.offset)

        #partial switch _ in field.type.variant {
        case reflect.Type_Info_Named:
            if value, ok := reflect.enum_from_name_any(field.type.id, section[field.name]); ok {
                write_int_field(ptr, field.type.size, int(value))
            }
        case reflect.Type_Info_Float:
            if value, ok := strconv.parse_f32(section[field.name]); ok {
                (^f32)(ptr)^ = value
            }
        case reflect.Type_Info_Integer:
            if value, ok := strconv.parse_int(section[field.name]); ok {
                write_int_field(ptr, field.type.size, value)
            }
        case reflect.Type_Info_Boolean:
            if value, ok := strconv.parse_bool(section[field.name]); ok {
                (^bool)(ptr)^ = value
            }
        case reflect.Type_Info_Array:
            listed := strings.trim(section[field.name], "[] ")
            if len(listed) > 0 {
                split := strings.split(listed, ",")
                defer delete(split)
                // Of f32 or int, an array of arrays is read in the order it's written out
                element_type := field.type
                for {
                    array, is_array := reflect.type_info_base(element_type).variant.(reflect.Type_Info_Array)
                    if !is_array do break
                    element_type = array.elem
                }
                for i in 0 ..< field.type.size / element_type.size {
                    element := rawptr(uintptr(ptr) + uintptr(i * element_type.size))
                    // Fill in the rest, one that doesn't parse keeps its default
                    if i >= len(split) {
                        runtime.mem_zero(element, element_type.size)
                        continue
                    }
                    trimmed := strings.trim(split[i], "[] ")
                    if reflect.is_float(element_type) {
                        if value, ok := strconv.parse_f32(trimmed); ok do (^f32)(element)^ = value
                    } else if reflect.is_integer(element_type) {
                        if value, ok := strconv.parse_int(trimmed); ok do write_int_field(element, element_type.size, value)
                    }
                }
            }
        }
    }

    return config
}


// Write with the field's own size, writing a full int into a smaller field clobbers the next one
write_int_field :: proc(ptr: rawptr, size: int, value: int) {
    switch size {
    case 1:
        (^u8)(ptr)^ = u8(value)
    case 2:
        (^u16)(ptr)^ = u16(value)
    case 4:
        (^u32)(ptr)^ = u32(value)
    case 8:
        (^int)(ptr)^ = value
    case:
        fmt.println("Unsupported config field size", size)
    }
}

save_config :: proc(config: Config) {
    ini_map := ini.Map{}
    defer ini.delete_map(ini_map)

    section: map[string]string = {}
    fields := reflect.struct_fields_zipped(Config)

    for field in fields {
        value := reflect.struct_field_value(config, field)
        key := strings.clone(field.name)
        section[key] = fmt.aprintf("%v", value)
    }

    ini_map[""] = section

    save_ini(ini_map)
}
