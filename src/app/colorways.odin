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

StrobeColorway :: enum {
    VIBRANT_RED,
    MINTY,
    AMBER,
    MONO,
    BY_NOTE, // see note_colors
}

// The lit stripes and the dark ones
COLORWAYS :: [StrobeColorway][2]u32 {
    .VIBRANT_RED = {0xFF6767FF, 0x6B4949FF},
    .MINTY       = {0xB5F2DBFF, 0x6B3D7DFF},
    .AMBER       = {0xFF9A4DFF, 0x6B4A38FF},
    // Black and white, the most contrast and no hue to tell apart
    .MONO        = {0xF2F1ECFF, 0x55565EFF},
    // Until the first frame follows the note, A's, see by_note_colors
    .BY_NOTE     = {0x8B8CE7FF, 0x463050FF},
}

// By note: every note its own color, from the painter's twelve-color wheel, C on its red and each semitone a
// color on round to B, the wheel's teal swapped for a cerulean G. The color flips with the shown note instead
// of blending between notes, a new color is a new note at a glance. The note's name stays on the screen, the
// color is a second cue. The lit colors are evened out toward one lightness so the blues and violets aren't
// dim. The dark stripes are the note's hue darkened, leaning a little toward plum, colorful enough to stay the
// note's color against the background the glow lights in their hue.
NOTE_COLORS :: [12][2]u32 {
    {0xFF6F66FF, 0x552D31FF}, // C
    {0xFF8C5DFF, 0x562D2CFF}, // C#
    {0xFF994AFF, 0x562E27FF}, // D
    {0xF8B000FF, 0x54301FFF}, // D#
    {0xDFD100FF, 0x503316FF}, // E
    {0x94CE4AFF, 0x473813FF}, // F
    {0x40CD6DFF, 0x3A3C32FF}, // F#
    {0x4AB7FBFF, 0x363659FF}, // G
    {0x6198FFFF, 0x403355FF}, // G#
    {0x8B8CE7FF, 0x463050FF}, // A
    {0xB57DDDFF, 0x4D2E49FF}, // A#
    {0xE76FC8FF, 0x512D40FF}, // B
}

// The shown note's, set every frame, see follow_note_colors
by_note_colors := COLORWAYS[.BY_NOTE]

// The lit and the dark color of a note, in whole semitones of cents from A4
note_colors :: proc(cents: int) -> [2]u32 {
    colors := NOTE_COLORS
    return colors[(cents / 100 + 9) %% 12]
}

// The note as it's shown, a transposing instrument's written note or a capo's open string
follow_note_colors :: proc(app: ^App) {
    by_note_colors = note_colors(app.measurement.note_target.target_note.cents + 100 * shown_transpose(app.config))
}


// Lamp glow on the strobe, the lamp-lit look of the old mechanical strobe tuners, toggled with G.
// The lamp shines through a filter in the colorway's hue.
GlowParams :: struct {
    color:      u32, // filter hue the lamp shines through
    dark_color: u32, // filter hue of the dark stripes, the same as color for a single hue
    dark_level: f32, // 1 is the usual share of light through the dark stripes, lower darkens them
    exposure:   f32, // higher shifts the lit stripes towards yellow/white
    saturation: f32, // 1 keeps the full color, lower mixes in gray
}

GLOWS :: [StrobeColorway]GlowParams {
    // The lamp only adds light, the filters are picked to land on the flat colors: the coral of the lit
    // stripes and the grayish mauve of the dark ones, cooler than the coral to set the two hues apart. No gray
    // mixed in, it turns the coral pink. A filter that pale passes a lot of light, the dark stripes are dimmed
    // to keep the contrast.
    .VIBRANT_RED = {color = 0xFF6D65FF, dark_color = 0xFFCBD3FF, dark_level = 0.6, exposure = 3.5, saturation = 1.0},
    // A paler purple than the flat one, the filter saturates it. Lands on the flat purple with light on it.
    .MINTY       = {color = 0x7DF2C4FF, dark_color = 0xE0A0FFFF, dark_level = 0.9, exposure = 3.0, saturation = 1.0},
    .AMBER       = {color = 0xFF803CFF, dark_color = 0xFF803CFF, dark_level = 1.0, exposure = 4.5, saturation = 0.8},
    // The warm white of a bulb, only a little off neutral, a yellow that's dimmed turns olive. A white filter
    // passes all of the light, the dark stripes are dimmed the most here.
    .MONO        = {color = 0xFFEEE0FF, dark_color = 0xFFF2EAFF, dark_level = 0.4, exposure = 3.5, saturation = 0.8},
    // Filters that land on the note's own colors, see landing_filter. The note's hue lights the background.
    .BY_NOTE     = {dark_level = 1.0, exposure = 3.5, saturation = 1.0},
}

// By note's background lit in the dark stripes' hue like the other colorways, or in the lit stripes'
BY_NOTE_GLOW_FROM_DARK :: #config(BY_NOTE_GLOW_FROM_DARK, true)

glow_params :: proc(config: ^Config) -> GlowParams {
    glows := GLOWS
    glow := glows[config.strobe_colorway]
    if config.strobe_colorway == .BY_NOTE {
        glow.color, glow.dark_color = by_note_colors.x, by_note_colors.x
        if BY_NOTE_GLOW_FROM_DARK do glow.dark_color = by_note_colors.y
    }
    return glow
}

strobe_colors :: proc(config: ^Config) -> [2]u32 {
    if config.strobe_colorway == .BY_NOTE do return by_note_colors

    colorways := COLORWAYS
    return colorways[config.strobe_colorway]
}
