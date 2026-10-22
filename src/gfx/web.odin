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


#+build js
package gfx

// WebGL2 backend in a browser's canvas, see platform/web. The draws are recorded in draw.odin, end_frame
// replays them. The fragment shaders are the Vulkan ones in src/shaders/vulkan, made GLSL ES 3.00 as
// they're compiled, see es_fragment_source. The browser asks for each frame, see platform/web/strobie.js.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import js "core:sys/wasm/js"
import gl "vendor:wasm/WebGL"

TextureHandle :: gl.Texture

// The canvas in platform/web/index.html
CANVAS_ID :: "strobie"

Gpu :: struct {
    programs:       [Program]gl.Program,
    transform:      [Program]i32, // the vertex shader's uniform locations, see VERTEX_SHADER
    flip_y:         [Program]i32,
    vertex_array:   gl.VertexArrayObject,
    vertex_buffer:  gl.Buffer,
    uniform_buffer: gl.Buffer,
    framebuffer:    gl.Framebuffer, // a render target's texture is attached to it as it's drawn
    white:          Texture,

    frame:          GpuFrame,
    drawing:        DrawingState,

    // the last frame
    dropped:        bool, // never on the web, WebGL draws or loses the context
}

Window :: struct {
    ui_scale:    f32, // the window's points per drawing point, see set_ui_scale
    points:      [2]f32, // the canvas in CSS pixels
    pixel_ratio: f32, // the canvas's pixels per CSS pixel
    pixels:      [2]i32, // its drawing buffer
}

// Key codes of KeyboardEvent.code
KEY_CODES :: [Key]string {
    .LEFT          = "ArrowLeft",
    .RIGHT         = "ArrowRight",
    .TAB           = "Tab",
    .SPACE         = "Space",
    .COMMA         = "Comma",
    .ESCAPE        = "Escape",
    .G             = "KeyG",
    .I             = "KeyI",
    .W             = "KeyW",
    .NUM_0         = "Digit0",
    .NUM_1         = "Digit1",
    .NUM_2         = "Digit2",
    .NUM_3         = "Digit3",
    .NUM_4         = "Digit4",
    .NUM_5         = "Digit5",
    .LEFT_SUPER    = "MetaLeft",
    .RIGHT_SUPER   = "MetaRight",
    .LEFT_CONTROL  = "ControlLeft",
    .RIGHT_CONTROL = "ControlRight",
}

// What the events between two frames leave, see on_pointer and on_key
Pointer :: struct {
    position: [2]f32, // in the canvas's CSS pixels
    down:     bool,
    keys:     bit_set[Key], // held
}

// The block each program's fragment shader takes its uniforms in, bound to UNIFORM_BINDING
UNIFORM_BLOCKS :: [Program]string {
    .SPRITE = "",
    .STROBE = "StrobeUniforms",
    .BLOOM  = "BloomUniforms",
    .SHADOW = "ShadowUniforms",
}

UNIFORM_BINDING :: 0

// sprite.vert for GLSL ES. A render target is drawn upside down, flip_y -1: GL's first row is the bottom
// one, the sampled texture's first row is then the drawing's top as it is in Metal and Vulkan.
VERTEX_SHADER :: `#version 300 es
layout(location = 0) in vec2 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;

out vec2 frag_uv;
out vec4 frag_color;

uniform vec4 transform;
uniform float flip_y;

void main()
{
    vec2 clip = (position - transform.zw) * transform.xy;

    gl_Position = vec4(clip.x - 1.0, (1.0 - clip.y) * flip_y, 0.0, 1.0);
    frag_uv = uv;
    frag_color = color;
}
`

fragment_shader_code := [Program]string {
    .SPRITE = #load("../shaders/vulkan/sprite.frag", string),
    .STROBE = #load("../shaders/vulkan/strobe.frag", string),
    .BLOOM  = #load("../shaders/vulkan/bloom.frag", string),
    .SHADOW = #load("../shaders/vulkan/shadow.frag", string),
}

gpu:     Gpu
window:  Window
pointer: Pointer

// The canvas fills the page, the sizes and the place are the desktop window's and don't apply
init :: proc(width, height: i32, title: cstring, min_size: [2]i32 = {}, position: Maybe([2]i32) = nil) -> bool {
    window.ui_scale = 1
    js.set_document_title(string(title))

    if !gl.CreateCurrentContextById(CANVAS_ID, {.disableAlpha, .disableAntialias, .disableDepth}) {
        fmt.eprintln("No WebGL context on the canvas")
        return false
    }
    major, minor: i32
    gl.GetWebGLVersion(&major, &minor)
    if major < 2 {
        fmt.eprintln("WebGL2 isn't supported")
        return false
    }
    follow_canvas_size()

    if !init_gpu() do return false

    listen_to_events()
    clock.last_counter = u64(time.tick_now()._nsec)
    return true
}

// The programs, the buffers, the framebuffer for the render targets and the white texture
init_gpu :: proc() -> bool {
    if !create_programs() do return false

    gpu.vertex_buffer = gl.CreateBuffer()
    gpu.uniform_buffer = gl.CreateBuffer()
    gpu.framebuffer = gl.CreateFramebuffer()
    gl.BindBufferBase(gl.UNIFORM_BUFFER, UNIFORM_BINDING, gpu.uniform_buffer)

    // The vertices as the vertex shader's inputs, see Vertex
    gpu.vertex_array = gl.CreateVertexArray()
    gl.BindVertexArray(gpu.vertex_array)
    gl.BindBuffer(gl.ARRAY_BUFFER, gpu.vertex_buffer)
    gl.EnableVertexAttribArray(0)
    gl.EnableVertexAttribArray(1)
    gl.EnableVertexAttribArray(2)
    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, position))
    gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, uv))
    gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, size_of(Vertex), offset_of(Vertex, color))

    gl.Enable(gl.SCISSOR_TEST)

    // What the solid shapes sample, the sprite shader always takes a texture and their color tints it
    white := [4]u8{255, 255, 255, 255}
    gpu.white = create_texture(1, 1, white[:])
    return true
}

// Each program's fragment shader with the vertex shader they all share. Errors are printed.
create_programs :: proc() -> bool {
    block_names := UNIFORM_BLOCKS
    for program in Program {
        source := es_fragment_source(fragment_shader_code[program])
        defer delete(source)

        handle, ok := gl.CreateProgramFromStrings({VERTEX_SHADER}, {source})
        if !ok {
            fmt.eprintln("Could not create the program", program)
            return false
        }
        gpu.programs[program] = handle

        gl.UseProgram(handle)
        gpu.transform[program] = gl.GetUniformLocation(handle, "transform")
        gpu.flip_y[program] = gl.GetUniformLocation(handle, "flip_y")
        gl.Uniform1i(gl.GetUniformLocation(handle, "texture0"), 0)
        if block_names[program] != "" {
            gl.UniformBlockBinding(handle, gl.GetUniformBlockIndex(handle, block_names[program]), UNIFORM_BINDING)
        }
    }
    return true
}

// A Vulkan fragment shader as GLSL ES 3.00: from its #version on, ES wants it on the first line, no
// descriptor sets, the uniform block laid out as std140 like the Vulkan one, see StrobeUniforms in gfx.odin,
// and no locations on the inputs
es_fragment_source :: proc(vulkan: string) -> string {
    REPLACEMENTS :: [?][2]string {
        {"#version 450", "#version 300 es\nprecision highp float;\nprecision highp int;"},
        {"layout(location = 0) in ", "in "},
        {"layout(location = 1) in ", "in "},
        {"layout(set = 2, binding = 0) uniform sampler2D", "uniform sampler2D"},
        {"layout(set = 3, binding = 0) uniform", "layout(std140) uniform"},
    }

    source := strings.clone(vulkan[max(strings.index(vulkan, "#version"), 0):])
    for replacement in REPLACEMENTS {
        replaced, allocated := strings.replace_all(source, replacement[0], replacement[1])
        if allocated {
            delete(source)
            source = replaced
        }
    }
    return source
}

// The page's events into input and pointer, kept until the frame that takes them, see clear_frame_input
listen_to_events :: proc() {
    js.add_event_listener(CANVAS_ID, .Pointer_Down, nil, on_pointer)
    js.add_window_event_listener(.Pointer_Up, nil, on_pointer)
    js.add_window_event_listener(.Pointer_Move, nil, on_pointer)
    js.add_window_event_listener(.Pointer_Cancel, nil, on_pointer)
    js.add_event_listener(CANVAS_ID, .Wheel, nil, on_wheel)
    js.add_window_event_listener(.Key_Down, nil, on_key)
    js.add_window_event_listener(.Key_Up, nil, on_key)

    // A key held as the page lost the focus never comes up
    js.add_window_event_listener(.Blur, nil, proc(event: js.Event) {
        pointer.keys = {}
        pointer.down = false
    })
}

on_pointer :: proc(event: js.Event) {
    canvas := js.get_bounding_client_rect(CANVAS_ID)
    client := event.mouse.client
    pointer.position = {f32(f64(client.x) - canvas.x), f32(f64(client.y) - canvas.y)}

    #partial switch event.kind {
    case .Pointer_Down:
        if event.mouse.button != 0 do return

        pointer.down = true
        input.mouse_clicked = true
        input.touch = event.mouse.pointer.pointer_type == .Touch
    case .Pointer_Up, .Pointer_Cancel:
        pointer.down = false
    }
}

on_wheel :: proc(event: js.Event) {
    // The page doesn't scroll under the canvas
    js.event_prevent_default()

    // Pixels like a trackpad's, a mouse's notch is around 100 of them and a line about 3. Up is up.
    WHEEL_PIXELS_PER_STEP :: 100
    delta := f32(event.wheel.delta.y)
    if event.wheel.delta_mode == .Line do delta *= WHEEL_PIXELS_PER_STEP / 3

    input.wheel -= delta / WHEEL_PIXELS_PER_STEP
}

on_key :: proc(event: js.Event) {
    codes := KEY_CODES
    for code, key in codes {
        if code != event.key.code do continue

        // Tab would move the focus off the canvas, Space would scroll
        if key == .TAB || key == .SPACE do js.event_prevent_default()

        if event.kind == .Key_Up {
            pointer.keys -= {key}
        } else if !event.key.repeat {
            pointer.keys += {key}
            input.keys_pressed += {key}
        }
    }
}

// The canvas's size as the page laid it out, its drawing buffer in the display's pixels
follow_canvas_size :: proc() {
    rect := js.get_bounding_client_rect(CANVAS_ID)
    window.points = {f32(rect.width), f32(rect.height)}
    window.pixel_ratio = f32(js.device_pixel_ratio())

    pixels := [2]i32{i32(math.round(rect.width * f64(window.pixel_ratio))), i32(math.round(rect.height * f64(window.pixel_ratio)))}
    if pixels == window.pixels do return

    window.pixels = pixels
    js.set_element_key_f64(CANVAS_ID, "width", f64(pixels.x))
    js.set_element_key_f64(CANVAS_ID, "height", f64(pixels.y))
}

shutdown :: proc() {
    unload_texture(gpu.white)
    for program in gpu.programs do gl.DeleteProgram(program)

    gl.DeleteBuffer(gpu.vertex_buffer)
    gl.DeleteBuffer(gpu.uniform_buffer)
    gl.DeleteFramebuffer(gpu.framebuffer)
    gl.DeleteVertexArray(gpu.vertex_array)
    delete_frame()
}

// Whether a frame is due at the limited rate, the browser asks at the display's. Counted from the last
// frame's start, a little early: the browser's next ask would come a whole refresh later.
frame_due :: proc() -> bool {
    REFRESH_MARGIN_S :: 0.004
    if clock.max_fps == 0 do return true

    elapsed := f64(u64(time.tick_now()._nsec) - clock.last_counter) / 1e9
    return elapsed >= 1 / f64(clock.max_fps) - REFRESH_MARGIN_S
}

// The frame's start, frame_time is since the previous one's. The canvas may have changed size.
begin_web_frame :: proc() {
    tick_clock()
    follow_canvas_size()
}

// The presses and the wheel the frame took
clear_frame_input :: proc() {
    input.keys_pressed = {}
    input.mouse_clicked = false
    input.wheel = 0
}

tick_clock :: proc() {
    counter := u64(time.tick_now()._nsec)
    clock.frame_time = f32(f64(counter - clock.last_counter) / 1e9)
    clock.last_counter = counter
}

// The main loop is the browser's, it stops asking for frames while the page is hidden
should_close :: proc() -> bool {
    return false
}

in_background :: proc() -> bool {
    return false
}

wait_for_foreground :: proc() {}

window_hidden :: proc() -> bool {
    return false
}

wait_while_hidden :: proc() {}

system_back :: proc() {}

live_resize_frames :: proc(frame: proc(data: rawptr), data: rawptr) {}

resizing :: proc() -> bool {
    return false
}

// Uploads the frame's vertices, draws the render targets, then the canvas
end_frame :: proc() {
    upload_vertices()
    draw_render_targets()
    draw_window()
}

upload_vertices :: proc() {
    if len(gpu.frame.vertices) == 0 do return

    gl.BindBuffer(gl.ARRAY_BUFFER, gpu.vertex_buffer)
    gl.BufferData(gl.ARRAY_BUFFER, len(gpu.frame.vertices) * size_of(Vertex), raw_data(gpu.frame.vertices), gl.STREAM_DRAW)
}

// Each render target with its own clear, before the canvas draws them
draw_render_targets :: proc() {
    gl.BindFramebuffer(gl.FRAMEBUFFER, gpu.framebuffer)
    for pass, pass_index in gpu.frame.passes {
        if !pass.offscreen || pass.target == {} do continue

        commands := pass_commands(pass_index)
        if len(commands) == 0 && pass.clear == nil do continue

        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, pass.target, 0)
        gl.Viewport(0, 0, i32(pass.target_size.x), i32(pass.target_size.y))
        if clear, ok := pass.clear.?; ok do clear_target(clear, pass.target_size)

        replay_commands(commands, pass.target_size, pass.offset, pass.zoom, flipped = true)
    }

    // Not left attached, a texture drawn into the canvas next would be both
    gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, 0, 0)
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// Every window pass into the canvas
draw_window :: proc() {
    size := [2]f32{f32(window.pixels.x), f32(window.pixels.y)}
    zoom := window.pixel_ratio * window.ui_scale

    gl.Viewport(0, 0, window.pixels.x, window.pixels.y)
    clear_target(gpu.drawing.clear, size)
    for pass, pass_index in gpu.frame.passes {
        if pass.offscreen do continue

        replay_commands(pass_commands(pass_index), size, {}, zoom, flipped = false)
    }
}

clear_target :: proc(color: Color, size: [2]f32) {
    normalized := normalize_color(color)
    gl.Scissor(0, 0, i32(size.x), i32(size.y))
    gl.ClearColor(normalized.r, normalized.g, normalized.b, normalized.a)
    gl.Clear(u32(gl.COLOR_BUFFER_BIT))
}

// Issues the draws for commands recorded during the frame: each one's program, blend, uniforms, texture and
// scissor, then its vertices. offset is the drawing position of the target's top left corner, zoom scales
// drawing coordinates to its pixels. A render target is drawn flipped, see VERTEX_SHADER.
replay_commands :: proc(commands: []DrawCommand, target_size: [2]f32, offset: [2]f32, zoom: f32, flipped: bool) {
    // xy scale drawing coordinates to clip space, zw is the drawing position of the top left corner
    view := [4]f32{2 * zoom / target_size.x, 2 * zoom / target_size.y, offset.x, offset.y}
    flip_y: f32 = -1 if flipped else 1

    gl.BindVertexArray(gpu.vertex_array)
    gl.ActiveTexture(gl.TEXTURE0)

    // Set only when they change
    program := Program(-1)
    blend := BlendMode(-1)
    uniforms: UniformRange
    samplers := PROGRAM_SAMPLERS
    for command in commands {
        if command.vertex_count == 0 do continue

        // A texture that failed to load
        sampled := samplers[command.program] > 0
        if sampled && command.texture == {} do continue

        if command.program != program {
            program = command.program
            gl.UseProgram(gpu.programs[program])
            gl.Uniform4f(gpu.transform[program], view.x, view.y, view.z, view.w)
            gl.Uniform1f(gpu.flip_y[program], flip_y)
        }
        if command.blend != blend {
            blend = command.blend
            set_blend(blend)
        }
        if command.uniforms.size > 0 && command.uniforms != uniforms {
            uniforms = command.uniforms
            gl.BindBuffer(gl.UNIFORM_BUFFER, gpu.uniform_buffer)
            gl.BufferData(gl.UNIFORM_BUFFER, uniforms.size, &gpu.frame.uniform_data[uniforms.offset], gl.DYNAMIC_DRAW)
        }
        if sampled do gl.BindTexture(gl.TEXTURE_2D, command.texture)

        // GL's scissor counts rows from the bottom, a flipped target's first row is the drawing's top
        scissor := scissor_pixels(command.scissor, target_size, offset, zoom)
        if !flipped do scissor.y = i32(target_size.y) - scissor.y - scissor.height

        gl.Scissor(scissor.x, scissor.y, scissor.width, scissor.height)
        gl.DrawArrays(gl.TRIANGLES, int(command.first_vertex), int(command.vertex_count))
    }
}

set_blend :: proc(blend: BlendMode) {
    switch blend {
    case .ALPHA:
        gl.Enable(gl.BLEND)
        gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    case .REPLACE:
        // Written as it is, without reading the target
        gl.Disable(gl.BLEND)
    case .ADD:
        gl.Enable(gl.BLEND)
        gl.BlendFunc(gl.ONE, gl.ONE)
    }
}

// Pixels per drawing point, the display's density times the UI scale. Text rasterized at it lands texel for
// pixel.
dpi_scale :: proc() -> f32 {
    return window.pixel_ratio * window.ui_scale
}

// The canvas, in CSS pixels
window_points :: proc() -> [2]f32 {
    return window.points
}

// CSS pixels are the points a phone or a tablet is sized in
content_scale :: proc() -> f32 {
    return 1
}

window_position :: proc() -> [2]i32 {
    return {}
}

set_window_size :: proc(width, height: i32) {}

// All of the canvas, the page keeps it clear of the notch, see platform/web/index.html
safe_area :: proc() -> Rect {
    size := window_size()
    return {0, 0, size.x, size.y}
}

key_down :: proc(key: Key) -> bool {
    return key in pointer.keys
}

mouse_position :: proc() -> [2]f32 {
    return pointer.position / window.ui_scale
}

mouse_down :: proc() -> bool {
    return pointer.down
}

has_haptics :: proc() -> bool {
    return false
}

haptic_tap :: proc() {}

// At once, not after the frame: WebGL keeps it until the draws already issued are done
unload_texture :: proc(texture: Texture) {
    if texture.handle != {} do gl.DeleteTexture(texture.handle)
}

load_render_target :: proc(width, height: i32) -> RenderTarget {
    handle := create_gl_texture()
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, 0, nil)
    return {{handle, width, height}}
}

// Straight alpha RGBA
create_texture :: proc(width, height: i32, pixels: []u8) -> Texture {
    handle := create_gl_texture()
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, len(pixels), raw_data(pixels))
    return {handle, width, height}
}

// Bound, sampled linearly and clamped at the edges like the SDL backend's one sampler
create_gl_texture :: proc() -> gl.Texture {
    handle := gl.CreateTexture()
    gl.BindTexture(gl.TEXTURE_2D, handle)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.LINEAR))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.LINEAR))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
    return handle
}
