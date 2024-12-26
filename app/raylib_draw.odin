package app

import "core:fmt"

import rl "vendor:raylib"

import "../core"

draw_note :: proc(
    note: core.Note,
    pos: [2]f32,
    size: f32,
    color: rl.Color,
    hide_accidental: bool = false,
) {
    if note.frequency == 0 do return

    // Note name
    rl.DrawTextEx(font, fmt.ctprintf("%v", note.name), pos, size, 0, color)

    // Sharp sign
    if note.is_accidental && !hide_accidental {
        rl.DrawTextEx(font, "♯", {pos.x + size / 2, pos.y + size / 8}, size / 2.5, 0, color)
    }

    // Octave number
    rl.DrawTextEx(
        font,
        fmt.ctprintf("%v", note.octave),
        {pos.x + size / 2, pos.y + size / 2},
        size / 2.5,
        0,
        color,
    )
}


draw_cent_deviation :: proc(phase_tracker: ^core.PhaseTracker) {
    data_points := phase_tracker.data_points
    x: f32 = 86
    i := phase_tracker.data_points_head

    draw_point :: proc(x: f32, value: f32, alpha: f32) {
        y := 400 - value * 10
        if y > 300 {
            rl.DrawPixelV({x, y}, rl.ColorAlpha(rl.GREEN, alpha))
        }
    }

    for i >= 0 {
        draw_point(x, data_points[i].err_cents, data_points[i].amp)
        x += 0.5
        i -= 1
    }

    i = len(data_points) - 1

    for i > phase_tracker.data_points_head {
        draw_point(x, data_points[i].err_cents, data_points[i].amp)
        x += 0.5
        i -= 1
    }

    rl.DrawLineV({86.0, 400.0}, {598.0, 400.0}, rl.LIGHTGRAY)
}
