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

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"

CONFIG_NAME :: "config.ini"

create_app_directory :: proc() -> Maybe(string) {
    dir_path := config_directory(APP_NAME)

    if os.exists(dir_path) do return dir_path

    err := os.make_directory(dir_path)
    if err != nil do return nil

    return dir_path
}

config_path :: proc() -> string {
    dir_path := config_directory(APP_NAME)
    defer delete(dir_path)
    path, _ := filepath.join({dir_path, CONFIG_NAME})
    return path
}

load_ini :: proc() -> (ini.Map, bool) {
    // Load or create config directory in a standard location based on the OS
    dir_path, dir_ok := create_app_directory().?
    defer delete(dir_path)

    if !dir_ok do return nil, false

    // Load or create an ini file
    ini_path, _ := filepath.join({dir_path, CONFIG_NAME})
    defer delete(ini_path)

    if os.exists(ini_path) {
        fmt.println("Loading config from", ini_path)
    } else {
        fmt.println("No config file at", ini_path)
        return nil, false
    }

    ini_map, err, ok := ini.load_map_from_path(ini_path, allocator = context.allocator)

    if !ok {
        fmt.println("Failed to load config file", ini_path, err)
        return nil, false
    }

    return ini_map, true
}

save_ini :: proc(ini_map: ini.Map) {
    dir_path, dir_ok := create_app_directory().?
    defer delete(dir_path)

    // Without it the path would be relative, the file would land wherever the app was started from
    if !dir_ok {
        fmt.println("Failed to create the config directory")
        return
    }

    ini_path, _ := filepath.join({dir_path, CONFIG_NAME})
    defer delete(ini_path)

    // Truncate so a shorter config doesn't leave stale bytes at the end of the file
    file, err := os.open(ini_path, {.Write, .Create, .Trunc})
    if err != nil {
        fmt.println("Failed to load the config file.", ini_path)
        return
    }
    defer os.close(file)

    fmt.println("Saving config to", ini_path)

    // The stream wraps the file handle, which is closed above
    stream := os.to_stream(file)

    section := ini_map[""]

    keys, keys_err := slice.map_keys(section)
    if keys_err != nil {
        fmt.println("Failed to save config file", ini_path)
        return
    }
    defer delete(keys)

    // Keep order the same in the ini file
    slice.sort(keys)

    for key in keys {
        ini.write_pair(stream, key, section[key])
    }
}

config_directory :: proc(app_name: string) -> string {
    when ODIN_OS == .Darwin {
        // macOS: ~/Library/Application Support
        home := os.get_env("HOME", context.allocator)
        defer delete(home)
        path, _ := filepath.join({home, "Library", "Application Support", app_name})
        return path
    } else {
        // Linux/Unix: ~/.config or XDG_CONFIG_HOME
        config_home := os.get_env("XDG_CONFIG_HOME", context.allocator)
        defer delete(config_home)
        if config_home == "" {
            home := os.get_env("HOME", context.allocator)
            defer delete(home)
            config_home, _ = filepath.join({home, ".config"})
        }
        path, _ := filepath.join({config_home, app_name})
        return path
    }
}
