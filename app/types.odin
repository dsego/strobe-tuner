package app

import "../core"

NoteDetectionMode :: enum {
    AUTO,
    MANUAL,
}

StrobeDisplayType :: enum {
    SPINNING_WHEEL,
    CURVED_TRACKS,
}

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
    strobe_color_1:        u32 "color",
    strobe_color_2:        u32 "color",

    // Background colors
    strobe_bg_color:       u32 "color",
    window_bg_color:       u32 "color",
}
