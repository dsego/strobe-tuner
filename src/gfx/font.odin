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


package gfx

import "core:fmt"
import "core:math"
import stb_truetype "vendor:stb/truetype"

Glyph :: struct {
    source:  Rect, // in the font atlas
    offset:  [2]f32, // from the text position, at base_size
    advance: f32,
}

Font :: struct {
    texture:   Texture,
    base_size: f32,
    glyphs:    map[rune]Glyph,
    fallback:  Glyph, // for missing glyphs, the first one
}

// A glyph's bitmap and where it goes in the font atlas, in pixels at the atlas size
GlyphBox :: struct {
    codepoint: rune,
    x0, y0:    i32, // the bitmap's top left from the text position, y0 from the baseline
    width:     i32,
    height:    i32,
    atlas:     [2]i32,
}

GLYPH_PADDING :: 2 // keeps the neighbours out of the linear filtering

// Bakes the glyphs into an atlas at size, drawn scaled from there
load_font :: proc(ttf: []u8, size: i32, codepoints: string) -> (font: Font) {
    info: stb_truetype.fontinfo
    if !stb_truetype.InitFont(&info, raw_data(ttf), 0) {
        fmt.eprintln("Could not load font")
        return
    }

    scale := stb_truetype.ScaleForPixelHeight(&info, f32(size))
    boxes := measure_glyphs(&info, scale, codepoints)
    atlas_size := pack_glyphs(boxes)

    for box in boxes do font.glyphs[box.codepoint] = glyph_from_box(&info, box, scale)

    coverage := rasterize_glyphs(&info, boxes, scale, atlas_size)
    font.texture = create_texture(atlas_size.x, atlas_size.y, white_pixels(coverage))
    font.base_size = f32(size)
    if len(boxes) > 0 do font.fallback = font.glyphs[boxes[0].codepoint]

    return
}

// Each glyph's bitmap size at scale, in the order of codepoints, each codepoint once
measure_glyphs :: proc(info: ^stb_truetype.fontinfo, scale: f32, codepoints: string) -> []GlyphBox {
    boxes := make([dynamic]GlyphBox, context.temp_allocator)
    seen := make(map[rune]bool, context.temp_allocator)
    for codepoint in codepoints {
        if codepoint in seen do continue

        seen[codepoint] = true

        box := GlyphBox {
            codepoint = codepoint,
        }
        x1, y1: i32
        stb_truetype.GetCodepointBitmapBox(info, codepoint, scale, scale, &box.x0, &box.y0, &x1, &y1)
        box.width = x1 - box.x0
        box.height = y1 - box.y0
        append(&boxes, box)
    }
    return boxes[:]
}

// Shelf packing: left to right in rows, a new row below when one is full. The atlas is about square, as wide
// as the boxes' area needs and never narrower than the widest glyph. Returns the atlas size.
pack_glyphs :: proc(boxes: []GlyphBox) -> [2]i32 {
    area, widest: i32
    for box in boxes {
        area += (box.width + GLYPH_PADDING) * (box.height + GLYPH_PADDING)
        widest = max(widest, box.width)
    }
    width := max(i32(math.ceil(math.sqrt(f32(area)))), widest) + 2 * GLYPH_PADDING

    pen: [2]i32 = GLYPH_PADDING
    row_height: i32 = 0
    for &box in boxes {
        if pen.x + box.width + GLYPH_PADDING > width {
            pen = {GLYPH_PADDING, pen.y + row_height + GLYPH_PADDING}
            row_height = 0
        }
        box.atlas = pen
        pen.x += box.width + GLYPH_PADDING
        row_height = max(row_height, box.height)
    }
    return {width, pen.y + row_height + GLYPH_PADDING}
}

// Where a packed glyph is in the atlas and how it's placed in a line of text
glyph_from_box :: proc(info: ^stb_truetype.fontinfo, box: GlyphBox, scale: f32) -> Glyph {
    ascent, descent, line_gap: i32
    stb_truetype.GetFontVMetrics(info, &ascent, &descent, &line_gap)

    // The advance rounded to whole pixels, the next glyph lands texel for pixel too. Cut down instead the
    // letters sit up to a pixel too close, unevenly.
    advance, left_side_bearing: i32
    stb_truetype.GetCodepointHMetrics(info, box.codepoint, &advance, &left_side_bearing)

    return Glyph {
        source  = {f32(box.atlas.x), f32(box.atlas.y), f32(box.width), f32(box.height)},
        offset  = {f32(box.x0), f32(box.y0 + i32(f32(ascent) * scale))},
        advance = math.round(f32(advance) * scale),
    }
}

// Each glyph's coverage drawn into its box, one byte per atlas pixel
rasterize_glyphs :: proc(
    info: ^stb_truetype.fontinfo,
    boxes: []GlyphBox,
    scale: f32,
    atlas_size: [2]i32,
) -> []u8 {
    coverage := make([]u8, atlas_size.x * atlas_size.y, context.temp_allocator)
    for box in boxes {
        if box.width <= 0 || box.height <= 0 do continue

        stb_truetype.MakeCodepointBitmap(
            info,
            &coverage[box.atlas.y * atlas_size.x + box.atlas.x],
            box.width,
            box.height,
            atlas_size.x,
            scale,
            scale,
            box.codepoint,
        )
    }
    return coverage
}

// RGBA white with the coverage as alpha, text is tinted when drawn
white_pixels :: proc(coverage: []u8) -> []u8 {
    pixels := make([]u8, len(coverage) * 4, context.temp_allocator)
    for alpha, index in coverage {
        pixels[index * 4 + 0] = 255
        pixels[index * 4 + 1] = 255
        pixels[index * 4 + 2] = 255
        pixels[index * 4 + 3] = alpha
    }
    return pixels
}

unload_font :: proc(font: Font) {
    unload_texture(font.texture)
    glyphs := font.glyphs
    delete(glyphs)
}

draw_text :: proc(
    font: Font,
    text: cstring,
    position: [2]f32,
    size: f32,
    spacing: f32,
    color: Color,
) {
    scale := size / font.base_size
    x := position.x
    for codepoint in string(text) {
        glyph, ok := font.glyphs[codepoint]
        if !ok do glyph = font.fallback

        if codepoint != ' ' && codepoint != '\t' && glyph.source.width > 0 {
            dest := Rect {
                x + glyph.offset.x * scale,
                position.y + glyph.offset.y * scale,
                glyph.source.width * scale,
                glyph.source.height * scale,
            }
            draw_texture(font.texture, glyph.source, dest, color)
        }
        x += glyph.advance * scale + spacing
    }
}

// Where a glyph's ink is from the text position at size. Glyphs from different fonts sit differently in their
// lines, centred on their ink they line up.
glyph_ink :: proc(font: Font, codepoint: rune, size: f32) -> Rect {
    scale := size / font.base_size
    glyph, ok := font.glyphs[codepoint]
    if !ok do glyph = font.fallback

    return {glyph.offset.x * scale, glyph.offset.y * scale, glyph.source.width * scale, glyph.source.height * scale}
}

measure_text :: proc(font: Font, text: cstring, size: f32, spacing: f32) -> [2]f32 {
    scale := size / font.base_size
    width: f32 = 0
    count := 0
    for codepoint in string(text) {
        glyph, ok := font.glyphs[codepoint]
        if !ok do glyph = font.fallback

        width += glyph.advance * scale
        count += 1
    }
    return {width + f32(max(count - 1, 0)) * spacing, size}
}
