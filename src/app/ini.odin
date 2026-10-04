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

import "base:runtime"
import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../gfx"

CONFIG_NAME :: "config.ini"

create_app_directory :: proc() -> Maybe(string) {
    dir_path := config_directory(APP_NAME)

    if os.exists(dir_path) do return dir_path

    // With the folders above it, an iOS app's container has no Application Support until it's made
    err := os.make_directory_all(dir_path)
    if err != nil do return nil

    return dir_path
}

config_path :: proc() -> string {
    dir_path := config_directory(APP_NAME)
    defer delete(dir_path)
    path, _ := filepath.join({dir_path, CONFIG_NAME})
    return path
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
    // The pairs sorted by key, the order stays the same. On the disk when it returns, not in a buffer.
    write_ini :: proc(path: string, ini_map: ini.Map) -> bool {
        // Truncate so a shorter config doesn't leave stale bytes at the end of the file
        file, err := os.open(path, {.Write, .Create, .Trunc})
        if err != nil do return false
        defer os.close(file)

        // The stream wraps the file handle, which is closed above
        stream := os.to_stream(file)

        section := ini_map[""]

        keys, keys_err := slice.map_keys(section)
        if keys_err != nil do return false
        defer delete(keys)

        // Keep order the same in the ini file
        slice.sort(keys)

        for key in keys {
            if _, write_err := ini.write_pair(stream, key, section[key]); write_err != .None do return false
        }
        return os.sync(file) == nil
    }

    dir_path, dir_ok := create_app_directory().?
    defer delete(dir_path)

    // Without it the path would be relative, the file would land wherever the app was started from
    if !dir_ok {
        fmt.println("Failed to create the config directory")
        return
    }

    ini_path, _ := filepath.join({dir_path, CONFIG_NAME})
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
