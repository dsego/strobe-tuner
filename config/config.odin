package config

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"


Error :: os.Error

load_config :: proc(app_name: string, $T: typeid, config: ^T) -> Error {
    config_path := get_config_directory(app_name)
    err := os.make_directory(config_path)

    if err != os.ERROR_NONE do return err

    count := reflect.struct_field_count(T)
    for i in 0 ..< count {
        field := reflect.struct_field_at(T, i)
    }
}


// save_config :: proc(config_path: string, config: ^Config) ->


// get_config_path :: proc () -> string {
//     dir_path := get_config_directory(APP_NAME)
//     config_file_path := filepath.join({dir_path, "config"})
//     return config_file_path
// }

get_config_directory :: proc(app_name: string) -> string {
    when ODIN_OS == .Windows {
        // Use %APPDATA% on Windows
        base_path := os.get_env("APPDATA")
        return filepath.join({base_path, app_name})
    } else when ODIN_OS == .Darwin {
        // macOS: ~/Library/Application Support
        home := os.get_env("HOME")
        return filepath.join({home, "Library", "Application Support", app_name})
    } else {
        // Linux/Unix: ~/.config or XDG_CONFIG_HOME
        config_home := os.get_env("XDG_CONFIG_HOME")
        if config_home == "" {
            home := os.get_env("HOME")
            config_home = filepath.join({home, ".config"})
        }
        return filepath.join({config_home, app_name})
    }
}


// load_config :: proc(config_path: string, config: ^Config) -> bool,  {
//     config_file_path := filepath.join({config_path, CONFIG_NAME})

//     if os.exists(config_file_path) {
//         fmt.println("Loading config from: %s", config_file_path)
//     } else {
//         fmt.println("No config file stored at %s", config_file_path)
//         return true
//     }

//     ini_map, err, ok := ini.load_map_from_path(config_file_path, allocator=context.allocator)
//     if !ok {
//         fmt.println("Failed to load config file.")
//         return false
//     }
//     defer ini.delete_map(ini_map)


//     // n, ok := strconv.parse_int("1234")
//     // reflect.enum_from_name()

//     // config.pitch_standard = ini_map["pitch_standard"]
//     // config.strobe_count = ini_map["strobe_count"]
//     // config.pitch_detect_fft_size = ini_map["pitch_detect_fft_size"]
//     // config.samplerate = ini_map["samplerate"]
//     // config.strobe_window_size = ini_map["strobe_window_size"]
//     // config.strobe_mode = ini_map["strobe_mode"]
//     // config.base_sensitivity = ini_map["base_sensitivity"]
//     // config.sensitivity_multiplier = ini_map["sensitivity_multiplier"]
//     // config.note_detection_mode = ini_map["note_detection_mode"]
//     // config.strobe_display_type = ini_map["strobe_display_type"]

//     // strconv.parse_bool
//     // strconv.parse_f32


//     return true
// }

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
