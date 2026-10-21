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

import "core:math"

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
    // Until the first frame follows the note, see by_note_colors
    .BY_NOTE     = {0xFF6767FF, 0x6B4949FF},
}

// By note: every note its own hue. The seven naturals are spread evenly round the hue wheel in pitch order,
// C at NOTE_HUE_C, a sharp halfway between its neighbours and B on round to C, so a pitch between two notes
// gets the hue between theirs. All at one lightness in OKLCH, the lightness the eye sees, so only the hue
// tells the notes apart and every note's stripes are as bright. The note's name stays on the screen, the
// color is a second cue. C has the coral's hue, the wheel runs on like the colors of music teaching, C red,
// D orange, E yellow and green, blue and violet up to B.
NOTE_HUE_C :: #config(NOTE_HUE_C, 23) // degrees
NOTE_LIGHTNESS :: #config(NOTE_LIGHTNESS, 0.76)
NOTE_CHROMA :: #config(NOTE_CHROMA, 0.135)
// The dark stripes, the same hue dimmed like the colorways' dark ones
NOTE_DARK_LIGHTNESS :: 0.4
NOTE_DARK_CHROMA :: 0.05

// Where each semitone from C sits among the naturals, C is 0 and the next C 7
NATURAL_PLACES :: [13]f32{0, 0.5, 1, 1.5, 2, 3, 3.5, 4, 4.5, 5, 5.5, 6, 7}

// The shown note's, set every frame, see follow_note_colors
by_note_colors := COLORWAYS[.BY_NOTE]

// The lit and the dark color at a pitch, in cents from A4
note_colors :: proc(cents: f32) -> [2]u32 {
    from_c := cents / 100 + 9
    semitone := math.floor(from_c)
    index := int(semitone) %% 12
    places := NATURAL_PLACES
    hue := NOTE_HUE_C + math.lerp(places[index], places[index + 1], from_c - semitone) * 360 / 7
    return {oklch_color(NOTE_LIGHTNESS, NOTE_CHROMA, hue), oklch_color(NOTE_DARK_LIGHTNESS, NOTE_DARK_CHROMA, hue)}
}

// The note as it's shown, a transposing instrument's written note or a capo's open string, with the
// readout's cents, the note alone while there's no readout
follow_note_colors :: proc(app: ^App, reading: Reading) {
    note_target := &app.measurement.note_target
    cents := f32(note_target.target_note.cents + 100 * shown_transpose(app.config))
    if note_target.active && reading.steady.measured do cents += reading.steady.err_cents

    by_note_colors = note_colors(cents)
}

// An OKLCH color (Björn Ottosson's OKLab as lightness, chroma and hue in degrees) as RGBA. A chroma the screen
// can't show at that lightness and hue is pulled in until it can.
oklch_color :: proc(lightness, chroma, hue: f32) -> u32 {
    linear_rgb :: proc(lightness, chroma, hue: f32) -> [3]f32 {
        a := chroma * math.cos(math.to_radians(hue))
        b := chroma * math.sin(math.to_radians(hue))
        l := math.pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        m := math.pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        s := math.pow(lightness - 0.0894841775 * a - 1.291485548 * b, 3)
        return {
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
        }
    }

    on_screen :: proc(rgb: [3]f32) -> bool {
        return min(rgb.r, rgb.g, rgb.b) >= -1e-4 && max(rgb.r, rgb.g, rgb.b) <= 1 + 1e-4
    }

    // Halving the range of chromas that fit and the ones that don't
    fitted := chroma
    if !on_screen(linear_rgb(lightness, chroma, hue)) {
        low, high: f32 = 0, chroma
        for _ in 0 ..< 16 {
            middle := (low + high) / 2
            if on_screen(linear_rgb(lightness, middle, hue)) do low = middle
            else do high = middle
        }
        fitted = low
    }

    color: u32 = 0xFF
    for channel, index in linear_rgb(lightness, fitted, hue) {
        value := clamp(channel, 0, 1)
        gamma := 12.92 * value if value <= 0.0031308 else 1.055 * math.pow(value, 1 / 2.4) - 0.055
        color |= u32(math.round(255 * gamma)) << u32(24 - 8 * index)
    }
    return color
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

glow_params :: proc(config: ^Config) -> GlowParams {
    glows := GLOWS
    glow := glows[config.strobe_colorway]
    if config.strobe_colorway == .BY_NOTE do glow.color, glow.dark_color = by_note_colors.x, by_note_colors.x
    return glow
}

strobe_colors :: proc(config: ^Config) -> [2]u32 {
    if config.strobe_colorway == .BY_NOTE do return by_note_colors

    colorways := COLORWAYS
    return colorways[config.strobe_colorway]
}
