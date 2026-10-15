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

import "core:math"
import "core:math/linalg"

// Rounded shapes are cut from one white anti-aliased circle generated at startup and tinted when drawn:
// the quarters make the corners, the middle row and column stretch into the straight edges. The rest are
// triangles over the white texture, tinted by their vertices.

// Pixels, a 24pt pill at 2x, the size of all the buttons
SHAPE_SIZE :: 48

shape_texture: Texture

load_shapes :: proc() {
    pixels: [SHAPE_SIZE * SHAPE_SIZE * 4]u8
    radius: f32 = SHAPE_SIZE / 2

    for y in 0 ..< SHAPE_SIZE {
        for x in 0 ..< SHAPE_SIZE {
            // Distance from the pixel centre to the edge covers the pixel partially
            distance := linalg.length([2]f32{f32(x) + 0.5, f32(y) + 0.5} - radius)
            coverage := clamp(radius - distance + 0.5, 0, 1)

            pixel := (y * SHAPE_SIZE + x) * 4
            pixels[pixel + 0] = 255
            pixels[pixel + 1] = 255
            pixels[pixel + 2] = 255
            pixels[pixel + 3] = u8(coverage * 255 + 0.5)
        }
    }

    shape_texture = create_texture(SHAPE_SIZE, SHAPE_SIZE, pixels[:])
}

unload_shapes :: proc() {
    unload_texture(shape_texture)
}

draw_rounded_rect :: proc(rect: Rect, radius: f32, color: Color) {
    corner := min(radius, rect.width / 2, rect.height / 2)
    half: f32 = SHAPE_SIZE / 2

    left, right := rect.x, rect.x + rect.width - corner
    top, bottom := rect.y, rect.y + rect.height - corner
    inner := [2]f32{rect.width - 2 * corner, rect.height - 2 * corner}

    // Corners
    draw_texture(shape_texture, {0, 0, half, half}, {left, top, corner, corner}, color)
    draw_texture(shape_texture, {half, 0, half, half}, {right, top, corner, corner}, color)
    draw_texture(shape_texture, {0, half, half, half}, {left, bottom, corner, corner}, color)
    draw_texture(shape_texture, {half, half, half, half}, {right, bottom, corner, corner}, color)

    // Edges
    if inner.x > 0 {
        draw_texture(shape_texture, {half - 0.5, 0, 1, half}, {left + corner, top, inner.x, corner}, color)
        draw_texture(shape_texture, {half - 0.5, half, 1, half}, {left + corner, bottom, inner.x, corner}, color)
    }
    if inner.y > 0 {
        draw_texture(shape_texture, {0, half - 0.5, half, 1}, {left, top + corner, corner, inner.y}, color)
        draw_texture(shape_texture, {half, half - 0.5, half, 1}, {right, top + corner, corner, inner.y}, color)
    }

    if inner.x > 0 && inner.y > 0 {
        draw_rect({left + corner, top + corner}, inner, color)
    }
}

// Fully rounded ends
draw_pill :: proc(rect: Rect, color: Color) {
    draw_rounded_rect(rect, rect.height / 2, color)
}

draw_rect :: proc(position: [2]f32, size: [2]f32, color: Color) {
    push_quad(gpu.white.handle, {position.x, position.y, size.x, size.y}, {0, 0}, {1, 1}, color)
}

draw_line :: proc(start, end: [2]f32, thickness: f32, color: Color) {
    if start == end do return

    normal := line_normal(start, end) * 0.5 * thickness

    push_vertices(
        gpu.white.handle,
        {
            {start + normal, {0, 0}, color},
            {end + normal, {1, 0}, color},
            {end - normal, {1, 1}, color},
            {start + normal, {0, 0}, color},
            {end - normal, {1, 1}, color},
            {start - normal, {0, 1}, color},
        },
    )
}

// The unit normal of the line from start to end, to its left on the screen, none for a point
line_normal :: proc(start, end: [2]f32) -> [2]f32 {
    direction := linalg.normalize0(end - start)
    return {-direction.y, direction.x}
}

// A wide line through the points in one strip, the pieces meet on a mitred joint without overlapping, a
// translucent line is as even at the joints as along them. A spike's mitre is cut at twice the width.
draw_polyline :: proc(points: [][2]f32, thickness: f32, color: Color) {
    if len(points) < 2 do return

    half := 0.5 * thickness
    previous := polyline_side(points, 0) * half
    for index in 1 ..< len(points) {
        offset := polyline_side(points, index) * half
        start, end := points[index - 1], points[index]
        push_vertices(
            gpu.white.handle,
            {
                {start + previous, {0, 0}, color},
                {end + offset, {1, 0}, color},
                {end - offset, {1, 1}, color},
                {start + previous, {0, 0}, color},
                {end - offset, {1, 1}, color},
                {start - previous, {0, 1}, color},
            },
        )
        previous = offset
    }
}

// A line through the points, fading to clear over feather inside its edges, each point in its own color and
// both ends round. A pixel's feather smooths a thin line, half the thickness makes a soft glow.
draw_soft_polyline :: proc(points: [][2]f32, colors: []Color, thickness, feather: f32) {
    if len(points) == 0 do return

    half := 0.5 * thickness
    inner := max(half - feather, 0)

    transparent :: proc(color: Color) -> Color {
        return {color.r, color.g, color.b, 0}
    }

    // A half disc around center on the outward side, solid out to inner and fading out to half
    round_end :: proc(center, outward: [2]f32, color: Color, inner, half: f32) {
        STEPS :: 8
        across := [2]f32{-outward.y, outward.x}
        edge := transparent(color)
        for step in 0 ..< STEPS {
            angle1 := math.PI * f32(step) / STEPS
            angle2 := math.PI * f32(step + 1) / STEPS
            direction1 := across * math.cos(angle1) + outward * math.sin(angle1)
            direction2 := across * math.cos(angle2) + outward * math.sin(angle2)
            push_vertices(
                gpu.white.handle,
                {
                    {center, {0, 0}, color},
                    {center + direction1 * inner, {0, 0}, color},
                    {center + direction2 * inner, {0, 0}, color},
                    {center + direction1 * inner, {0, 0}, color},
                    {center + direction1 * half, {0, 0}, edge},
                    {center + direction2 * half, {0, 0}, edge},
                    {center + direction1 * inner, {0, 0}, color},
                    {center + direction2 * half, {0, 0}, edge},
                    {center + direction2 * inner, {0, 0}, color},
                },
            )
        }
    }

    last := len(points) - 1
    if last == 0 {
        round_end(points[0], {1, 0}, colors[0], inner, half)
        round_end(points[0], {-1, 0}, colors[0], inner, half)
        return
    }

    // Across the line from one edge to the other, clear, solid, solid and clear
    rows :: proc(point, side: [2]f32, color: Color, inner, half: f32) -> [4]Vertex {
        edge := transparent(color)
        return {
            {point - side * half, {0, 0}, edge},
            {point - side * inner, {0, 0}, color},
            {point + side * inner, {0, 0}, color},
            {point + side * half, {0, 0}, edge},
        }
    }

    previous := rows(points[0], polyline_side(points, 0), colors[0], inner, half)
    for index in 1 ..= last {
        current := rows(points[index], polyline_side(points, index), colors[index], inner, half)
        for band in 0 ..< 3 {
            push_vertices(
                gpu.white.handle,
                {previous[band], current[band], current[band + 1], previous[band], current[band + 1], previous[band + 1]},
            )
        }
        previous = current
    }

    round_end(points[0], linalg.normalize0(points[0] - points[1]), colors[0], inner, half)
    round_end(points[last], linalg.normalize0(points[last] - points[last - 1]), colors[last], inner, half)
}

// The offset either side at a point of a line a half width of one across, along the bisector of its two
// pieces, a spike's mitre cut at twice the width
polyline_side :: proc(points: [][2]f32, index: int) -> [2]f32 {
    before := line_normal(points[max(index - 1, 0)], points[index])
    after := line_normal(points[index], points[min(index + 1, len(points) - 1)])
    if index == 0 do before = after
    if index == len(points) - 1 do after = before

    bisector := before + after
    if linalg.length(bisector) < 1e-6 do return before

    bisector = linalg.normalize(bisector)
    cosine := linalg.dot(bisector, after)
    return bisector * min(1 / max(cosine, 1e-6), 2)
}

draw_circle :: proc(center: [2]f32, radius: f32, color: Color) {
    SEGMENTS :: 24
    for i in 0 ..< SEGMENTS {
        a0 := f32(i) / SEGMENTS * math.TAU
        a1 := f32(i + 1) / SEGMENTS * math.TAU
        push_vertices(
            gpu.white.handle,
            {
                {center, {0, 0}, color},
                {center + radius * [2]f32{math.cos(a0), math.sin(a0)}, {0, 0}, color},
                {center + radius * [2]f32{math.cos(a1), math.sin(a1)}, {0, 0}, color},
            },
        )
    }
}
