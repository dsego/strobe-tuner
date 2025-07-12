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

NoteDetectionMode :: enum {
    AUTO,
    MANUAL,
}


StrobeDisplayType :: enum {
    CURVED_TRACKS,
    SPINNING_WHEEL,
}

TuningPreset :: enum {
    CHROMATIC,
    GUITAR_STD,
    UKULELE_STD,
}


Config :: struct {
    // Initial target frequency for the strobe
    target_freq_hz:               f32,

    // eg A 440Hz
    pitch_standard:               f32,

    // how many spinning bands to show
    strobe_intervals:             [MAX_INTERVALS]f32,
    strobe_intervals_index:       int,

    // FFT length for the pitch detector, e.g. 4096 samples
    pitch_detect_fft_size:        int,

    // audio card sampling rate, e.g. 44.100 Hz
    samplerate:                   int,

    // harmonic to track multiple frequencies or "vernier" to track one pitch at different sensitivities
    strobe_mode:                  core.StrobeMode,

    // the sensitivity or speed of the base strobe band,
    // i.e. how fast should the spinning effect be in response to the phase difference
    strobe_speed:                 f32,

    // if multiple strobe bands, this sensitivity multiplier will be applied to subsequent spinning bands
    speed_multiplier:             f32,

    // contrast or gain of the strobe wheel, higher contrast will amplify the signal to make the stripes more prominent
    strobe_contrast:              f32,

    // auto detection vs manual selection of note to track
    note_detection_mode:          NoteDetectionMode,

    // How to render the strobe effect
    strobe_display_type:          StrobeDisplayType,

    // Color scheme for strobe track display, two hex values
    strobe_color_1:               u32 "color",
    strobe_color_2:               u32 "color",
    strobe_colorway:              StrobeColorway,

    // attenuate strobe effect when it spins so fast it becomes distracting
    apply_attenuation:            bool,
    tuning_preset:                TuningPreset,
    partial_labels:               PartialLabelType,
    pitch_detection_clarity_low:  f32,
    pitch_detection_rms_low:      f32,
    pitch_detection_clarity_high: f32,
    pitch_detection_rms_high:     f32,
    auto_gain_control:            bool,
    max_auto_gain:                f32,
    auto_gain_threshold_low_0:    f32,
    auto_gain_threshold_low_1:    f32,
    auto_gain_threshold_high:     f32,
}

@(private)
config_defaults :: Config {
    apply_attenuation            = true,
    target_freq_hz               = 110.0,
    pitch_standard               = 440.0,
    strobe_intervals             = {1, 2, 4, 0, 0, 0, 0, 0},
    strobe_intervals_index       = 0,
    pitch_detect_fft_size        = 8192,
    samplerate                   = 48_000,
    strobe_mode                  = .HARMONIC_MODE,
    note_detection_mode          = .AUTO,
    strobe_speed                 = 0.025,
    speed_multiplier             = 2.0,
    strobe_contrast              = 1000.0,
    strobe_display_type          = .CURVED_TRACKS,
    strobe_colorway              = .VIBRANT_RED,

    // Custom colors
    strobe_color_1               = 0x0,
    strobe_color_2               = 0x0,

    //
    tuning_preset                = .CHROMATIC,
    partial_labels               = .MULTIPLES,
    pitch_detection_clarity_low  = 0.9,
    pitch_detection_clarity_high = 0.95,
    pitch_detection_rms_low      = 0.001,
    pitch_detection_rms_high     = 0.01,
    auto_gain_control            = false,
    max_auto_gain                = 1000.0,
    auto_gain_threshold_low_0    = 0.0005,
    auto_gain_threshold_low_1    = 0.001,
    auto_gain_threshold_high     = 0.005,
}


get_config_defaults :: proc() -> Config {
    return config_defaults
}

// Load config from the standard OS path, eg ~/Library/Application Support/StrobeTuner/config.ini on MacOS.
load_config :: proc() -> Config {

    config := get_config_defaults()

    ini_map, ok := load_ini()
    defer if ok do ini.delete_map(ini_map)
    section := ini_map[""]

    fields := reflect.struct_fields_zipped(Config)

    for field in fields {
        value := reflect.struct_field_value(config, field)
        ptr := rawptr(uintptr(&config) + field.offset)

        #partial switch v in field.type.variant {
        case reflect.Type_Info_Named:
            named := field.type.variant.(reflect.Type_Info_Named)
            value, ok := reflect.enum_from_name_any(field.type.id, section[field.name])
            if ok {
                ptr_int := cast(^int)ptr
                ptr_int^ = cast(int)value
            }
        case reflect.Type_Info_Float:
            value, ok := strconv.parse_f32(section[field.name])
            if ok {
                ptr_f32 := cast(^f32)ptr
                ptr_f32^ = value
            }
        case reflect.Type_Info_Integer:
            value, ok := strconv.parse_int(section[field.name])
            if ok {
                ptr_int := cast(^int)ptr
                ptr_int^ = value
            }
        case reflect.Type_Info_Boolean:
            value, ok := strconv.parse_bool(section[field.name])
            if ok {
                ptr_bool := cast(^bool)ptr
                ptr_bool^ = value
            }
        case reflect.Type_Info_Array:
            trimmed := strings.trim(section[field.name], "[] ")
            if len(trimmed) > 0 {
                split := strings.split(trimmed, ",")
                defer delete(split)
                ptr_array := cast(^[MAX_INTERVALS]f32)ptr
                l := len(split)
                for i in 0 ..< l {
                    trimmed := strings.trim(split[i], " ")
                    value, ok := strconv.parse_f32(trimmed)
                    if ok {
                        ptr_array^[i] = value
                    }
                }
                // Fill in the rest
                for i in l ..< MAX_INTERVALS do ptr_array^[i] = 0.0
            }
        }
    }

    return config
}


save_config :: proc(config: Config) {
    ini_map := ini.Map{}
    defer ini.delete_map(ini_map)

    section: map[string]string = {}
    fields := reflect.struct_fields_zipped(Config)

    for field in fields {
        value := reflect.struct_field_value(config, field)
        key := strings.clone(field.name)
        if field.tag == "color" {
            section[key] = fmt.aprintf("%#X", value)
        } else {
            section[key] = fmt.aprintf("%v", value)
        }
    }

    ini_map[""] = section

    save_ini(ini_map)
}
