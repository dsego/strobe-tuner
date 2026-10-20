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


// The config in a file where the OS keeps an app's settings, see config_directory. In a browser see web.odin.
#+build !js
package app

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Only used on Android, required so a -vet build elsewhere doesn't count them as unused
@(require) import sdl "vendor:sdl3"
@(require) import "../gfx"

CONFIG_NAME :: "config.ini"

create_app_directory :: proc() -> Maybe(string) {
    dir_path := config_directory(APP_NAME)

    if os.exists(dir_path) do return dir_path

    // With the folders above it, an iOS app's container has no Application Support until it's made
    err := os.make_directory_all(dir_path)
    if err != nil {
        delete(dir_path)
        return nil
    }

    return dir_path
}

config_path :: proc() -> string {
    dir_path := config_directory(APP_NAME)
    defer delete(dir_path)

    path, _ := filepath.join({dir_path, CONFIG_NAME})
    return path
}

load_ini :: proc() -> (ini.Map, bool) {
    // In a standard location based on the OS, see config_directory
    ini_path := config_path()
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
    // On the disk when it returns, not in a buffer
    write_ini :: proc(path: string, ini_map: ini.Map) -> bool {
        // Truncate so a shorter config doesn't leave stale bytes at the end of the file
        file, err := os.open(path, {.Write, .Create, .Trunc})
        if err != nil do return false

        defer os.close(file)

        // The stream wraps the file handle, which is closed above
        if !write_ini_pairs(os.to_stream(file), ini_map) do return false

        return os.sync(file) == nil
    }

    dir_path, dir_ok := create_app_directory().?
    defer delete(dir_path)

    // Without it the path would be relative, the file would land wherever the app was started from
    if !dir_ok {
        fmt.println("Failed to create the config directory")
        return
    }

    ini_path := config_path()
    defer delete(ini_path)

    // Written next to it and renamed over it, a rename is all or nothing: the app ended halfway, by iOS or
    // a crash, leaves the last config, not half of one
    temp_path := strings.concatenate({ini_path, ".tmp"})
    defer delete(temp_path)

    fmt.println("Saving config to", ini_path)

    if !write_ini(temp_path, ini_map) {
        fmt.println("Failed to save the config file", temp_path)
        return
    }
    if err := os.rename(temp_path, ini_path); err != nil {
        fmt.println("Failed to replace the config file", ini_path, err)
    }
}

config_directory :: proc(app_name: string) -> string {
    when ODIN_OS == .Darwin {
        // macOS: ~/Library/Application Support
        home := os.get_env("HOME", context.allocator)
        defer delete(home)

        path, _ := filepath.join({home, "Library", "Application Support", app_name})
        return path
    } else when gfx.ANDROID {
        // No HOME, the app's own folder in the internal storage, the system removes it with the app
        return strings.clone(string(sdl.GetAndroidInternalStoragePath()))
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
