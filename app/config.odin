package app


import "core:encoding/ini"
import "core:fmt"
import "core:reflect"

import "../core"


load_config :: proc() -> Config {
    // Load config from the standard OS path, eg ~/Library/Application Support/strobe-tuner/config.ini on MacOS.
    // Initiate fields to default values if a setting is not found in the configuration file.

    config := Config{}

    ini_map, ok := load_ini()
    defer if ok do ini.delete_map(ini_map)

    config.apply_attenuation = get_config(ini_map, "apply_attenuation", bool, false)
    config.target_freq_hz = get_config(ini_map, "target_freq_hz", f32, 110.0)
    config.pitch_standard = get_config(ini_map, "pitch_standard", f32, 440.0)
    config.strobe_count = get_config(ini_map, "strobe_count", int, 3)
    config.pitch_detect_fft_size = get_config(ini_map, "pitch_detect_fft_size", int, 4096)
    config.samplerate = get_config(ini_map, "samplerate", int, 48_000)
    config.strobe_mode = get_config(
        ini_map,
        "strobe_mode",
        core.StrobeMode,
        core.StrobeMode.VERNIER_MODE,
    )
    config.note_detection_mode = get_config(
        ini_map,
        "note_detection_mode",
        NoteDetectionMode,
        NoteDetectionMode.AUTO,
    )
    config.strobe_speed = get_config(ini_map, "strobe_speed", f32, 0.01)
    config.speed_multiplier = get_config(ini_map, "speed_multiplier", f32, 2.0)
    config.strobe_contrast = get_config(ini_map, "strobe_contrast", f32, 1000.0)
    config.strobe_display_type = get_config(
        ini_map,
        "strobe_display_type",
        StrobeDisplayType,
        StrobeDisplayType.CURVED_TRACKS,
    )
    config.window_bg_color = cast(u32)get_config(ini_map, "window_bg_color", int, 0x0D0C10FF)
    config.strobe_bg_color = cast(u32)get_config(ini_map, "strobe_bg_color", int, 0x0D0C10FF)
    config.strobe_color_1 = cast(u32)get_config(ini_map, "strobe_color_1", int, 0xE26546FF)
    config.strobe_color_2 = cast(u32)get_config(ini_map, "strobe_color_2", int, 0x54202BFF)

    return config
}


save_config :: proc(config: Config) {
    ini_map := ini.Map{}
    defer ini.delete_map(ini_map)
    defer delete(ini_map)

    section: map[string]string = {}
    defer delete(section)

    fields := reflect.struct_fields_zipped(Config)

    for field in fields {
        value := reflect.struct_field_value(config, field)
        if field.tag == "color" {
            stringified := fmt.aprintf("%#X", value)
            section[field.name] = stringified
        } else {
            stringified := fmt.aprintf("%v", value)
            section[field.name] = stringified
        }
    }

    ini_map[""] = section
    save_ini(ini_map)
}
