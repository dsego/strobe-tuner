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


draw_cent_deviation :: proc(
    phase_tracker: ^core.PhaseTracker,
    rect: rl.Rectangle,
    max_samples: int,
) {
    rl.DrawRectangleLinesEx(rect, 1.0, rl.ORANGE)

    data_points := phase_tracker.data_points
    x: f32 = rect.x
    y: f32 = rect.y + rect.height * 0.5

    dx := rect.width / f32(max_samples - 1)
    i := phase_tracker.data_points_head

    draw_point :: proc(x: f32, y: f32, value: f32, alpha: f32) {
        rl.DrawPixelV({x, y - value}, rl.ColorAlpha(rl.GREEN, alpha))
    }
    limit := rect.x + rect.width

    for i >= 0 && x <= limit {
        draw_point(x, y, data_points[i].err_cents, data_points[i].amp)
        x += dx * f32(data_points[i].sample_count)
        i -= 1
    }

    i = len(data_points) - 1

    for i > phase_tracker.data_points_head && x <= limit {
        draw_point(x, y, data_points[i].err_cents, data_points[i].amp)
        x += dx * f32(data_points[i].sample_count)
        i -= 1
    }

    rl.DrawLineV({rect.x, y}, {rect.x + rect.width, y}, rl.LIGHTGRAY)
}
