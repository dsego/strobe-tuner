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

MAX_INTERVALS :: 8


PartialLabelType :: enum {
    NONE,
    MULTIPLES,
    FREQUENCY,
    NOTE_NAMES,
}

StrobeDisplayType :: enum {
    CURVED_TRACKS,
    SPINNING_WHEEL,
    TRACE, // a line of the cents over the last few seconds
    SCOPE, // the wave itself, like an oscilloscope synced to the strobe's frequency, see core/scope.odin
    RIBBON, // the scope from above, stripes as bright as the wave is high, the classic strobe
}


Config :: struct {
    // Initial target frequency for the strobe
    target_freq_hz:               f32,

    // eg A 440Hz
    pitch_standard:               f32,

    // how many spinning bands to show
    strobe_intervals:             [MAX_INTERVALS]f32,
    strobe_intervals_index:       int,
    // per track, harmonic mode: the target this many cents off the exact partial, eg a stretched octave
    strobe_offsets_cents:         [MAX_INTERVALS]f32,
    // per track, harmonic mode: on top of strobe_speed, 1 leaves it as is
    strobe_speeds:                [MAX_INTERVALS]f32,

    // FFT length for the pitch detector, e.g. 4096 samples
    pitch_detect_fft_size:        int,

    // audio card sampling rate, e.g. 44.100 Hz
    samplerate:                   int,

    // harmonic to track multiple frequencies or "fine" to track one pitch at different sensitivities
    strobe_mode:                  core.StrobeMode,

    // the sensitivity or speed of the base strobe band,
    // i.e. how fast should the spinning effect be in response to the phase difference
    strobe_speed:                 f32,

    // if multiple strobe bands, this sensitivity multiplier will be applied to subsequent spinning bands
    speed_multiplier:             f32,

    // How to render the strobe effect
    strobe_display_type:          StrobeDisplayType,

    strobe_colorway:              StrobeColorway,
    strobe_blur:                  bool,
    // average the strobe pattern over its movement since the previous frame, reduces shimmer when it spins fast
    motion_blur:                  bool,
    // lamp-lit look of the old mechanical strobe tuners in the colorway's hue, see glow_params
    strobe_glow:                  bool,
    prevent_strobe_octave_jumps:  bool,

    // show different type of partial labels, eg partial number 1x, note name A2, or frequency 110Hz
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

    // pitch detection settings
    pitch_detection_clarity_low:  f32,
    pitch_detection_clarity_high: f32,
    noise_floor_snr_db_threshold: f32,
    pitch_detection_min_snr_db:   f32,

    // number of consecutive pitch detections of a new note before the strobe switches to it
    note_switch_confirmations:    int,

    // high-pass filter on the input to remove DC and low frequency rumble, 0 to disable
    highpass_cutoff_hz:           f32,

    // Add in the DFT bins 5 cents either side, a slightly detuned note keeps its level, see set_dft_freq
    use_phase_average:            bool,

    // Show cents offset for each strobe band
    show_band_cents:              bool,

    // Scope and ribbon displays: how long the beam stays on the screen, 0 shows only what came in since
    // the previous frame
    scope_persistence_ms:         f32,
    // what the ribbon shows, the positive half of the wave like a lamp or the wave as it is
    ribbon_shape:                 core.ScopeShape,
    // the scope over time or as a Lissajous figure against the strobe's frequency, tapping it flips them
    scope_sweep:                  core.ScopeSweep,
}

config_defaults :: Config {
    target_freq_hz               = 110.0,
    pitch_standard               = 440.0,
    strobe_intervals             = {1, 2, 4, 0, 0, 0, 0, 0},
    strobe_intervals_index       = 0,
    strobe_offsets_cents         = {0, 0, 0, 0, 0, 0, 0, 0},
    strobe_speeds                = {1, 1, 1, 1, 1, 1, 1, 1},
    pitch_detect_fft_size        = 8192,
    samplerate                   = 48_000,
    strobe_mode                  = .HARMONIC,
    strobe_speed                 = 0.0125,
    speed_multiplier             = 2.0,
    strobe_display_type          = .CURVED_TRACKS,
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
    noise_floor_snr_db_threshold = 10, // to determine if it’s safe to update the noise floor
    pitch_detection_min_snr_db   = 2, // dB
    note_switch_confirmations    = 3, // ~150ms at 20 detections per second, the last one strong or the run steady
    highpass_cutoff_hz           = 60, // below guitar low E (82Hz), lower it for bass
    use_phase_average            = true,
    show_band_cents              = false,
    scope_persistence_ms         = 40,
    ribbon_shape                 = .HALF_RECTIFIED,
    scope_sweep                  = .TIME,
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

// Load config from the standard OS path, eg ~/Library/Application Support/<APP_NAME>/config.ini on MacOS, see config_directory.
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
