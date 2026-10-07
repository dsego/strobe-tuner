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
}

// The lit stripes and the dark ones
COLORWAYS :: [StrobeColorway][2]u32 {
    .VIBRANT_RED = {0xFF6767FF, 0x6B4949FF},
    .MINTY       = {0xB5F2DBFF, 0x6B3D7DFF},
    .AMBER       = {0xFF9A4DFF, 0x6B4A38FF},
    // Black and white, the most contrast and no hue to tell apart
    .MONO        = {0xF2F1ECFF, 0x55565EFF},
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
}

glow_params :: proc(config: ^Config) -> GlowParams {
    glows := GLOWS
    return glows[config.strobe_colorway]
}

strobe_colors :: proc(config: ^Config) -> [2]u32 {
    colorways := COLORWAYS
    return colorways[config.strobe_colorway]
}
