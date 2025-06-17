package app

import "core:fmt"
import "core:math"

import rl "vendor:raylib"

import "../core"


texture_atlas: rl.Texture2D


load_texture_atlas :: proc() {
    file_data := #load("../assets/atlas.2x.png")
    image := rl.LoadImageFromMemory(".png", raw_data(file_data), i32(len(file_data)))
    texture_atlas = rl.LoadTextureFromImage(image)
    // rl.SetTextureFilter(texture_atlas, rl.TextureFilter.BILINEAR)
    rl.UnloadImage(image)
}

unload_texture_atlas :: proc() {
    rl.UnloadTexture(texture_atlas)
}

gui_strobe_mode_toggle :: proc(
    position: [2]f32,
    active_strobe_mode: core.StrobeMode,
) -> (
    core.StrobeMode,
    bool,
) {
    text_color := rl.GetColor(0x15141BFF)

    if active_strobe_mode == .HARMONIC_MODE {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 96, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_48,
            "HARMONIC",
            rl.Vector2{position.x + 18.0, position.y},
            24,
            0,
            text_color,
        )
    } else {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 0, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_48,
            "VERNIER",
            rl.Vector2{position.x + 22.0, position.y},
            24,
            0,
            text_color,
        )
    }

    if gui_button({position.x, position.y, 120, 24}) {
        if active_strobe_mode == .HARMONIC_MODE do return .VERNIER_MODE, true
        else do return .HARMONIC_MODE, true
    }

    return active_strobe_mode, false
}


gui_note_detection_mode_toggle :: proc(
    position: [2]f32,
    active_detection_mode: NoteDetectionMode,
) -> (
    NoteDetectionMode,
    bool,
) {
    text_color := rl.GetColor(0x15141BFF)

    if active_detection_mode == .AUTO {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 48, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_48,
            "AUTO",
            rl.Vector2{position.x + 18.0, position.y},
            24,
            0,
            text_color,
        )
    } else {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 0, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_48,
            "MANUAL",
            rl.Vector2{position.x + 22.0, position.y},
            24,
            0,
            text_color,
        )
    }

    if gui_button({position.x, position.y, 120, 24}) {
        if active_detection_mode == .AUTO do return .MANUAL, true
        else do return .AUTO, true
    }

    return active_detection_mode, false
}

// note_detection_mode_toggle


// rl.DrawTexture(texture_atlas, 10, 10, rl.WHITE)
// rl.DrawTexturePro(
//     texture_atlas,
//     rl.Rectangle{0, 48, 240, 48},
//     rl.Rectangle{0, 0, 120, 24},
//     rl.Vector2{-100, -400},
//     0,
//     rl.WHITE,
// )
// rl.DrawRectangleLines(100, 10, 120,24, rl.ORANGE)


gui_button :: proc(bounds: rl.Rectangle) -> bool {
    mouse_point := rl.GetMousePosition()
    if rl.CheckCollisionPointRec(mouse_point, bounds) {
        if rl.IsMouseButtonReleased(rl.MouseButton.LEFT) {
            return true
        }
    }
    return false
}


draw_note :: proc(note: core.Note, pos: [2]f32, color: rl.Color, hide_accidental: bool = false) {
    if note.frequency == 0 do return

    // Note name
    rl.DrawTextEx(font_store.size_192, fmt.ctprintf("%v", note.name), pos, 96, 0, color)

    // Sharp sign
    if note.is_accidental && !hide_accidental {
        rl.DrawTextEx(font_store.size_192, "♯", {pos.x + 48, pos.y + 12}, 38, 0, color)
    }

    // Octave number
    rl.DrawTextEx(
        font_store.size_192,
        fmt.ctprintf("%v", note.octave),
        {pos.x + 48, pos.y + 48},
        38,
        0,
        color,
    )
}


// draw_cent_deviation :: proc(
//     phase_comparator: ^core.PhaseComparator,
//     rect: rl.Rectangle,
//     max_samples: int,
// ) {
//     rl.DrawRectangleLinesEx(rect, 1.0, rl.ORANGE)

//     data_points := phase_comparator.data_points
//     x: f32 = rect.x
//     y: f32 = rect.y + rect.height * 0.5

//     dx := rect.width / f32(max_samples - 1)
//     i := phase_comparator.data_points_head

//     draw_point :: proc(x: f32, y: f32, value: f32, alpha: f32) {
//         rl.DrawPixelV({x, y - value}, rl.ColorAlpha(rl.GREEN, alpha))
//     }
//     limit := rect.x + rect.width

//     for i >= 0 && x <= limit {
//         draw_point(x, y, data_points[i].err_cents, data_points[i].amp)
//         x += dx * f32(data_points[i].sample_count)
//         i -= 1
//     }

//     i = len(data_points) - 1

//     for i > phase_comparator.data_points_head && x <= limit {
//         draw_point(x, y, data_points[i].err_cents, data_points[i].amp)
//         x += dx * f32(data_points[i].sample_count)
//         i -= 1
//     }

//     rl.DrawLineV({rect.x, y}, {rect.x + rect.width, y}, rl.LIGHTGRAY)
// }
