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

// What both backends share: drawing only records vertices and draw commands, the backend's end_frame
// uploads the vertices in one go and replays the commands. Every begin/end_render_target splits the frame
// into another render pass. SDL3 GPU in sdl.odin, WebGL2 in web.odin, each with its own TextureHandle, Gpu
// and Window.

import "core:math/linalg"
import "core:mem"

Texture :: struct {
    handle:        TextureHandle,
    width, height: i32,
}

RenderTarget :: struct {
    texture: Texture,
}

// What the draws between begin_shader and end_shader run, the sprite's otherwise
Shader :: Program

Program :: enum {
    SPRITE,
    STROBE,
    BLOOM,
    SHADOW,
}

// The textures each program's fragment shader samples, the strobe and the shadow draw theirs from uniforms
PROGRAM_SAMPLERS :: [Program]u32 {
    .SPRITE = 1,
    .STROBE = 0,
    .BLOOM  = 1,
    .SHADOW = 0,
}

Vertex :: struct {
    position: [2]f32,
    uv:       [2]f32,
    color:    Color,
}

UniformRange :: struct {
    offset, size: int,
}

DrawCommand :: struct {
    program:      Program,
    blend:        BlendMode,
    texture:      TextureHandle,
    uniforms:     UniformRange,
    scissor:      Maybe(Rect),
    first_vertex: u32,
    vertex_count: u32,
}

Pass :: struct {
    offscreen:     bool, // into a render target, not the window
    target:        TextureHandle, // the render target's, none for one that couldn't be made: its draws are dropped
    target_size:   [2]f32, // in pixels
    clear:         Maybe(Color), // a target's, or the draws cover all of it, the window clears to gpu.drawing.clear
    offset:        [2]f32,
    zoom:          f32,
    first_command: int,
}

// What the frame draws, filled by the draw calls and sent to the GPU by end_frame
GpuFrame :: struct {
    vertices:     [dynamic]Vertex,
    commands:     [dynamic]DrawCommand,
    passes:       [dynamic]Pass,
    uniform_data: [dynamic]u8,
}

// What the next draw call is drawn with
DrawingState :: struct {
    program:        Program,
    blend:          BlendMode,
    scissor:        Maybe(Rect),
    window_scissor: Maybe(Rect), // the window's while a render target is drawn, see begin_render_target
    uniforms:       [Program]UniformRange,
    clear:          Color,
}

// A scissor in a target's pixels, from its top left corner
PixelRect :: struct {
    x, y, width, height: i32,
}

Input :: struct {
    keys_pressed:  bit_set[Key],
    mouse_clicked: bool,
    touch:         bool, // the last press was a finger, see touch_input
    wheel:         f32,
}

Clock :: struct {
    last_counter: u64,
    frame_time:   f32,
    max_fps:      int, // see limit_fps
}

input: Input
clock: Clock


begin_frame :: proc(clear: Color) {
    clear_dynamic_array(&gpu.frame.vertices)
    clear_dynamic_array(&gpu.frame.commands)
    clear_dynamic_array(&gpu.frame.passes)
    clear_dynamic_array(&gpu.frame.uniform_data)
    gpu.drawing = {
        program = .SPRITE,
        blend   = .ALPHA,
        clear   = clear,
    }

    begin_window_pass()
}

// The frame's lists, once the GPU is done with them
delete_frame :: proc() {
    delete(gpu.frame.vertices)
    delete(gpu.frame.commands)
    delete(gpu.frame.passes)
    delete(gpu.frame.uniform_data)
}

// The draw commands recorded between this pass's start and the next one's
pass_commands :: proc(pass_index: int) -> []DrawCommand {
    last_command := len(gpu.frame.commands)
    if pass_index + 1 < len(gpu.frame.passes) do last_command = gpu.frame.passes[pass_index + 1].first_command

    return gpu.frame.commands[gpu.frame.passes[pass_index].first_command:last_command]
}

// A scissor in drawing coordinates as the target's pixels, none is all of it
scissor_pixels :: proc(scissor: Maybe(Rect), target_size, offset: [2]f32, zoom: f32) -> PixelRect {
    rect, ok := scissor.?
    if !ok do return {0, 0, i32(target_size.x), i32(target_size.y)}

    // From the target's top left corner, then from drawing points to its pixels, inside the target and never
    // inside out
    start := [2]f32{rect.x, rect.y}
    end := start + {rect.width, rect.height}
    top_left := linalg.clamp(linalg.round((start - offset) * zoom), 0, target_size)
    bottom_right := linalg.clamp(linalg.round((end - offset) * zoom), top_left, target_size)

    size := bottom_right - top_left
    return {i32(top_left.x), i32(top_left.y), i32(size.x), i32(size.y)}
}

// The last frame wasn't drawn, what was drawn into the render targets during it isn't there
last_frame_dropped :: proc() -> bool {
    return gpu.dropped
}

// 0 for the display's rate, the swapchain waits for vsync
limit_fps :: proc(fps: int) {
    clock.max_fps = fps
}

frame_time :: proc() -> f32 {
    return clock.frame_time
}

// In drawing points, see set_ui_scale
window_size :: proc() -> [2]f32 {
    return window_points() / window.ui_scale
}

// Everything is drawn and measured in points of this many of the window's own: 1 on a phone and in the
// desktop window, more on a tablet read from further away, where the same layout comes out larger. The
// window, its safe area and the pointer report in them, and dpi_scale grows by it so text rasterized for it
// stays sharp.
set_ui_scale :: proc(scale: f32) {
    window.ui_scale = scale
}

// The scale in effect, see set_ui_scale
ui_scale :: proc() -> f32 {
    return window.ui_scale
}

key_pressed :: proc(key: Key) -> bool {
    return key in input.keys_pressed
}

mouse_pressed :: proc() -> bool {
    return input.mouse_clicked
}

// Whether the last press was a finger rather than a mouse or a trackpad, a finger covers what it presses
touch_input :: proc() -> bool {
    return input.touch
}

mouse_wheel :: proc() -> f32 {
    return input.wheel
}

draw_texture :: proc(texture: Texture, source: Rect, dest: Rect, tint := WHITE) {
    source := source
    flip_x := source.width < 0
    flip_y := source.height < 0
    source.width = abs(source.width)
    source.height = abs(source.height)

    size := [2]f32{f32(texture.width), f32(texture.height)}
    uv0 := [2]f32{source.x, source.y} / size
    uv1 := [2]f32{source.x + source.width, source.y + source.height} / size
    if flip_x do uv0.x, uv1.x = uv1.x, uv0.x
    if flip_y do uv0.y, uv1.y = uv1.y, uv0.y

    push_quad(texture.handle, dest, uv0, uv1, tint)
}

begin_scissor :: proc(rect: Rect) {
    gpu.drawing.scissor = rect
}

end_scissor :: proc() {
    gpu.drawing.scissor = nil
}

set_blend_mode :: proc(mode: BlendMode) {
    gpu.drawing.blend = mode
}

begin_shader :: proc(shader: Shader) {
    gpu.drawing.program = shader
}

end_shader :: proc() {
    gpu.drawing.program = .SPRITE
}

// Takes effect for the following draws with this shader
set_shader_uniforms :: proc(shader: Shader, uniforms: ^$T) {
    offset := len(gpu.frame.uniform_data)
    append(&gpu.frame.uniform_data, ..mem.ptr_to_bytes(uniforms))
    gpu.drawing.uniforms[shader] = {offset, size_of(T)}
}

draw_shader_quad :: proc(rect: Rect) {
    push_quad(gpu.white.handle, rect, {0, 0}, {1, 1}, WHITE)
}

// The shader over rect a quarter turn anticlockwise: the shader's top edge runs up the left side of rect
// and its right edge along the top. rect is the quad as it lands on the screen, the shader sees its own
// frame upright, its size is rect's transposed.
draw_shader_quad_turned :: proc(rect: Rect) {
    x0, y0 := rect.x, rect.y
    x1, y1 := rect.x + rect.width, rect.y + rect.height
    push_vertices(
        gpu.white.handle,
        {
            {{x0, y0}, {1, 0}, WHITE},
            {{x1, y0}, {1, 1}, WHITE},
            {{x1, y1}, {0, 1}, WHITE},
            {{x0, y0}, {1, 0}, WHITE},
            {{x1, y1}, {0, 1}, WHITE},
            {{x0, y1}, {0, 0}, WHITE},
        },
    )
}

unload_render_target :: proc(target: RenderTarget) {
    unload_texture(target.texture)
}

render_target_size :: proc(target: RenderTarget) -> [2]f32 {
    return {f32(target.texture.width), f32(target.texture.height)}
}

// offset is the top left corner of the target in the drawing coordinates, zoom scales them to target pixels.
// No clear when the draws cover the whole target, its contents aren't loaded then. The window's scissor
// doesn't apply in the target, it's back after end_render_target.
begin_render_target :: proc(
    target: RenderTarget,
    clear: Maybe(Color),
    offset: [2]f32 = {},
    zoom: f32 = 1,
) {
    gpu.drawing.window_scissor = gpu.drawing.scissor
    gpu.drawing.scissor = nil
    append(
        &gpu.frame.passes,
        Pass {
            offscreen = true,
            target = target.texture.handle,
            target_size = render_target_size(target),
            clear = clear,
            offset = offset,
            zoom = zoom,
            first_command = len(gpu.frame.commands),
        },
    )
}

// Back to drawing into the window, over what's there already
end_render_target :: proc() {
    gpu.drawing.scissor = gpu.drawing.window_scissor
    gpu.drawing.window_scissor = nil
    begin_window_pass()
}

draw_render_target :: proc(target: RenderTarget, dest: Rect, tint := WHITE) {
    size := render_target_size(target)
    draw_texture(target.texture, {0, 0, size.x, size.y}, dest, tint)
}

begin_window_pass :: proc() {
    append(&gpu.frame.passes, Pass{zoom = 1, first_command = len(gpu.frame.commands)})
}

push_quad :: proc(texture: TextureHandle, dest: Rect, uv0, uv1: [2]f32, color: Color) {
    x0, y0 := dest.x, dest.y
    x1, y1 := dest.x + dest.width, dest.y + dest.height
    push_vertices(
        texture,
        {
            {{x0, y0}, {uv0.x, uv0.y}, color},
            {{x1, y0}, {uv1.x, uv0.y}, color},
            {{x1, y1}, {uv1.x, uv1.y}, color},
            {{x0, y0}, {uv0.x, uv0.y}, color},
            {{x1, y1}, {uv1.x, uv1.y}, color},
            {{x0, y1}, {uv0.x, uv1.y}, color},
        },
    )
}

// Appends to the last draw command if nothing changed since, otherwise starts a new one
push_vertices :: proc(texture: TextureHandle, vertices: []Vertex) {
    command := DrawCommand {
        program      = gpu.drawing.program,
        blend        = gpu.drawing.blend,
        texture      = texture,
        uniforms     = gpu.drawing.uniforms[gpu.drawing.program],
        scissor      = gpu.drawing.scissor,
        first_vertex = u32(len(gpu.frame.vertices)),
        vertex_count = u32(len(vertices)),
    }
    append(&gpu.frame.vertices, ..vertices)

    pass := gpu.frame.passes[len(gpu.frame.passes) - 1]
    if len(gpu.frame.commands) > pass.first_command {
        last := &gpu.frame.commands[len(gpu.frame.commands) - 1]
        if last.program == command.program &&
           last.blend == command.blend &&
           last.texture == command.texture &&
           last.uniforms == command.uniforms &&
           last.scissor == command.scissor {
            last.vertex_count += command.vertex_count
            return
        }
    }
    append(&gpu.frame.commands, command)
}
