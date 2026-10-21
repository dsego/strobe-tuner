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
import "core:io"
import "core:math"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../core"

// From the standard OS path, e.g. ~/Library/Application Support/<APP_NAME>/config.ini on macOS, see
// config_directory in ini_file.odin, the page's storage in a browser, see web.odin. Each field as save_config writes it, see read_value. A few values are then held in
// range, see the end.
load_config :: proc() -> Config {
    config := config_defaults

    ini_map, loaded := load_ini()
    defer if loaded do ini.delete_map(ini_map)

    section := ini_map[""]

    fields := reflect.struct_fields_zipped(Config)

    for field in fields {
        read_value(rawptr(uintptr(&config) + field.offset), field.type, section[field.name])
    }

    // Hand edited out of range, the tuner would have no note to start on
    config.pitch_standard = clamp(config.pitch_standard, PITCH_STANDARD_MIN, PITCH_STANDARD_MAX)
    lowest := core.freq_at_cents(config.pitch_standard, core.LOWEST_NOTE * 100)
    highest := core.freq_at_cents(config.pitch_standard, core.HIGHEST_NOTE * 100)
    config.target_freq_hz = clamp(config.target_freq_hz, lowest, highest)

    // A readout time of 0 would fit the newest chunk alone and a negative one blow the fit up
    fit_steps := READOUT_FIT_STEPS_S
    config.readout_fit_s = clamp(config.readout_fit_s, fit_steps[0], fit_steps[len(fit_steps) - 1])

    // An offset past the settings' own moves the strobe's target to another note, it stands still there
    for &preset in config.note_offset_cents {
        for &cents in preset do cents = clamp(cents, -NOTE_OFFSET_MAX_CENTS, NOTE_OFFSET_MAX_CENTS)
    }
    for &cents in config.strobe_offsets_cents do cents = clamp(cents, -TRACK_OFFSET_MAX_CENTS, TRACK_OFFSET_MAX_CENTS)

    // 0 is off, a sliver of a period would fade the screen to nothing between two samples. The W key's longest
    // is about 70 periods.
    if config.strobe_persistence_periods != 0 do config.strobe_persistence_periods = clamp(config.strobe_persistence_periods, 1, 1000)
    if config.screen_persistence_periods != 0 do config.screen_persistence_periods = clamp(config.screen_persistence_periods, 1, 1000)

    // A spectrum window of 0 would have nothing to transform
    window_steps := SPECTRUM_WINDOW_STEPS
    config.spectrum_windows = clamp(config.spectrum_windows, window_steps[0], window_steps[len(window_steps) - 1])

    // The strobe needs a track, and the I key steps on from a preset that exists
    defaults := config_defaults
    has_track := false
    for interval in config.strobe_intervals do has_track ||= interval >= 1
    if !has_track do config.strobe_intervals = defaults.strobe_intervals

    config.strobe_intervals_index = clamp(config.strobe_intervals_index, 0, len(INTERVAL_OPTIONS) - 1)

    // Hand edited smaller than the window goes, it opens at the strobe's size
    min_size := WINDOW_MIN_SIZE
    if config.window_size.x < int(min_size.x) || config.window_size.y < int(min_size.y) do config.window_size = {}

    return config
}

// A value as %v writes it into the field or element at ptr: an enum by its name, a float, an integer, a bool,
// a string, a fixed array [a, b, c] of any of these, an array of arrays nested the same way, e.g. the note
// offsets per preset, and an enumerated array [.NAME = value, ...] by its names, e.g. a tuning per
// instrument. Arrays nested and enums named, a new instrument or longer rows don't shift what's saved onto
// another. Missing or doesn't parse keeps its default, a number that isn't finite too, and an array's
// missing trailing elements are zero, an enumerated array's missing names keep theirs. An enum of a number
// is a config from before they were named. A Maybe of an integer is the integer or nil. Others keep their
// default: slices, dynamic arrays, structs, other unions.
read_value :: proc(ptr: rawptr, type: ^runtime.Type_Info, written: string) {
    text := strings.trim_space(written)
    if len(text) == 0 do return

    #partial switch info in reflect.type_info_base(type).variant {
    case reflect.Type_Info_Union:
        if len(info.variants) != 1 || !reflect.is_integer(info.variants[0]) do return

        if text == "nil" {
            runtime.mem_zero(ptr, type.size)
        } else if value, ok := strconv.parse_int(text); ok {
            write_int_field(ptr, info.variants[0].size, value)
            reflect.set_union_variant_type_info(any{ptr, type.id}, info.variants[0])
        }
    case reflect.Type_Info_Enum:
        if value, ok := reflect.enum_from_name_any(type.id, strings.trim(text, "\".")); ok {
            write_int_field(ptr, type.size, int(value))
        } else if number, is_number := strconv.parse_int(text); is_number {
            if slice.contains(info.values, reflect.Type_Info_Enum_Value(number)) do write_int_field(ptr, type.size, number)
        }
    case reflect.Type_Info_Float:
        if value, ok := parse_finite_f32(text); ok {
            if type.size == 8 do (^f64)(ptr)^ = f64(value)
            else do (^f32)(ptr)^ = value
        }
    case reflect.Type_Info_Integer:
        if value, ok := strconv.parse_int(text); ok do write_int_field(ptr, type.size, value)
    case reflect.Type_Info_Boolean:
        if value, ok := strconv.parse_bool(text); ok do (^bool)(ptr)^ = value
    case reflect.Type_Info_String:
        // A copy of its own, the map goes at the end
        (^string)(ptr)^ = strings.clone(text)
    case reflect.Type_Info_Array:
        items := split_list(text)
        defer delete(items)

        if len(items) == 0 do return

        for index in 0 ..< info.count {
            element := rawptr(uintptr(ptr) + uintptr(index * info.elem_size))
            if index < len(items) do read_value(element, info.elem, items[index])
            else do runtime.mem_zero(element, info.elem_size)
        }
    case reflect.Type_Info_Enumerated_Array:
        items := split_list(text)
        defer delete(items)

        for item, position in items {
            index := position
            value := item

            // By its name, a config from before them only has the values in order
            name, equals, rest := strings.partition(item, "=")
            if len(equals) > 0 {
                key, named := reflect.enum_from_name_any(info.index.id, strings.trim(name, " ."))
                if !named do continue

                index, value = int(key - info.min_value), rest
            }
            if index >= 0 && index < info.count {
                read_value(rawptr(uintptr(ptr) + uintptr(index * info.elem_size)), info.elem, value)
            }
        }
    }
}

// The items of a list as %v writes it, the outer brackets off, split at the commas outside any nested ones
split_list :: proc(text: string) -> [dynamic]string {
    items: [dynamic]string
    inner := strings.trim_space(text)
    if strings.has_prefix(inner, "[") && strings.has_suffix(inner, "]") do inner = inner[1:len(inner) - 1]
    if len(strings.trim_space(inner)) == 0 do return items

    depth, start := 0, 0
    for char, index in inner {
        switch char {
        case '[':
            depth += 1
        case ']':
            depth -= 1
        case ',':
            if depth == 0 {
                append(&items, inner[start:index])
                start = index + 1
            }
        }
    }
    append(&items, inner[start:])
    return items
}

// A hand edited "nan" or "inf" would spread through the measurements, it keeps the default like a typo
parse_finite_f32 :: proc(text: string) -> (value: f32, ok: bool) {
    value, ok = strconv.parse_f32(text)
    return value, ok && !math.is_nan(value) && !math.is_inf(value)
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

// The pairs sorted by key, the order stays the same from one save to the next
write_ini_pairs :: proc(stream: io.Stream, ini_map: ini.Map) -> bool {
    section := ini_map[""]

    keys, keys_err := slice.map_keys(section)
    if keys_err != nil do return false

    defer delete(keys)

    // Keep order the same in the ini file
    slice.sort(keys)

    for key in keys {
        if _, write_err := ini.write_pair(stream, key, section[key]); write_err != .None do return false
    }
    return true
}
