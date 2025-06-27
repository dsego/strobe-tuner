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
import "core:encoding/ini"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strconv"

CONFIG_NAME :: "config.ini"
APP_NAME :: "strobe-tuner"

create_app_directory :: proc() -> Maybe(string) {
    dir_path := get_config_directory(APP_NAME)
    err := os.make_directory(dir_path)
    if err != os.ERROR_NONE && err != os.EEXIST {
        return nil
    }
    return dir_path
}

load_ini :: proc() -> (ini.Map, bool) {
    // Load or create config directory in a standard location based on the OS
    dir_path, dir_ok := create_app_directory().?

    if !dir_ok do return nil, false

    // Load or create an ini file
    ini_path := filepath.join({dir_path, CONFIG_NAME})
    defer delete(ini_path)

    if os.exists(ini_path) {
        fmt.println("Loading config from", ini_path)
    } else {
        fmt.println("No config file at", ini_path)
        return nil, false
    }

    ini_map, err, ok := ini.load_map_from_path(ini_path, allocator = context.allocator)

    if !ok {
        fmt.println("Failed to load config file", ini_path)
        return nil, false
    }

    return ini_map, true
}

save_ini :: proc(ini_map: ini.Map) {
    dir_path, dir_ok := create_app_directory().?
    ini_path := filepath.join({dir_path, CONFIG_NAME})
    defer delete(ini_path)

    file, err := os.open(ini_path, os.O_WRONLY | os.O_CREATE, 0o644)
    if err != nil {
        fmt.println("Failed to load the config file.", ini_path)
        return
    }
    defer os.close(file)

    fmt.println("Saving config to", ini_path)

    stream := os.stream_from_handle(file)
    defer io.close(stream)

    section := ini_map[""]

    keys, keys_err := slice.map_keys(section)
    if keys_err != nil {
        fmt.println("Failed to save config file", ini_path)
        return
    }

    // Keep order the same in the ini file
    slice.sort(keys)

    for k in keys {
        ini.write_pair(stream, k, section[k])
    }
}

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

get_config :: proc(ini_map: ini.Map, name: string, $T: typeid, default: T) -> T {
    section := ini_map[""]
    when intrinsics.type_is_enum(T) {
        value, ok := reflect.enum_from_name_any(T, section[name])
        if ok do return cast(T)value
        return default
    } else when T == f32 {
        return strconv.parse_f32(section[name]) or_else default
    } else when T == int {
        return strconv.parse_int(section[name]) or_else default
    } else when T == bool {
        return strconv.parse_bool(section[name]) or_else default
    }
    return default
}
