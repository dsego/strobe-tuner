package app


import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"


import "../core"


Config :: struct {
    // eg A 440Hz
    pitch_standard:        f32,

    // how many spinning bands to show
    strobe_count:          int,

    // FFT length for the pitch detector, e.g. 4092 samples
    pitch_detect_fft_size: int,

    // audio card sampling rate, e.g. 44.100 Hz
    samplerate:            int,

    // how many samples to use for single bin phase detection
    strobe_window_size:    int,

    // harmonic to track multiple frequencies or "vernier" to track one pitch at different sensitivities
    strobe_mode:           core.StrobeMode,

    // the sensitivity or speed of the base strobe band,
    // i.e. how fast should the spinning effect be in response to the phase difference
    strobe_speed:          f32,

    // if multiple strobe bands, this sensitivity multiplier will be applied to subsequent spinning bands
    speed_multiplier:      f32,

    // contrast or gain of the strobe wheel, higher contrast will amplify the signal to make the stripes more prominent
    strobe_contrast:       f32,

    // attenuate strobe effect when it spins faster than desired
    apply_attenuation:     bool,

    // auto detection vs manual selection of note to track
    note_detection_mode:   NoteDetectionMode,

    // How to render the strobe effect
    strobe_display_type:   StrobeDisplayType,

    // Color scheme for strobe track display, two hex values
    strobe_color_1:        u32,
    strobe_color_2:        u32,
    strobe_bg_color:       u32,
    window_bg_color:       u32,
}

defaults := Config {
    pitch_standard        = 440.0,
    strobe_count          = 3,
    pitch_detect_fft_size = 4096,
    samplerate            = 48_000,
    strobe_window_size    = 4800,
    strobe_mode           = .VERNIER_MODE, // .HARMONIC_MODE
    note_detection_mode   = .AUTO,
    strobe_speed          = 0.01,
    speed_multiplier      = 2.0,
    strobe_contrast       = 1.0,
    apply_attenuation     = false,
    strobe_display_type   = .CURVED_TRACKS,
    // strobe_color             = {0xB5F2DBFF, 0x6B3D7DFF},
    strobe_color_1        = 0xE26546FF,
    strobe_color_2        = 0x54202BFF,
    strobe_bg_color       = 0x7F889CFF,
    window_bg_color       = 0x0D0C10FF,
}


load_config :: proc() -> Config {
    // start with the default config
    config := defaults

    ini_map, ok := load_ini("strobe-tuner")
    defer if ok do ini.delete_map(ini_map)

    section := ini_map[""]

    count := reflect.struct_field_count(Config)
    offsets := reflect.struct_field_offsets(Config)

    for i in 0 ..< count {
        field := reflect.struct_field_at(Config, i)
        raw_ptr := rawptr(uintptr(&config) + offsets[i])

        #partial switch v in field.type.variant {
        case reflect.Type_Info_Float:
            val, ok := strconv.parse_f32(section[field.name])
            if ok {
                ptr := cast(^f32)raw_ptr
                ptr^ = val
            }
        case reflect.Type_Info_Integer:
            val, ok := strconv.parse_int(section[field.name])
            if ok {
                switch field.type.id {
                case int:
                    ptr := cast(^int)raw_ptr
                    ptr^ = int(val)
                case u32:
                    ptr := cast(^u32)raw_ptr
                    ptr^ = u32(val)
                }
            }
        case reflect.Type_Info_Boolean:
            val, ok := strconv.parse_bool(section[field.name])
            if ok {
                ptr := cast(^bool)raw_ptr
                ptr^ = val
            }
        case reflect.Type_Info_Named:
            val, ok := reflect.enum_from_name_any(field.type.id, section[field.name])
            if ok {
                ptr := cast(^int)raw_ptr
                ptr^ = int(val)
            }
        case:
            fmt.println("Unsupported config type.")
        // ignore
        }
    }

    // config.pitch_standard = strconv.parse_f32(section["pitch_standard"]) or_else defaults.pitch_standard
    // config.strobe_count = strconv.parse_int(section["strobe_count"]) or_else defaults.strobe_count
    // config.pitch_detect_fft_size = strconv.parse_int(section["pitch_detect_fft_size"]) or_else defaults.pitch_detect_fft_size
    // config.samplerate = strconv.parse_int(section["samplerate"]) or_else defaults.samplerate
    // config.strobe_window_size = strconv.parse_int(section["strobe_window_size"]) or_else defaults.strobe_window_size
    // config.strobe_mode = reflect.enum_from_name(core.StrobeMode, section["strobe_mode"]) or_else defaults.strobe_mode
    // config.note_detection_mode = reflect.enum_from_name(NoteDetectionMode, section["note_detection_mode"]) or_else defaults.note_detection_mode
    // config.strobe_speed = strconv.parse_f32(section["strobe_speed"]) or_else defaults.strobe_speed
    // config.speed_multiplier = strconv.parse_f32(section["speed_multiplier"]) or_else defaults.speed_multiplier
    // config.strobe_contrast = strconv.parse_f32(section["strobe_contrast"]) or_else defaults.strobe_contrast
    // config.apply_attenuation = strconv.parse_bool(section["apply_attenuation"]) or_else defaults.apply_attenuation
    // config.strobe_display_type = reflect.enum_from_name(StrobeDisplayType, section["strobe_display_type"]) or_else defaults.strobe_display_type

    // config.window_bg_color = cast(u32) (strconv.parse_uint(section["window_bg_color"]) or_else uint(defaults.window_bg_color))
    // config.strobe_bg_color = cast(u32) (strconv.parse_uint(section["strobe_bg_color"]) or_else uint(defaults.strobe_bg_color))
    // config.strobe_color_1 = cast(u32) (strconv.parse_uint(section["strobe_color_1"]) or_else uint(defaults.strobe_color_1))
    // config.strobe_color_2 = cast(u32) (strconv.parse_uint(section["strobe_color_2"]) or_else uint(defaults.strobe_color_2))

    return config
}


deserialize_config :: proc () {

}


// save_config :: proc(config_path: string, config: ^Config) ->

// save_config :: proc(config: ^Config) -> ConfigError {
//     config_file_path := filepath.join({config_path, CONFIG_NAME})

//     // Convert map to JSON
//     json_data, marshal_err := json.marshal(config.data)
//     if marshal_err != .None {
//         fmt.eprintln("Config marshal error:", marshal_err)
//         return .WriteError
//     }
//     defer delete(json_data)

//     // Write to file
//     write_ok := os.write_entire_file(config_file_path, json_data)
//     if !write_ok {
//         return .WriteError
//     }

//     return .None
// }
