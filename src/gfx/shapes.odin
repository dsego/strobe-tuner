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

// A disc the size of the square rect, its left half in one color and its right half in the other
draw_split_disc :: proc(rect: Rect, left, right: Color) {
    half: f32 = SHAPE_SIZE / 2
    middle := rect.x + rect.width / 2
    draw_texture(shape_texture, {0, 0, half, SHAPE_SIZE}, {rect.x, rect.y, rect.width / 2, rect.height}, left)
    draw_texture(shape_texture, {half, 0, half, SHAPE_SIZE}, {middle, rect.y, rect.width / 2, rect.height}, right)
}

draw_rect :: proc(position: [2]f32, size: [2]f32, color: Color) {
    push_quad(gpu.white.handle, {position.x, position.y, size.x, size.y}, {0, 0}, {1, 1}, color)
}

draw_triangle :: proc(first, second, third: [2]f32, color: Color) {
    push_vertices(gpu.white.handle, {{first, {0, 0}, color}, {second, {1, 0}, color}, {third, {1, 1}, color}})
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

// A line from start to end whose sides fade to clear over feather, its ends cut square like draw_line's.
// Drawn piece by piece a jagged line keeps its corners, where a polyline's joints pinch a sharp spike thin
// toward its tip.
draw_soft_line :: proc(start, end: [2]f32, thickness, feather: f32, color: Color) {
    if start == end do return

    normal := line_normal(start, end)
    half := 0.5 * thickness
    inner := max(half - feather, 0)
    edge := Color{color.r, color.g, color.b, 0}

    // Across the line from one edge to the other, clear, solid, solid and clear
    across := [4]f32{-half, -inner, inner, half}
    colors := [4]Color{edge, color, color, edge}
    for band in 0 ..< 3 {
        near, far := normal * across[band], normal * across[band + 1]
        push_vertices(
            gpu.white.handle,
            {
                {start + near, {0, 0}, colors[band]},
                {end + near, {0, 0}, colors[band]},
                {end + far, {0, 0}, colors[band + 1]},
                {start + near, {0, 0}, colors[band]},
                {end + far, {0, 0}, colors[band + 1]},
                {start + far, {0, 0}, colors[band + 1]},
            },
        )
    }
}

// The unit normal of the line from start to end, to its left on the screen, none for a point
line_normal :: proc(start, end: [2]f32) -> [2]f32 {
    direction := linalg.normalize0(end - start)
    return {-direction.y, direction.x}
}

// A wide line through the points in one strip, the pieces meet on a mitred joint without overlapping, a
// translucent line is as even at the joints as along them. A spike's mitre is cut at twice the width. Closed,
// the last point is the first again and they meet on a joint too.
draw_polyline :: proc(points: [][2]f32, thickness: f32, color: Color, closed := false) {
    if len(points) < 2 do return

    half := 0.5 * thickness
    previous := polyline_side(points, 0, closed) * half
    for index in 1 ..< len(points) {
        offset := polyline_side(points, index, closed) * half
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
// both ends round. A pixel's feather smooths a thin line, half the thickness makes a soft glow. Closed, the
// last point is the first again and they meet on a joint like the others: two round ends there would lie
// over each other, their faded edges and a glow adding up to a brighter spot.
draw_soft_polyline :: proc(points: [][2]f32, colors: []Color, thickness, feather: f32, closed := false) {
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

    // Across the line at a point from one edge to the other, clear, solid, solid and clear. The inside of a
    // turn tighter than the line is wide is cut short where it would cross itself, see polyline_turn, as faded
    // as the line is there. Folded over its own edge, a wide glow's faded rows piled up in specks inside the
    // tips of the scope's lobes, squeezed into the room they faded to clear there and left a dark one.
    rows :: proc(points: [][2]f32, index: int, closed: bool, color: Color, inner, half: f32) -> [4]Vertex {
        side := polyline_side(points, index, closed)
        inside, room := polyline_turn(points, index, closed)

        // The minus side's and the plus side's: how far it's solid, how far its edge and the edge's color
        solid := [2]f32{inner, inner}
        reach := [2]f32{half, half}
        edges := [2]Color{transparent(color), transparent(color)}
        if room < half {
            cut := 1 if linalg.dot(side, inside) > 0 else 0
            solid[cut] = min(inner, room)
            reach[cut] = room
            fade := f32(1) if room <= inner else 1 - (room - inner) / (half - inner)
            edges[cut].a = u8(math.round(f32(color.a) * fade))
        }

        point := points[index]
        return {
            {point - side * reach[0], {0, 0}, edges[0]},
            {point - side * solid[0], {0, 0}, color},
            {point + side * solid[1], {0, 0}, color},
            {point + side * reach[1], {0, 0}, edges[1]},
        }
    }

    previous := rows(points, 0, closed, colors[0], inner, half)
    for index in 1 ..= last {
        current := rows(points, index, closed, colors[index], inner, half)
        for band in 0 ..< 3 {
            push_vertices(
                gpu.white.handle,
                {previous[band], current[band], current[band + 1], previous[band], current[band + 1], previous[band + 1]},
            )
        }
        previous = current
    }
    if closed do return

    round_end(points[0], linalg.normalize0(points[0] - points[1]), colors[0], inner, half)
    round_end(points[last], linalg.normalize0(points[last] - points[last - 1]), colors[last], inner, half)
}

// Which way a line turns at a point, toward its inside, and how far either side of it the inside can reach
// before its edge crosses itself: the edges of two pieces meet tan(turn / 2) of that along each, at most halfway
// along the shorter, about the curve's radius on a smooth line. Straight, at an open line's ends or beside a
// piece too short to have a direction, any width fits. Closed, the neighbors wrap as in polyline_side.
polyline_turn :: proc(points: [][2]f32, index: int, closed := false) -> (inside: [2]f32, room: f32) {
    MIN_PIECE :: 1e-3 // points

    last := len(points) - 1
    previous, next := max(index - 1, 0), min(index + 1, last)
    if closed && last >= 2 {
        if index == 0 {
            previous = last - 1
        }
        if index == last {
            next = 1
        }
    }

    before := points[index] - points[previous]
    after := points[next] - points[index]
    before_length, after_length := linalg.length(before), linalg.length(after)
    if before_length < MIN_PIECE || after_length < MIN_PIECE do return {}, math.F32_MAX

    before /= before_length
    after /= after_length
    cosine := clamp(linalg.dot(before, after), -1, 1)
    half_turn_tangent := math.sqrt((1 - cosine) / max(1 + cosine, 1e-6))
    inside = after - before
    room = 0.5 * min(before_length, after_length) / max(half_turn_tangent, 1e-6)
    return
}

// The offset either side at a point of a line a half width of one across, along the bisector of its two
// pieces, a spike's mitre cut at twice the width. Closed, the ends are the same point, the piece before the
// first is the last one and the piece after the last is the first.
polyline_side :: proc(points: [][2]f32, index: int, closed := false) -> [2]f32 {
    last := len(points) - 1
    before := line_normal(points[max(index - 1, 0)], points[index])
    after := line_normal(points[index], points[min(index + 1, last)])
    if closed && last >= 2 {
        if index == 0 {
            before = line_normal(points[last - 1], points[0])
        }
        if index == last {
            after = line_normal(points[last], points[1])
        }
    } else {
        if index == 0 {
            before = after
        }
        if index == last {
            after = before
        }
    }

    bisector := before + after
    if linalg.length(bisector) < 1e-6 do return before

    bisector = linalg.normalize(bisector)
    cosine := linalg.dot(bisector, after)
    return bisector * min(1 / max(cosine, 1e-6), 2)
}

// A disc in equal slices, one per color, the first from the top and the rest clockwise. The rim fades out
// over the feather, the slices meet on a hard edge.
draw_sector_disc :: proc(center: [2]f32, radius: f32, colors: []Color, feather: f32) {
    STEPS :: 6 // per slice, enough for a round rim
    inner := max(radius - feather, 0)
    for color, slice in colors {
        edge := Color{color.r, color.g, color.b, 0}
        for step in 0 ..< STEPS {
            angle1 := math.TAU * (f32(slice) + f32(step) / STEPS) / f32(len(colors))
            angle2 := math.TAU * (f32(slice) + f32(step + 1) / STEPS) / f32(len(colors))
            direction1 := [2]f32{math.sin(angle1), -math.cos(angle1)}
            direction2 := [2]f32{math.sin(angle2), -math.cos(angle2)}
            push_vertices(
                gpu.white.handle,
                {
                    {center, {0, 0}, color},
                    {center + direction1 * inner, {0, 0}, color},
                    {center + direction2 * inner, {0, 0}, color},
                    {center + direction1 * inner, {0, 0}, color},
                    {center + direction1 * radius, {0, 0}, edge},
                    {center + direction2 * radius, {0, 0}, edge},
                    {center + direction1 * inner, {0, 0}, color},
                    {center + direction2 * radius, {0, 0}, edge},
                    {center + direction2 * inner, {0, 0}, color},
                },
            )
        }
    }
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
