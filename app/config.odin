package app


import "core:encoding/ini"
import "core:fmt"
import "core:reflect"

import "../core"


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
    target_freq_hz:        f32,

    // eg A 440Hz
    pitch_standard:        f32,

    // how many spinning bands to show
    strobe_count:          int,

    // FFT length for the pitch detector, e.g. 4092 samples
    pitch_detect_fft_size: int,

    // audio card sampling rate, e.g. 44.100 Hz
    samplerate:            int,

    // harmonic to track multiple frequencies or "vernier" to track one pitch at different sensitivities
    strobe_mode:           core.StrobeMode,

    // the sensitivity or speed of the base strobe band,
    // i.e. how fast should the spinning effect be in response to the phase difference
    strobe_speed:          f32,

    // if multiple strobe bands, this sensitivity multiplier will be applied to subsequent spinning bands
    speed_multiplier:      f32,

    // contrast or gain of the strobe wheel, higher contrast will amplify the signal to make the stripes more prominent
    strobe_contrast:       f32,

    // auto detection vs manual selection of note to track
    note_detection_mode:   NoteDetectionMode,

    // How to render the strobe effect
    strobe_display_type:   StrobeDisplayType,

    // Color scheme for strobe track display, two hex values
    strobe_color_1:        u32 "color",
    strobe_color_2:        u32 "color",

    // Background colors
    strobe_bg_color:       u32 "color",
    window_bg_color:       u32 "color",

    // attenuate strobe effect when it spins so fast it becomes distracting
    apply_attenuation:     bool,

    tuning_preset:         TuningPreset,
}


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

    config.tuning_preset = get_config(
        ini_map,
        "tuning_preset",
        TuningPreset,
        TuningPreset.CHROMATIC,
    )
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
