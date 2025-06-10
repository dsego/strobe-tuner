package app

import rl "vendor:raylib"
import "core:fmt"

import "../core"


RoundedBox :: struct {
    shader: rl.Shader,
    top_left_radius_loc: i32,
    top_right_radius_loc: i32,
    bottom_left_radius_loc: i32,
    bottom_right_radius_loc: i32,
    border_color_loc: i32,
    border_thickness_locs: i32,
}

rounded_box : RoundedBox = {}



// rl.SetShaderValue(
//     rounded_box_shader,
//     self.shadow_dimensions_loc,
//     &shadow_dimensions,
//     rl.ShaderUniformDataType.VEC2,
// )




// init_gui_shaders :: proc () {
//     {
//         shader_data := #load("../shaders/rounded_box.frag")
//         rounded_box.shader = rl.LoadShaderFromMemory(nil, shader_data)
//         rounded_box.top_left_radius_loc = rl.GetShaderLocation(rounded_box.shader, "top_left_radius")
//         rounded_box.top_right_radius_loc = rl.GetShaderLocation(rounded_box.shader, "top_right_radius")
//         rounded_box.bottom_left_radius_loc = rl.GetShaderLocation(rounded_box.shader, "bottom_left_radius")
//         rounded_box.bottom_right_radius_loc = rl.GetShaderLocation(rounded_box.shader, "bottom_right_radius")

//     }
// }

// destroy_gui_shaders :: proc () {
//     rl.UnloadShader(rounded_box.shader)
// }



// gui_toggle :: proc (bounds: rl.Rectangle, options: []string, choice: int) -> int {

//     choice := choice
//     state : rl.GuiState

//     mouse_point := rl.GetMousePosition()

//     // split bounds into equal parts

//     if rl.CheckCollisionPointRec(mouse_point, bounds) {
//         if rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
//             state = rl.GuiState.STATE_PRESSED
//         } else {
//             state = rl.GuiState.STATE_FOCUSED
//         }

//         if (rl.IsMouseButtonReleased(rl.MouseButton.LEFT)) {
//             // choice
//         }
//     }

//     // rl.BeginShaderMode(rounded_box.shader)
//     // rl.DrawTextureV(self.texture, {rect.x, rect.y + 10}, rl.WHITE)
//     // rl.EndShaderMode(rounded_box.shader)


//     for opt in options {

//     }
//     // draw gui
//     // detect click -> set choice

//     return choice
// }



draw_note :: proc(
    note: core.Note,
    pos: [2]f32,
    color: rl.Color,
    hide_accidental: bool = false,
) {
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
