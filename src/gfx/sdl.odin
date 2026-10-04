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


package gfx

// SDL3 GPU backend with Metal shaders, see gfx.odin
//
// Drawing only records vertices and draw commands, end_frame uploads the vertices in one go
// and replays the commands. Every begin/end_render_target splits the frame into another render pass.

import "core:fmt"
import "core:math"
import "core:mem"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

Texture :: struct {
    handle:        ^sdl.GPUTexture,
    width, height: i32,
}

RenderTarget :: struct {
    texture: Texture,
}

Shader :: ShaderKind

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

Program :: enum {
    SPRITE,
    STROBE,
    BLOOM,
    SHADOW,
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
    texture:      ^sdl.GPUTexture,
    uniforms:     UniformRange,
    scissor:      Maybe(Rect),
    first_vertex: u32,
    vertex_count: u32,
}

Pass :: struct {
    target:        ^sdl.GPUTexture, // nil for the window
    target_size:   [2]f32, // in pixels
    clear:         Maybe(Color), // a target's, or the draws cover all of it, the window clears to gpu.clear
    offset:        [2]f32,
    zoom:          f32,
    first_command: int,
}

// Render targets are always this format, the window may use another one
TARGET_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

PASS_WINDOW :: 0
PASS_TARGET :: 1

ShaderCode :: struct {
    code:       []u8,
    entrypoint: cstring,
}

// Metal on Apple, Vulkan elsewhere. The SPIR-V is compiled from src/shaders/vulkan into build/spirv by
// src/shaders/vulkan/compile.sh, Metal takes the source.
when ODIN_OS == .Darwin {
    SHADER_FORMAT :: sdl.GPUShaderFormat{.MSL}

    vertex_shader_code := ShaderCode{#load("../shaders/metal/sprite.metal"), "vertex_main"}
    fragment_shader_code := [Program]ShaderCode {
        .SPRITE = {#load("../shaders/metal/sprite.metal"), "sprite_fragment"},
        .STROBE = {#load("../shaders/metal/strobe.metal"), "strobe_fragment"},
        .BLOOM  = {#load("../shaders/metal/bloom.metal"), "bloom_fragment"},
        .SHADOW = {#load("../shaders/metal/shadow.metal"), "shadow_fragment"},
    }
} else {
    SHADER_FORMAT :: sdl.GPUShaderFormat{.SPIRV}

    vertex_shader_code := ShaderCode{#load("../../build/spirv/sprite.vert.spv"), "main"}
    fragment_shader_code := [Program]ShaderCode {
        .SPRITE = {#load("../../build/spirv/sprite.frag.spv"), "main"},
        .STROBE = {#load("../../build/spirv/strobe.frag.spv"), "main"},
        .BLOOM  = {#load("../../build/spirv/bloom.frag.spv"), "main"},
        .SHADOW = {#load("../../build/spirv/shadow.frag.spv"), "main"},
    }
}

scancodes := [Key]sdl.Scancode {
    .LEFT        = .LEFT,
    .RIGHT       = .RIGHT,
    .UP          = .UP,
    .DOWN        = .DOWN,
    .TAB         = .TAB,
    .SPACE       = .SPACE,
    .COMMA       = .COMMA,
    .ESCAPE      = .ESCAPE,
    .G           = .G,
    .I           = .I,
    .R           = .R,
    .X           = .X,
    .LEFT_SHIFT  = .LSHIFT,
    .RIGHT_SHIFT = .RSHIFT,
    .LEFT_SUPER  = .LGUI,
    .RIGHT_SUPER = .RGUI,
}

gpu: struct {
    window:           ^sdl.Window,
    device:           ^sdl.GPUDevice,
    window_format:    sdl.GPUTextureFormat,
    vertex_shader:    ^sdl.GPUShader,
    fragment_shaders: [Program]^sdl.GPUShader,
    pipelines:        [Program][BlendMode][2]^sdl.GPUGraphicsPipeline,
    sampler:          ^sdl.GPUSampler,
    white:            Texture,

    // grows as needed
    vertex_buffer:    ^sdl.GPUBuffer,
    transfer_buffer:  ^sdl.GPUTransferBuffer,
    vertex_capacity:  int,

    // this frame
    vertices:         [dynamic]Vertex,
    commands:         [dynamic]DrawCommand,
    passes:           [dynamic]Pass,
    uniform_data:     [dynamic]u8,

    // drawing state
    program:          Program,
    blend:            BlendMode,
    scissor:          Maybe(Rect),
    uniforms:         [Program]UniformRange,
    clear:            Color,
    acquire_failed:   bool, // the last frame's swapchain, reported once

    // input
    quit:             bool,
    background:       bool, // set by watch_app_events
    max_fps:          int, // see limit_fps
    keys_pressed:     bit_set[Key],
    mouse_clicked:    bool,
    touch:            bool, // the last press was a finger, see touch_input
    wheel:            f32,
    last_counter:     u64,
    frame_time:       f32,
}

init :: proc(width, height: i32, title: cstring) -> bool {
    if !sdl.Init({.VIDEO}) {
        fmt.eprintln("SDL_Init failed:", sdl.GetError())
        return false
    }

    // Without it SDL picks the orientation from the window's aspect ratio, landscape for the
    // desktop sizes, and keeps rotating the phone away from portrait
    when MOBILE do sdl.SetHint("SDL_ORIENTATIONS", "Portrait")

    // The back button closes a sheet first, the app passes it on when there's none, see system_back
    when ANDROID do sdl.SetHint(sdl.HINT_ANDROID_TRAP_BACK_BUTTON, "1")

    // The app may be suspended before the queued events are polled
    when MOBILE do _ = sdl.AddEventWatch(watch_app_events, nil)

    gpu.window = sdl.CreateWindow(title, width, height, {.HIGH_PIXEL_DENSITY})
    if gpu.window == nil {
        fmt.eprintln("SDL_CreateWindow failed:", sdl.GetError())
        return false
    }

    gpu.device = sdl.CreateGPUDevice(SHADER_FORMAT, ODIN_DEBUG, nil)
    if gpu.device == nil {
        fmt.eprintln("SDL_CreateGPUDevice failed:", sdl.GetError())
        return false
    }

    if !sdl.ClaimWindowForGPUDevice(gpu.device, gpu.window) {
        fmt.eprintln("SDL_ClaimWindowForGPUDevice failed:", sdl.GetError())
        return false
    }
    _ = sdl.SetGPUSwapchainParameters(gpu.device, gpu.window, .SDR, .VSYNC)
    gpu.window_format = sdl.GetGPUSwapchainTextureFormat(gpu.device, gpu.window)

    gpu.vertex_shader = create_shader(vertex_shader_code, .VERTEX, 0, 1)
    gpu.fragment_shaders = {
        .SPRITE = create_shader(fragment_shader_code[.SPRITE], .FRAGMENT, 1, 0),
        .STROBE = create_shader(fragment_shader_code[.STROBE], .FRAGMENT, 0, 1),
        .BLOOM  = create_shader(fragment_shader_code[.BLOOM], .FRAGMENT, 1, 1),
        .SHADOW = create_shader(fragment_shader_code[.SHADOW], .FRAGMENT, 0, 1),
    }
    for shader in gpu.fragment_shaders {
        if shader == nil do return false
    }
    if gpu.vertex_shader == nil do return false

    for program in Program {
        for blend in BlendMode {
            gpu.pipelines[program][blend][PASS_WINDOW] = create_pipeline(
                program,
                blend,
                gpu.window_format,
            )
            gpu.pipelines[program][blend][PASS_TARGET] = create_pipeline(
                program,
                blend,
                TARGET_FORMAT,
            )
        }
    }

    gpu.sampler = sdl.CreateGPUSampler(
        gpu.device,
        {
            min_filter = .LINEAR,
            mag_filter = .LINEAR,
            mipmap_mode = .NEAREST,
            address_mode_u = .CLAMP_TO_EDGE,
            address_mode_v = .CLAMP_TO_EDGE,
            address_mode_w = .CLAMP_TO_EDGE,
        },
    )

    white := [4]u8{255, 255, 255, 255}
    gpu.white = create_texture(1, 1, white[:])

    gpu.last_counter = sdl.GetPerformanceCounter()
    return true
}

shutdown :: proc() {
    _ = sdl.WaitForGPUIdle(gpu.device)

    unload_texture(gpu.white)
    sdl.ReleaseGPUSampler(gpu.device, gpu.sampler)
    for &by_blend in gpu.pipelines {
        for &by_pass in by_blend {
            for pipeline in by_pass do sdl.ReleaseGPUGraphicsPipeline(gpu.device, pipeline)
        }
    }
    for shader in gpu.fragment_shaders do sdl.ReleaseGPUShader(gpu.device, shader)

    sdl.ReleaseGPUShader(gpu.device, gpu.vertex_shader)
    if gpu.vertex_buffer != nil {
        sdl.ReleaseGPUBuffer(gpu.device, gpu.vertex_buffer)
        sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.transfer_buffer)
    }

    delete(gpu.vertices)
    delete(gpu.commands)
    delete(gpu.passes)
    delete(gpu.uniform_data)

    sdl.ReleaseWindowFromGPUDevice(gpu.device, gpu.window)
    sdl.DestroyGPUDevice(gpu.device)
    sdl.DestroyWindow(gpu.window)
    sdl.Quit()
}

should_close :: proc() -> bool {
    gpu.keys_pressed = {}
    gpu.mouse_clicked = false
    gpu.wheel = 0

    event: sdl.Event
    for sdl.PollEvent(&event) {
        #partial switch event.type {
        case .QUIT, .WINDOW_CLOSE_REQUESTED:
            gpu.quit = true
        case .KEY_DOWN:
            if event.key.repeat do break

            for scancode, key in scancodes {
                if scancode == event.key.scancode do gpu.keys_pressed += {key}
            }

            // Android's back button, see system_back
            if event.key.scancode == .AC_BACK do gpu.keys_pressed += {.ESCAPE}
        case .MOUSE_BUTTON_DOWN:
            if event.button.button == sdl.BUTTON_LEFT do gpu.mouse_clicked = true

            gpu.touch = event.button.which == sdl.TOUCH_MOUSEID
        case .MOUSE_WHEEL:
            // Undo natural scrolling, scrolling up always means up
            gpu.wheel += -event.wheel.y if event.wheel.direction == .FLIPPED else event.wheel.y
        }
    }

    counter := sdl.GetPerformanceCounter()
    gpu.frame_time = f32(f64(counter - gpu.last_counter) / f64(sdl.GetPerformanceFrequency()))
    gpu.last_counter = counter

    return gpu.quit
}

in_background :: proc() -> bool {
    return gpu.background
}

// Blocks until the app is back in front, or quit
wait_for_foreground :: proc() {
    event: sdl.Event
    for gpu.background && !gpu.quit {
        if sdl.WaitEvent(&event) && event.type == .QUIT do gpu.quit = true
    }

    // Not a frame that took as long as the app was away
    gpu.last_counter = sdl.GetPerformanceCounter()
}

open_url :: proc(url: cstring) {
    if !sdl.OpenURL(url) do fmt.eprintln("SDL_OpenURL failed:", sdl.GetError())
}

// SDL traps Android's back button and sends it as a key, see init. What the system does with it
// otherwise, leave the app.
system_back :: proc() {
    when ANDROID do sdl.SendAndroidBackButton()
}

watch_app_events :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
    // Not WILL_ENTER_BACKGROUND, it comes for anything that makes the app inactive, like the Control
    // Center or the microphone permission alert, and it may keep drawing then
    #partial switch event.type {
    case .DID_ENTER_BACKGROUND:
        gpu.background = true
    case .WILL_ENTER_FOREGROUND:
        gpu.background = false
    }
    return true
}

begin_frame :: proc(clear: Color) {
    clear_dynamic_array(&gpu.vertices)
    clear_dynamic_array(&gpu.commands)
    clear_dynamic_array(&gpu.passes)
    clear_dynamic_array(&gpu.uniform_data)
    gpu.program = .SPRITE
    gpu.blend = .ALPHA
    gpu.scissor = nil
    gpu.uniforms = {}
    gpu.clear = clear

    begin_window_pass()
}

end_frame :: proc() {
    pass_commands :: proc(pass_index: int) -> []DrawCommand {
        last_command := len(gpu.commands)
        if pass_index + 1 < len(gpu.passes) do last_command = gpu.passes[pass_index + 1].first_command

        return gpu.commands[gpu.passes[pass_index].first_command:last_command]
    }

    begin_render_pass :: proc(
        command_buffer: ^sdl.GPUCommandBuffer,
        color_target: ^sdl.GPUColorTargetInfo,
        target_size: [2]f32,
    ) -> ^sdl.GPURenderPass {
        render_pass := sdl.BeginGPURenderPass(command_buffer, color_target, 1, nil)
        sdl.SetGPUViewport(render_pass, {0, 0, target_size.x, target_size.y, 0, 1})
        binding := sdl.GPUBufferBinding{gpu.vertex_buffer, 0}
        if gpu.vertex_buffer != nil do sdl.BindGPUVertexBuffers(render_pass, 0, &binding, 1)

        return render_pass
    }

    // offset is the drawing position of the target's top left corner, zoom scales drawing coordinates to
    // its pixels
    draw_commands :: proc(
        command_buffer: ^sdl.GPUCommandBuffer,
        render_pass: ^sdl.GPURenderPass,
        commands: []DrawCommand,
        target_size: [2]f32,
        offset: [2]f32,
        zoom: f32,
        kind: int,
    ) {
        // xy scale drawing coordinates to clip space, zw is the drawing position of the top left corner
        view := [4]f32{2 * zoom / target_size.x, 2 * zoom / target_size.y, offset.x, offset.y}

        // Bound and pushed only when they change
        pipeline: ^sdl.GPUGraphicsPipeline
        uniforms: UniformRange
        for command in commands {
            if command.vertex_count == 0 do continue

            // A texture that failed to load
            if command.program != .STROBE && command.texture == nil do continue

            if next := gpu.pipelines[command.program][command.blend][kind]; next != pipeline {
                pipeline = next
                sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
                sdl.PushGPUVertexUniformData(command_buffer, 0, &view, size_of(view))
            }
            if command.uniforms.size > 0 && command.uniforms != uniforms {
                uniforms = command.uniforms
                sdl.PushGPUFragmentUniformData(
                    command_buffer,
                    0,
                    &gpu.uniform_data[uniforms.offset],
                    u32(uniforms.size),
                )
            }
            if command.program != .STROBE {
                texture_binding := sdl.GPUTextureSamplerBinding{command.texture, gpu.sampler}
                sdl.BindGPUFragmentSamplers(render_pass, 0, &texture_binding, 1)
            }

            scissor := sdl.Rect{0, 0, i32(target_size.x), i32(target_size.y)}
            if rect, ok := command.scissor.?; ok {
                x0 := clamp(math.round((rect.x - offset.x) * zoom), 0, target_size.x)
                y0 := clamp(math.round((rect.y - offset.y) * zoom), 0, target_size.y)
                x1 := clamp(math.round((rect.x + rect.width - offset.x) * zoom), x0, target_size.x)
                y1 := clamp(
                    math.round((rect.y + rect.height - offset.y) * zoom),
                    y0,
                    target_size.y,
                )
                scissor = {i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0)}
            }
            sdl.SetGPUScissor(render_pass, scissor)

            sdl.DrawGPUPrimitives(render_pass, command.vertex_count, 1, command.first_vertex, 0)
        }
    }

    command_buffer := sdl.AcquireGPUCommandBuffer(gpu.device)
    if command_buffer == nil {
        fmt.eprintln("SDL_AcquireGPUCommandBuffer failed:", sdl.GetError())
        return
    }

    swapchain: ^sdl.GPUTexture
    swapchain_w, swapchain_h: u32
    acquired := sdl.WaitAndAcquireGPUSwapchainTexture(
        command_buffer,
        gpu.window,
        &swapchain,
        &swapchain_w,
        &swapchain_h,
    )
    // Once, it can fail every frame while Android tears the surface down
    if !acquired && !gpu.acquire_failed {
        fmt.eprintln("SDL_WaitAndAcquireGPUSwapchainTexture failed:", sdl.GetError())
    }
    gpu.acquire_failed = !acquired

    // Minimized or hidden, nothing to draw into. Or no vertex buffer, nothing to draw with.
    if swapchain == nil || !upload_vertices(command_buffer) {
        _ = sdl.SubmitGPUCommandBuffer(command_buffer)
        sdl.Delay(16)
        return
    }

    // The render targets first, then the window in a single pass. Apple's and nearly every phone's GPU
    // draws in tiles, each pass loads its whole target into them and stores it back, a window pass
    // between each render target would move the full screen through memory every time. The window is
    // never sampled, and each target is finished before the window draws it, the order stays right.
    for pass, pass_index in gpu.passes {
        if pass.target == nil do continue

        commands := pass_commands(pass_index)
        if len(commands) == 0 && pass.clear == nil do continue

        color_target := sdl.GPUColorTargetInfo {
            texture  = pass.target,
            load_op  = .DONT_CARE, // the draws cover all of it
            store_op = .STORE,
        }
        if clear, ok := pass.clear.?; ok {
            normalized := normalize_color(clear)
            color_target.clear_color = {normalized.r, normalized.g, normalized.b, normalized.a}
            color_target.load_op = .CLEAR
        }
        render_pass := begin_render_pass(command_buffer, &color_target, pass.target_size)
        draw_commands(
            command_buffer,
            render_pass,
            commands,
            pass.target_size,
            pass.offset,
            pass.zoom,
            PASS_TARGET,
        )
        sdl.EndGPURenderPass(render_pass)
    }

    logical_w: i32
    sdl.GetWindowSize(gpu.window, &logical_w, nil)
    window_zoom := f32(swapchain_w) / f32(max(logical_w, 1))
    window_size := [2]f32{f32(swapchain_w), f32(swapchain_h)}

    clear := normalize_color(gpu.clear)
    color_target := sdl.GPUColorTargetInfo {
        texture     = swapchain,
        clear_color = {clear.r, clear.g, clear.b, clear.a},
        load_op     = .CLEAR,
        store_op    = .STORE,
    }
    render_pass := begin_render_pass(command_buffer, &color_target, window_size)
    for pass, pass_index in gpu.passes {
        if pass.target != nil do continue

        draw_commands(
            command_buffer,
            render_pass,
            pass_commands(pass_index),
            window_size,
            {},
            window_zoom,
            PASS_WINDOW,
        )
    }
    sdl.EndGPURenderPass(render_pass)

    _ = sdl.SubmitGPUCommandBuffer(command_buffer)

    // The rest of the frame at the limited rate, counted from the start of the frame in should_close.
    // A little short of it, the swapchain waits for the vsync that ends it, a sleep a touch too long
    // would miss that one and hold the frame on screen a refresh longer.
    VSYNC_MARGIN_S :: 0.002
    if gpu.max_fps > 0 {
        elapsed :=
            f64(sdl.GetPerformanceCounter() - gpu.last_counter) /
            f64(sdl.GetPerformanceFrequency())
        remaining := 1 / f64(gpu.max_fps) - elapsed - VSYNC_MARGIN_S
        if remaining > 0 do sdl.DelayPrecise(u64(remaining * 1e9))
    }
}

// 0 for the display's rate, the swapchain waits for vsync
limit_fps :: proc(fps: int) {
    gpu.max_fps = fps
}

frame_time :: proc() -> f32 {
    return gpu.frame_time
}

dpi_scale :: proc() -> f32 {
    return sdl.GetWindowPixelDensity(gpu.window)
}

window_size :: proc() -> [2]f32 {
    width, height: i32
    sdl.GetWindowSize(gpu.window, &width, &height)
    return {f32(width), f32(height)}
}

// Part of the window clear of the notch and the home indicator
safe_area :: proc() -> Rect {
    area: sdl.Rect
    if !sdl.GetWindowSafeArea(gpu.window, &area) {
        size := window_size()
        return {0, 0, size.x, size.y}
    }
    return {f32(area.x), f32(area.y), f32(area.w), f32(area.h)}
}

key_pressed :: proc(key: Key) -> bool {
    return key in gpu.keys_pressed
}

key_down :: proc(key: Key) -> bool {
    return sdl.GetKeyboardState(nil)[scancodes[key]]
}

mouse_position :: proc() -> [2]f32 {
    position: [2]f32
    _ = sdl.GetMouseState(&position.x, &position.y)
    return position
}

mouse_pressed :: proc() -> bool {
    return gpu.mouse_clicked
}

mouse_down :: proc() -> bool {
    return .LEFT in sdl.GetMouseState(nil, nil)
}

// Whether the last press was a finger rather than a mouse or a trackpad, a finger covers what it presses
touch_input :: proc() -> bool {
    return gpu.touch
}

mouse_wheel :: proc() -> f32 {
    return gpu.wheel
}

load_texture :: proc(png: []u8) -> Texture {
    width, height, channels: i32
    pixels := stbi.load_from_memory(raw_data(png), i32(len(png)), &width, &height, &channels, 4)
    if pixels == nil {
        fmt.eprintln("Could not load image:", stbi.failure_reason())
        return {}
    }
    defer stbi.image_free(pixels)
    return create_texture(width, height, pixels[:width * height * 4])
}

// Straight alpha RGBA, the sampler is linear already
load_texture_rgba :: proc(width, height: i32, pixels: []u8) -> Texture {
    return create_texture(width, height, pixels)
}

unload_texture :: proc(texture: Texture) {
    if texture.handle != nil do sdl.ReleaseGPUTexture(gpu.device, texture.handle)
}

// Bakes the glyphs into an atlas at size, drawn scaled from there
load_font :: proc(ttf: []u8, size: i32, codepoints: string) -> (font: Font) {
    info: stbtt.fontinfo
    if !stbtt.InitFont(&info, raw_data(ttf), 0) {
        fmt.eprintln("Could not load font")
        return
    }

    scale := stbtt.ScaleForPixelHeight(&info, f32(size))
    ascent, descent, line_gap: i32
    stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)

    PADDING :: 2 // keeps the neighbours out of the linear filtering
    atlas_width: i32 = 2048 if size > 64 else 512

    GlyphBox :: struct {
        codepoint: rune,
        x0, y0:    i32,
        width:     i32,
        height:    i32,
        atlas:     [2]i32,
    }
    boxes := make([dynamic]GlyphBox, context.temp_allocator)

    // Shelf packing, row by row
    pen: [2]i32 = PADDING
    row_height: i32 = 0
    for codepoint in codepoints {
        if codepoint in font.glyphs do continue

        box := GlyphBox {
            codepoint = codepoint,
        }
        x1, y1: i32
        stbtt.GetCodepointBitmapBox(&info, codepoint, scale, scale, &box.x0, &box.y0, &x1, &y1)
        box.width = x1 - box.x0
        box.height = y1 - box.y0

        if pen.x + box.width + PADDING > atlas_width {
            pen = {PADDING, pen.y + row_height + PADDING}
            row_height = 0
        }
        box.atlas = pen
        pen.x += box.width + PADDING
        row_height = max(row_height, box.height)
        append(&boxes, box)

        advance, left_side_bearing: i32
        stbtt.GetCodepointHMetrics(&info, codepoint, &advance, &left_side_bearing)
        font.glyphs[codepoint] = Glyph {
            source  = {f32(box.atlas.x), f32(box.atlas.y), f32(box.width), f32(box.height)},
            offset  = {f32(box.x0), f32(box.y0 + i32(f32(ascent) * scale))},
            advance = f32(i32(f32(advance) * scale)),
        }
    }
    atlas_height := pen.y + row_height + PADDING

    alpha := make([]u8, atlas_width * atlas_height, context.temp_allocator)
    for box in boxes {
        if box.width <= 0 || box.height <= 0 do continue

        stbtt.MakeCodepointBitmap(
            &info,
            &alpha[box.atlas.y * atlas_width + box.atlas.x],
            box.width,
            box.height,
            atlas_width,
            scale,
            scale,
            box.codepoint,
        )
    }

    pixels := make([]u8, len(alpha) * 4, context.temp_allocator)
    for coverage, i in alpha {
        pixels[i * 4 + 0] = 255
        pixels[i * 4 + 1] = 255
        pixels[i * 4 + 2] = 255
        pixels[i * 4 + 3] = coverage
    }

    font.texture = create_texture(atlas_width, atlas_height, pixels)
    font.base_size = f32(size)
    if len(boxes) > 0 do font.fallback = font.glyphs[boxes[0].codepoint]

    return
}

unload_font :: proc(font: Font) {
    unload_texture(font.texture)
    glyphs := font.glyphs
    delete(glyphs)
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

draw_rect :: proc(position: [2]f32, size: [2]f32, color: Color) {
    push_quad(gpu.white.handle, {position.x, position.y, size.x, size.y}, {0, 0}, {1, 1}, color)
}

draw_rect_lines :: proc(rect: Rect, thickness: f32, color: Color) {
    line := thickness
    draw_rect({rect.x, rect.y}, {rect.width, line}, color)
    draw_rect({rect.x, rect.y + rect.height - line}, {rect.width, line}, color)
    draw_rect({rect.x, rect.y + line}, {line, rect.height - 2 * line}, color)
    draw_rect({rect.x + rect.width - line, rect.y + line}, {line, rect.height - 2 * line}, color)
}

draw_line :: proc(start, end: [2]f32, thickness: f32, color: Color) {
    delta := end - start
    length := math.sqrt(delta.x * delta.x + delta.y * delta.y)
    if length == 0 do return

    normal := [2]f32{-delta.y, delta.x} * (0.5 * thickness / length)

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

begin_scissor :: proc(rect: Rect) {
    gpu.scissor = rect
}

end_scissor :: proc() {
    gpu.scissor = nil
}

set_blend_mode :: proc(mode: BlendMode) {
    gpu.blend = mode
}

load_shader :: proc(kind: ShaderKind) -> Shader {
    return kind
}

unload_shader :: proc(shader: Shader) {}

begin_shader :: proc(shader: Shader) {
    gpu.program = program_of(shader)
}

end_shader :: proc() {
    gpu.program = .SPRITE
}

// Takes effect for the following draws with this shader
set_shader_uniforms :: proc(shader: Shader, uniforms: ^$T) {
    offset := len(gpu.uniform_data)
    append(&gpu.uniform_data, ..mem.ptr_to_bytes(uniforms))
    gpu.uniforms[program_of(shader)] = {offset, size_of(T)}
}

draw_shader_quad :: proc(rect: Rect) {
    push_quad(gpu.white.handle, rect, {0, 0}, {1, 1}, WHITE)
}

load_render_target :: proc(width, height: i32) -> RenderTarget {
    handle := sdl.CreateGPUTexture(
        gpu.device,
        {
            type = .D2,
            format = TARGET_FORMAT,
            usage = {.SAMPLER, .COLOR_TARGET},
            width = u32(width),
            height = u32(height),
            layer_count_or_depth = 1,
            num_levels = 1,
        },
    )
    return {{handle, width, height}}
}

unload_render_target :: proc(target: RenderTarget) {
    unload_texture(target.texture)
}

render_target_size :: proc(target: RenderTarget) -> [2]f32 {
    return {f32(target.texture.width), f32(target.texture.height)}
}

// offset is the top left corner of the target in the drawing coordinates, zoom scales them to target pixels.
// No clear when the draws cover the whole target, its contents aren't loaded then.
begin_render_target :: proc(
    target: RenderTarget,
    clear: Maybe(Color),
    offset: [2]f32 = {},
    zoom: f32 = 1,
) {
    append(
        &gpu.passes,
        Pass {
            target = target.texture.handle,
            target_size = render_target_size(target),
            clear = clear,
            offset = offset,
            zoom = zoom,
            first_command = len(gpu.commands),
        },
    )
}

// Back to drawing into the window, over what's there already
end_render_target :: proc() {
    begin_window_pass()
}

draw_render_target :: proc(target: RenderTarget, dest: Rect, tint := WHITE) {
    size := render_target_size(target)
    draw_texture(target.texture, {0, 0, size.x, size.y}, dest, tint)
}


program_of :: proc(shader: Shader) -> Program {
    switch shader {
    case .STROBE:
        return .STROBE
    case .BLOOM:
        return .BLOOM
    case .SHADOW:
        return .SHADOW
    }
    return .SPRITE
}

begin_window_pass :: proc() {
    append(&gpu.passes, Pass{zoom = 1, first_command = len(gpu.commands)})
}

push_quad :: proc(texture: ^sdl.GPUTexture, dest: Rect, uv0, uv1: [2]f32, color: Color) {
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
push_vertices :: proc(texture: ^sdl.GPUTexture, vertices: []Vertex) {
    command := DrawCommand {
        program      = gpu.program,
        blend        = gpu.blend,
        texture      = texture,
        uniforms     = gpu.uniforms[gpu.program],
        scissor      = gpu.scissor,
        first_vertex = u32(len(gpu.vertices)),
        vertex_count = u32(len(vertices)),
    }
    append(&gpu.vertices, ..vertices)

    pass := gpu.passes[len(gpu.passes) - 1]
    if len(gpu.commands) > pass.first_command {
        last := &gpu.commands[len(gpu.commands) - 1]
        if last.program == command.program &&
           last.blend == command.blend &&
           last.texture == command.texture &&
           last.uniforms == command.uniforms &&
           last.scissor == command.scissor {
            last.vertex_count += command.vertex_count
            return
        }
    }
    append(&gpu.commands, command)
}

// False when the buffers couldn't be made, nothing can be drawn then
upload_vertices :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
    if len(gpu.vertices) == 0 do return true

    size := len(gpu.vertices) * size_of(Vertex)

    if size > gpu.vertex_capacity {
        if gpu.vertex_buffer != nil do sdl.ReleaseGPUBuffer(gpu.device, gpu.vertex_buffer)
        if gpu.transfer_buffer != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.transfer_buffer)

        gpu.vertex_capacity = max(size, 2 * gpu.vertex_capacity, 64 * 1024)
        gpu.vertex_buffer = sdl.CreateGPUBuffer(
            gpu.device,
            {usage = {.VERTEX}, size = u32(gpu.vertex_capacity)},
        )
        gpu.transfer_buffer = sdl.CreateGPUTransferBuffer(
            gpu.device,
            {usage = .UPLOAD, size = u32(gpu.vertex_capacity)},
        )
        if gpu.vertex_buffer == nil || gpu.transfer_buffer == nil {
            fmt.eprintln("Could not create the vertex buffers:", sdl.GetError())
            gpu.vertex_capacity = 0 // tried again next frame
            return false
        }
    }

    mapped := sdl.MapGPUTransferBuffer(gpu.device, gpu.transfer_buffer, true)
    if mapped == nil {
        fmt.eprintln("SDL_MapGPUTransferBuffer failed:", sdl.GetError())
        return false
    }
    mem.copy(mapped, raw_data(gpu.vertices), size)
    sdl.UnmapGPUTransferBuffer(gpu.device, gpu.transfer_buffer)

    copy_pass := sdl.BeginGPUCopyPass(command_buffer)
    sdl.UploadToGPUBuffer(
        copy_pass,
        {gpu.transfer_buffer, 0},
        {gpu.vertex_buffer, 0, u32(size)},
        true,
    )
    sdl.EndGPUCopyPass(copy_pass)
    return true
}

// An empty texture when it fails, the draws with it are skipped
create_texture :: proc(width, height: i32, pixels: []u8) -> Texture {
    handle := sdl.CreateGPUTexture(
        gpu.device,
        {
            type = .D2,
            format = .R8G8B8A8_UNORM,
            usage = {.SAMPLER},
            width = u32(width),
            height = u32(height),
            layer_count_or_depth = 1,
            num_levels = 1,
        },
    )

    if handle == nil {
        fmt.eprintln("SDL_CreateGPUTexture failed:", sdl.GetError())
        return {}
    }

    transfer := sdl.CreateGPUTransferBuffer(gpu.device, {usage = .UPLOAD, size = u32(len(pixels))})
    mapped := sdl.MapGPUTransferBuffer(gpu.device, transfer, false) if transfer != nil else nil
    if mapped == nil {
        fmt.eprintln("Could not upload the texture:", sdl.GetError())
        if transfer != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, transfer)

        sdl.ReleaseGPUTexture(gpu.device, handle)
        return {}
    }
    defer sdl.ReleaseGPUTransferBuffer(gpu.device, transfer)
    mem.copy(mapped, raw_data(pixels), len(pixels))
    sdl.UnmapGPUTransferBuffer(gpu.device, transfer)

    command_buffer := sdl.AcquireGPUCommandBuffer(gpu.device)
    copy_pass := sdl.BeginGPUCopyPass(command_buffer)
    sdl.UploadToGPUTexture(
        copy_pass,
        {transfer_buffer = transfer},
        {texture = handle, w = u32(width), h = u32(height), d = 1},
        false,
    )
    sdl.EndGPUCopyPass(copy_pass)
    _ = sdl.SubmitGPUCommandBuffer(command_buffer)

    return {handle, width, height}
}

create_shader :: proc(
    source: ShaderCode,
    stage: sdl.GPUShaderStage,
    num_samplers: u32,
    num_uniform_buffers: u32,
) -> ^sdl.GPUShader {
    shader := sdl.CreateGPUShader(
        gpu.device,
        {
            code_size = len(source.code),
            code = raw_data(source.code),
            entrypoint = source.entrypoint,
            format = SHADER_FORMAT,
            stage = stage,
            num_samplers = num_samplers,
            num_uniform_buffers = num_uniform_buffers,
        },
    )
    if shader == nil {
        fmt.eprintln("Could not compile shader", source.entrypoint, sdl.GetError())
    }
    return shader
}

create_pipeline :: proc(
    program: Program,
    blend: BlendMode,
    format: sdl.GPUTextureFormat,
) -> ^sdl.GPUGraphicsPipeline {
    blend_state: sdl.GPUColorTargetBlendState
    blend_state.enable_blend = true
    blend_state.color_blend_op = .ADD
    blend_state.alpha_blend_op = .ADD
    switch blend {
    case .ALPHA:
        blend_state.src_color_blendfactor = .SRC_ALPHA
        blend_state.dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA
        blend_state.src_alpha_blendfactor = .ONE
        blend_state.dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA
    case .REPLACE:
        // Written as it is, without reading the target
        blend_state.enable_blend = false
    case .ADD:
        blend_state.src_color_blendfactor = .ONE
        blend_state.dst_color_blendfactor = .ONE
        blend_state.src_alpha_blendfactor = .ONE
        blend_state.dst_alpha_blendfactor = .ONE
    }

    color_target := sdl.GPUColorTargetDescription {
        format      = format,
        blend_state = blend_state,
    }

    buffer_description := sdl.GPUVertexBufferDescription {
        slot       = 0,
        pitch      = size_of(Vertex),
        input_rate = .VERTEX,
    }
    attributes := [?]sdl.GPUVertexAttribute {
        {location = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, position))},
        {location = 1, format = .FLOAT2, offset = u32(offset_of(Vertex, uv))},
        {location = 2, format = .UBYTE4_NORM, offset = u32(offset_of(Vertex, color))},
    }

    pipeline := sdl.CreateGPUGraphicsPipeline(
        gpu.device,
        {
            vertex_shader = gpu.vertex_shader,
            fragment_shader = gpu.fragment_shaders[program],
            vertex_input_state = {
                vertex_buffer_descriptions = &buffer_description,
                num_vertex_buffers = 1,
                vertex_attributes = raw_data(attributes[:]),
                num_vertex_attributes = len(attributes),
            },
            primitive_type = .TRIANGLELIST,
            target_info = {color_target_descriptions = &color_target, num_color_targets = 1},
        },
    )
    if pipeline == nil {
        fmt.eprintln("Could not create pipeline", program, blend, sdl.GetError())
    }
    return pipeline
}
