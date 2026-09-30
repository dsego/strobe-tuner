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

// Missing ones draw as the first, the space too. Inter has no ♯, it comes from Noto.
FONT_CODEPOINTS :: " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#/+-−1234567890.,:π!×½()[]¢·%"

// Phosphor Regular (phosphoricons.com), the font is cut down to these, to add one:
//   uvx --from fonttools pyftsubset Phosphor.ttf --unicodes=U+E272,U+E326,... --no-hinting \
//       --output-file=assets/fonts/phosphor/Phosphor-Icons.ttf
// The codepoints are in the style.css of the @phosphor-icons/web package.
ICON_SLIDERS: cstring : "\ue432"
ICON_CARET_UP: cstring : "\ue13c"
ICON_TRASH: cstring : "\ue4a8"
ICON_PLUS_MINUS: cstring : "\ue3d8"
ICON_GEAR: cstring : ""
ICON_MICROPHONE: cstring : ""
ICON_CARET_DOWN: cstring : ""
ICON_MINUS: cstring : ""
ICON_PLUS: cstring : ""
ICON_X: cstring : ""

ICON_CODEPOINTS :: "\ue432\ue13c\ue4a8\ue3d8"

// All the text is rasterized at exactly the size it's drawn at on this screen, a scaled atlas is soft or
// jagged. Point sizes, whole pixels at 1x, 2x and 3x.
LABEL_SIZE :: 14 // the controls and most of the text
LABEL_LARGE_SIZE :: 16
STEPPER_SIZE :: 24 // the − and + and the key of the transpose, half again a large label
LABEL_SMALL_SIZE :: 12 // the buttons that reset and clear, the debug stats
LABEL_TIMES_SIZE :: 18 // the × as large as the body of a ¢ in a label
TITLE_SIZE :: 18
ICON_SIZE :: 16
ICON_LARGE_SIZE :: 24
// The note without the ruler
NOTE_NAME_SIZE :: 128
NOTE_OCTAVE_SIZE :: 38
NOTE_SHARP_SIZE :: 48
// The ruler, scaled by the layout
RULER_NOTE_SIZE :: 88 // the target note
RULER_NEIGHBOUR_SIZE :: 52
RULER_OCTAVE_SIZE :: 26
// The sharps 3/8 of their letter like NOTE_SHARP_SIZE, the octave already matches
RULER_NOTE_SHARP_SIZE :: 33
RULER_NEIGHBOUR_SHARP_SIZE :: 20
READOUT_SIZE :: 24 // the Hz and cents values, they grow with the ruler
NOTE_ARROW_SIZE :: 26 // either side of the note without the ruler
STROBE_ARROW_SIZE :: 22 // over the strobe, which way to tune

// A font and the point size that draws it one texel to one pixel
PixelFont :: struct {
    font: Font,
    size: f32,
}

PixelFonts :: struct {
    scale:           f32, // the DPI scale they were loaded for
    ruler_scale:     f32, // the ruler's sizes relative to the desktop, see Layout
    label:           PixelFont,
    label_large:     PixelFont,
    label_small:     PixelFont,
    stepper:         PixelFont,
    label_times:     PixelFont, // the × after a label's digits, Inter's is only as tall as a lowercase letter
    title:           PixelFont,
    icon:            PixelFont,
    icon_large:      PixelFont,
    note_name:       PixelFont, // the note without the ruler
    note_octave:     PixelFont,
    note_name_sharp: PixelFont,
    note:            PixelFont, // the ruler's target note
    neighbour:       PixelFont,
    octave:          PixelFont,
    note_sharp:      PixelFont,
    neighbour_sharp: PixelFont,
    readout:         PixelFont,
    note_arrow:      PixelFont,
    strobe_arrow:    PixelFont,
}

pixel_fonts: PixelFonts

// Called before the frame starts, reloads when the window moves to a screen with another scale or the
// layout sizes the ruler differently
update_pixel_fonts :: proc(ruler_scale: f32) {
    scale := gfx_dpi_scale()
    if scale == pixel_fonts.scale && ruler_scale == pixel_fonts.ruler_scale do return
    unload_pixel_fonts()

    inter_medium := #load("../assets/fonts/inter/Inter-Medium.ttf")
    inter_bold := #load("../assets/fonts/inter/Inter-Bold.ttf")
    noto_sans_mono := #load("../assets/fonts/noto/NotoSansMono-Medium.ttf")
    phosphor := #load("../assets/fonts/phosphor/Phosphor-Icons.ttf")
    load :: proc(ttf: []u8, points, scale: f32, codepoints: string) -> PixelFont {
        pixels := math.round(points * scale)
        return {gfx_load_font(ttf, i32(pixels), codepoints), pixels / scale}
    }

    pixel_fonts = {
        scale           = scale,
        ruler_scale     = ruler_scale,
        label           = load(inter_medium, LABEL_SIZE, scale, FONT_CODEPOINTS),
        label_large     = load(inter_medium, LABEL_LARGE_SIZE, scale, FONT_CODEPOINTS),
        label_small     = load(inter_medium, LABEL_SMALL_SIZE, scale, FONT_CODEPOINTS),
        stepper         = load(inter_medium, STEPPER_SIZE, scale, "ABCDEFGb+−"),
        label_times     = load(inter_medium, LABEL_TIMES_SIZE, scale, "×"),
        title           = load(inter_bold, TITLE_SIZE, scale, FONT_CODEPOINTS),
        icon            = load(phosphor, ICON_SIZE, scale, ICON_CODEPOINTS),
        icon_large      = load(phosphor, ICON_LARGE_SIZE, scale, ICON_CODEPOINTS),
        note_name       = load(inter_medium, NOTE_NAME_SIZE, scale, "ABCDEFG"),
        note_octave     = load(inter_medium, NOTE_OCTAVE_SIZE, scale, "0123456789"),
        note_name_sharp = load(noto_sans_mono, NOTE_SHARP_SIZE, scale, "♯"),
        note            = load(inter_medium, ruler_scale * RULER_NOTE_SIZE, scale, "ABCDEFG"),
        neighbour       = load(inter_medium, ruler_scale * RULER_NEIGHBOUR_SIZE, scale, "ABCDEFG"),
        octave          = load(inter_medium, ruler_scale * RULER_OCTAVE_SIZE, scale, "0123456789"),
        note_sharp      = load(noto_sans_mono, ruler_scale * RULER_NOTE_SHARP_SIZE, scale, "♯"),
        neighbour_sharp = load(noto_sans_mono, ruler_scale * RULER_NEIGHBOUR_SHARP_SIZE, scale, "♯"),
        readout         = load(inter_medium, ruler_scale * READOUT_SIZE, scale, "0123456789.-+"),
        note_arrow      = load(inter_medium, NOTE_ARROW_SIZE, scale, "◀▶"),
        strobe_arrow    = load(inter_medium, STROBE_ARROW_SIZE, scale, "◀▶"),
    }
}

unload_pixel_fonts :: proc() {
    if pixel_fonts.scale == 0 do return
    gfx_unload_font(pixel_fonts.label.font)
    gfx_unload_font(pixel_fonts.label_large.font)
    gfx_unload_font(pixel_fonts.label_small.font)
    gfx_unload_font(pixel_fonts.stepper.font)
    gfx_unload_font(pixel_fonts.label_times.font)
    gfx_unload_font(pixel_fonts.title.font)
    gfx_unload_font(pixel_fonts.icon.font)
    gfx_unload_font(pixel_fonts.icon_large.font)
    gfx_unload_font(pixel_fonts.note_name.font)
    gfx_unload_font(pixel_fonts.note_octave.font)
    gfx_unload_font(pixel_fonts.note_name_sharp.font)
    gfx_unload_font(pixel_fonts.note.font)
    gfx_unload_font(pixel_fonts.neighbour.font)
    gfx_unload_font(pixel_fonts.octave.font)
    gfx_unload_font(pixel_fonts.note_sharp.font)
    gfx_unload_font(pixel_fonts.neighbour_sharp.font)
    gfx_unload_font(pixel_fonts.readout.font)
    gfx_unload_font(pixel_fonts.note_arrow.font)
    gfx_unload_font(pixel_fonts.strobe_arrow.font)
    pixel_fonts = {}
}

// Whole pixels on this screen, so text drawn at a pixel font's size lands texel for pixel
snap_to_pixels :: proc(p: [2]f32) -> [2]f32 {
    scale := pixel_fonts.scale
    return {math.round(p.x * scale), math.round(p.y * scale)} / scale
}

// Icon with its top left at position, ICON_SIZE or ICON_LARGE_SIZE
draw_icon :: proc(icon: cstring, position: [2]f32, color: Color, large := false) {
    font := pixel_fonts.icon_large if large else pixel_fonts.icon
    draw_text(font.font, icon, snap_to_pixels(position), font.size, 0, color)
}

// Text in a pixel font, snapped to whole pixels
draw_label :: proc(font: PixelFont, text: cstring, position: [2]f32, color: Color, spacing: f32 = 0) {
    draw_text(font.font, text, snap_to_pixels(position), font.size, spacing, color)
}

measure_label :: proc(font: PixelFont, text: cstring, spacing: f32 = 0) -> [2]f32 {
    return measure_text(font.font, text, font.size, spacing)
}
