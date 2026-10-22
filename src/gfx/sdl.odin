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


#+build !js
package gfx

// SDL3 GPU backend, Metal shaders on macOS and iOS and Vulkan SPIR-V elsewhere, see gfx.odin. The draws are
// recorded in draw.odin, end_frame replays them.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

TextureHandle :: ^sdl.GPUTexture

// Render targets are always this format, the window may use another one
TARGET_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

// Which of a program's pipelines a pass draws with, they differ in the format they draw into
PassKind :: enum {
    WINDOW,
    TARGET,
}

ShaderCode :: struct {
    code:       []u8,
    entrypoint: cstring,
}

Gpu :: struct {
    device:           ^sdl.GPUDevice,
    window_format:    sdl.GPUTextureFormat,
    vertex_shader:    ^sdl.GPUShader,
    fragment_shaders: [Program]^sdl.GPUShader,
    pipelines:        [Program][BlendMode][PassKind]^sdl.GPUGraphicsPipeline,
    sampler:          ^sdl.GPUSampler,
    white:            Texture,

    // grows as needed
    vertex_buffer:    ^sdl.GPUBuffer,
    transfer_buffer:  ^sdl.GPUTransferBuffer,
    vertex_capacity:  int,

    frame:            GpuFrame,
    drawing:          DrawingState,

    // the last frame
    acquire_failed:   bool, // its swapchain, reported once
    dropped:          bool, // it wasn't drawn, the render targets hold what they had before it
}

Window :: struct {
    handle:     ^sdl.Window,
    ui_scale:   f32, // the window's points per drawing point, see set_ui_scale
    quit:       bool,
    background: bool, // set by watch_app_events, on whichever thread SDL pushes the event from
}

// The desktop window dragged to another size or a menu open, see live_resize_frames
LiveResize :: struct {
    frame:         proc(data: rawptr),
    data:          rawptr,
    frame_context: runtime.Context,
    resizing:      bool, // in a frame drawn from the OS's own loop
    polling:       bool, // in should_close, where the main loop is stuck while the OS runs a drag, a zoom or a menu
    drag_tick:     u64, // the last tick of the drag's timer, in milliseconds
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
    .TAB         = .TAB,
    .SPACE       = .SPACE,
    .COMMA       = .COMMA,
    .ESCAPE      = .ESCAPE,
    .G           = .G,
    .I           = .I,
    .W           = .W,
    .NUM_0       = ._0,
    .NUM_1       = ._1,
    .NUM_2       = ._2,
    .NUM_3       = ._3,
    .NUM_4       = ._4,
    .NUM_5       = ._5,
    .LEFT_SUPER  = .LGUI,
    .RIGHT_SUPER = .RGUI,
    .LEFT_CONTROL = .LCTRL,
    .RIGHT_CONTROL = .RCTRL,
}

gpu:         Gpu
window:      Window
live_resize: LiveResize

// On the desktop the window can be resized down to min_size, none keeps it the size it opened at, and opens
// with its top left corner at position, none or off every display in the middle of the main one. A phone's
// is the screen.
init :: proc(width, height: i32, title: cstring, min_size: [2]i32 = {}, position: Maybe([2]i32) = nil) -> bool {
    if !sdl.Init({.VIDEO}) {
        fmt.eprintln("SDL_Init failed:", sdl.GetError())
        return false
    }
    window.ui_scale = 1

    // Without it SDL picks the orientation from the window's aspect ratio, landscape for the
    // desktop sizes, and keeps rotating the phone away from portrait. On iOS it asks for all four and
    // keeps the ones Info.plist lists for the device: a phone's portrait, an iPad's every way.
    when IOS do sdl.SetHint("SDL_ORIENTATIONS", "Portrait PortraitUpsideDown LandscapeLeft LandscapeRight")
    when ANDROID do sdl.SetHint("SDL_ORIENTATIONS", "Portrait")

    // The back button closes a sheet first, the app passes it on when there's none, see system_back
    when ANDROID do sdl.SetHint(sdl.HINT_ANDROID_TRAP_BACK_BUTTON, "1")

    // The app may be suspended before the queued events are polled
    when MOBILE do _ = sdl.AddEventWatch(watch_app_events, nil)

    // The window keeps drawing while it's dragged to another size, see live_resize_frames. Elsewhere the
    // main loop goes on during a drag.
    when ODIN_OS == .Darwin && !MOBILE do _ = sdl.AddEventWatch(watch_live_resize, nil)

    // A size remembered from a bigger display is cut down to the one it opens on
    size := [2]i32{width, height}
    corner, placed := position.?
    when MOBILE do _, _ = corner, placed // a phone's window is the screen

    when !MOBILE {
        // Placed only where its title bar shows, the display it was on may be gone
        display := sdl.GetPrimaryDisplay()
        if placed {
            title_bar_display, shows := display_showing_title_bar(corner, size.x)
            if shows do display = title_bar_display

            placed = shows
        }
        size = fit_to_display(size, display)
    }

    // Hidden until it's where it goes
    window.handle = sdl.CreateWindow(title, size.x, size.y, {.HIGH_PIXEL_DENSITY, .HIDDEN})
    if window.handle == nil {
        fmt.eprintln("SDL_CreateWindow failed:", sdl.GetError())
        return false
    }
    when !MOBILE {
        if placed do sdl.SetWindowPosition(window.handle, corner.x, corner.y)
    }
    sdl.ShowWindow(window.handle)

    when !MOBILE {
        if min_size.x > 0 || min_size.y > 0 {
            sdl.SetWindowResizable(window.handle, true)
            sdl.SetWindowMinimumSize(window.handle, min_size.x, min_size.y)
        }
    }

    if !init_gpu() do return false

    clock.last_counter = sdl.GetPerformanceCounter()
    return true
}

// The GPU device drawing into the window, the shaders and pipelines of every program, the sampler and the
// white texture. Errors are printed.
init_gpu :: proc() -> bool {
    gpu.device = sdl.CreateGPUDevice(SHADER_FORMAT, ODIN_DEBUG, nil)
    if gpu.device == nil {
        fmt.eprintln("SDL_CreateGPUDevice failed:", sdl.GetError())
        return false
    }

    if !sdl.ClaimWindowForGPUDevice(gpu.device, window.handle) {
        fmt.eprintln("SDL_ClaimWindowForGPUDevice failed:", sdl.GetError())
        return false
    }
    _ = sdl.SetGPUSwapchainParameters(gpu.device, window.handle, .SDR, .VSYNC)
    gpu.window_format = sdl.GetGPUSwapchainTextureFormat(gpu.device, window.handle)

    if !create_shaders() || !create_pipelines() || !create_sampler() do return false

    // What the solid shapes sample, the sprite shader always takes a texture and their color tints it
    white := [4]u8{255, 255, 255, 255}
    gpu.white = create_texture(1, 1, white[:])
    return true
}

// The one sampler every texture is drawn with: linear, clamped at the edges
create_sampler :: proc() -> bool {
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
    if gpu.sampler == nil {
        fmt.eprintln("SDL_CreateGPUSampler failed:", sdl.GetError())
        return false
    }
    return true
}

// The vertex shader all programs share and each program's fragment shader
create_shaders :: proc() -> bool {
    gpu.vertex_shader = create_shader(vertex_shader_code, .VERTEX, 0, 1)
    if gpu.vertex_shader == nil do return false

    // Every program but the sprite takes its uniforms
    samplers := PROGRAM_SAMPLERS
    for program in Program {
        uniform_buffers: u32 = 0 if program == .SPRITE else 1
        shader := create_shader(fragment_shader_code[program], .FRAGMENT, samplers[program], uniform_buffers)
        if shader == nil do return false

        gpu.fragment_shaders[program] = shader
    }
    return true
}

// A pipeline per program, blend mode and pass kind. Like a shader, one that couldn't be made would leave its
// draws to whatever was bound before.
create_pipelines :: proc() -> bool {
    for program in Program {
        for blend in BlendMode {
            window := create_pipeline(program, blend, gpu.window_format)
            target := create_pipeline(program, blend, TARGET_FORMAT)
            if window == nil || target == nil do return false

            gpu.pipelines[program][blend][.WINDOW] = window
            gpu.pipelines[program][blend][.TARGET] = target
        }
    }
    return true
}

// The display whose usable area a window's title bar overlaps, with the window's top left corner at corner.
// False on none, the window would open where it can't be grabbed.
display_showing_title_bar :: proc(corner: [2]i32, width: i32) -> (display: sdl.DisplayID, shows: bool) {
    TITLE_BAR_HEIGHT :: 28
    title_bar := sdl.Rect{corner.x, corner.y, width, TITLE_BAR_HEIGHT}

    count: i32
    displays := sdl.GetDisplays(&count)
    defer sdl.free(displays)

    for index in 0 ..< count {
        bounds: sdl.Rect
        if !sdl.GetDisplayUsableBounds(displays[index], &bounds) do continue

        if sdl.HasRectIntersection(title_bar, bounds) do return displays[index], true
    }
    return
}

// A size cut down to the display's usable area, one remembered from a bigger display may not fit
fit_to_display :: proc(size: [2]i32, display: sdl.DisplayID) -> [2]i32 {
    bounds: sdl.Rect
    if !sdl.GetDisplayUsableBounds(display, &bounds) do return size

    return {min(size.x, bounds.w), min(size.y, bounds.h)}
}

shutdown :: proc() {
    destroy_gpu()

    sdl.DestroyWindow(window.handle)
    sdl.Quit()
}

// What init_gpu made in reverse, and the buffers and lists the frames made, once the GPU is done with them
destroy_gpu :: proc() {
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

    delete_frame()

    sdl.ReleaseWindowFromGPUDevice(gpu.device, window.handle)
    sdl.DestroyGPUDevice(gpu.device)
}

should_close :: proc() -> bool {
    input.keys_pressed = {}
    input.mouse_clicked = false
    input.wheel = 0

    event: sdl.Event
    live_resize.polling = true
    for sdl.PollEvent(&event) {
        #partial switch event.type {
        case .QUIT, .WINDOW_CLOSE_REQUESTED:
            window.quit = true
        case .KEY_DOWN:
            if event.key.repeat do break

            for scancode, key in scancodes {
                if scancode == event.key.scancode do input.keys_pressed += {key}
            }

            // Android's back button, see system_back
            if event.key.scancode == .AC_BACK do input.keys_pressed += {.ESCAPE}
        case .MOUSE_BUTTON_DOWN:
            if event.button.button == sdl.BUTTON_LEFT do input.mouse_clicked = true

            input.touch = event.button.which == sdl.TOUCH_MOUSEID
        case .MOUSE_WHEEL:
            // Undo natural scrolling, scrolling up always means up
            input.wheel += -event.wheel.y if event.wheel.direction == .FLIPPED else event.wheel.y
        }
    }
    live_resize.polling = false

    tick_clock()
    return window.quit
}

// The frame's start, frame_time is since the previous one's
tick_clock :: proc() {
    counter := sdl.GetPerformanceCounter()
    clock.frame_time = f32(f64(counter - clock.last_counter) / f64(sdl.GetPerformanceFrequency()))
    clock.last_counter = counter
}

in_background :: proc() -> bool {
    return intrinsics.atomic_load(&window.background)
}

// Blocks until the app is back in front, or quit
wait_for_foreground :: proc() {
    event: sdl.Event
    for intrinsics.atomic_load(&window.background) && !window.quit {
        if sdl.WaitEvent(&event) && event.type == .QUIT do window.quit = true
    }

    // Not a frame that took as long as the app was away
    clock.last_counter = sdl.GetPerformanceCounter()
}

// A desktop window minimized or covered by other windows, nothing of it would show
window_hidden :: proc() -> bool {
    return sdl.GetWindowFlags(window.handle) & {.MINIMIZED, .HIDDEN, .OCCLUDED} != {}
}

// Blocks until the window shows again, or quit
wait_while_hidden :: proc() {
    event: sdl.Event
    for window_hidden() && !window.quit {
        if sdl.WaitEvent(&event) && (event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED) do window.quit = true
    }

    // Not a frame that took as long as the window was hidden
    clock.last_counter = sdl.GetPerformanceCounter()
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
        intrinsics.atomic_store(&window.background, true)
    case .WILL_ENTER_FOREGROUND:
        intrinsics.atomic_store(&window.background, false)
    }
    return true
}

// The desktop window keeps drawing while it's dragged or zoomed to another size. The OS runs the drag in a
// loop of its own that should_close is stuck in, and asks for a frame from there 60 times a second instead:
// frame draws one with begin_frame and end_frame, as a turn of the main loop does after should_close. An
// open menu of the menu bar is the same, see start_menu_frames.
live_resize_frames :: proc(frame: proc(data: rawptr), data: rawptr) {
    live_resize.frame = frame
    live_resize.data = data
    live_resize.frame_context = context
    start_menu_frames()
}

// On the main thread, from inside the OS's loop, see live_resize_frames. The zoom of a double click on the
// title bar is animated by the OS with the main loop stuck the same way, with no timer but a resize event
// per step of the animation, and those draw a frame each. A drag sends both, its timer's frames do for it.
DRAG_TIMER_MS :: 50 // the drag's timer ticks every 16 ms, a resize this soon after a tick is the drag's

watch_live_resize :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
    if live_resize.frame == nil || !live_resize.polling || live_resize.resizing do return true

    #partial switch event.type {
    case .WINDOW_EXPOSED:
        if event.window.data1 != 1 do return true

        live_resize.drag_tick = sdl.GetTicks()
    case .WINDOW_RESIZED:
        if sdl.GetTicks() - live_resize.drag_tick < DRAG_TIMER_MS do return true
    case:
        return true
    }

    draw_from_os_loop()
    return true
}

// A frame from inside the OS's loop, a drag's, a zoom's or an open menu's. The keys and clicks polled before
// it are its own, the main loop's next frame would take them again.
draw_from_os_loop :: proc "c" () {
    context = live_resize.frame_context
    live_resize.resizing = true
    tick_clock()
    live_resize.frame(live_resize.data)
    live_resize.resizing = false

    input.keys_pressed = {}
    input.mouse_clicked = false
    input.wheel = 0
}

// Uploads the frame's vertices, draws the render targets, then the window
end_frame :: proc() {
    // Without one nothing is drawn, the render targets hold what they had, see last_frame_dropped
    command_buffer := acquire_command_buffer()
    if command_buffer == nil {
        gpu.dropped = true
        submit_gpu_command_buffer(command_buffer)
        return
    }

    swapchain, swapchain_size := acquire_swapchain(command_buffer)

    // No vertex buffer, nothing to draw with
    gpu.dropped = !upload_vertices(command_buffer)
    if gpu.dropped {
        submit_gpu_command_buffer(command_buffer)
        return
    }

    draw_render_targets(command_buffer)

    // Minimized or hidden, the window has nothing to draw into. The render targets are drawn all the same,
    // they're up to date when it shows again.
    if swapchain == nil {
        submit_gpu_command_buffer(command_buffer)
        return
    }

    draw_window(command_buffer, swapchain, swapchain_size)
    submit_gpu_command_buffer(command_buffer, .MAX_FPS)
}

// How the main loop is paced after a frame is submitted
FrameWait :: enum {
    // The window doesn't show the frame, no swapchain waits for vsync and the loop would spin with
    // nothing to pace it. A 60 Hz frame's sleep stands in for the wait.
    UNSHOWN,
    // The rest of the frame at the limited rate, see wait_for_max_fps
    MAX_FPS,
}

UNSHOWN_FRAME_MS :: 16

// Without a command buffer it only waits
submit_gpu_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer, wait: FrameWait = .UNSHOWN) {
    if command_buffer != nil do _ = sdl.SubmitGPUCommandBuffer(command_buffer)

    switch wait {
    case .UNSHOWN:
        sdl.Delay(UNSHOWN_FRAME_MS)
    case .MAX_FPS:
        wait_for_max_fps()
    }
}

acquire_command_buffer :: proc() -> ^sdl.GPUCommandBuffer {
    command_buffer := sdl.AcquireGPUCommandBuffer(gpu.device)
    if command_buffer == nil do fmt.eprintln("SDL_AcquireGPUCommandBuffer failed:", sdl.GetError())

    return command_buffer
}

// The window's texture to draw into and its size in pixels, nil while it's minimized or hidden. A failure
// is reported once, it can fail every frame while Android tears the surface down.
acquire_swapchain :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> (swapchain: ^sdl.GPUTexture, size: [2]f32) {
    width, height: u32
    acquired := sdl.WaitAndAcquireGPUSwapchainTexture(command_buffer, window.handle, &swapchain, &width, &height)
    if !acquired && !gpu.acquire_failed {
        fmt.eprintln("SDL_WaitAndAcquireGPUSwapchainTexture failed:", sdl.GetError())
    }
    gpu.acquire_failed = !acquired

    return swapchain, {f32(width), f32(height)}
}

// The render targets first, then the window in a single pass. Apple's and nearly every phone's GPU
// draws in tiles, each pass loads its whole target into them and stores it back, a window pass
// between each render target would move the full screen through memory every time. The window is
// never sampled, and each target is finished before the window draws it, the order stays right.
draw_render_targets :: proc(command_buffer: ^sdl.GPUCommandBuffer) {
    for pass, pass_index in gpu.frame.passes {
        if !pass.offscreen || pass.target == nil do continue

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
        replay_commands(command_buffer, render_pass, commands, .TARGET, pass.target_size, pass.offset, pass.zoom)
        sdl.EndGPURenderPass(render_pass)
    }
}

// Every window pass into the swapchain, size in pixels
draw_window :: proc(command_buffer: ^sdl.GPUCommandBuffer, swapchain: ^sdl.GPUTexture, size: [2]f32) {
    // Drawing points to the swapchain's pixels: the display's density and the UI scale
    logical_w: i32
    sdl.GetWindowSize(window.handle, &logical_w, nil)
    zoom := size.x / f32(max(logical_w, 1)) * window.ui_scale

    clear := normalize_color(gpu.drawing.clear)
    color_target := sdl.GPUColorTargetInfo {
        texture     = swapchain,
        clear_color = {clear.r, clear.g, clear.b, clear.a},
        load_op     = .CLEAR,
        store_op    = .STORE,
    }
    render_pass := begin_render_pass(command_buffer, &color_target, size)
    for pass, pass_index in gpu.frame.passes {
        if pass.offscreen do continue

        replay_commands(command_buffer, render_pass, pass_commands(pass_index), .WINDOW, size, {}, zoom)
    }
    sdl.EndGPURenderPass(render_pass)
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

// Issues the GPU draws for commands recorded during the frame: binds each one's pipeline, uniforms,
// texture and scissor, then draws its vertices. offset is the drawing position of the target's top left
// corner, zoom scales drawing coordinates to its pixels.
replay_commands :: proc(
    command_buffer: ^sdl.GPUCommandBuffer,
    render_pass: ^sdl.GPURenderPass,
    commands: []DrawCommand,
    kind: PassKind,
    target_size: [2]f32,
    offset: [2]f32,
    zoom: f32,
) {
    // xy scale drawing coordinates to clip space, zw is the drawing position of the top left corner
    view := [4]f32{2 * zoom / target_size.x, 2 * zoom / target_size.y, offset.x, offset.y}

    // Bound and pushed only when they change
    pipeline: ^sdl.GPUGraphicsPipeline
    uniforms: UniformRange
    samplers := PROGRAM_SAMPLERS
    for command in commands {
        if command.vertex_count == 0 do continue

        // A texture that failed to load
        sampled := samplers[command.program] > 0
        if sampled && command.texture == nil do continue

        if next := gpu.pipelines[command.program][command.blend][kind]; next != pipeline {
            pipeline = next
            sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
            sdl.PushGPUVertexUniformData(command_buffer, 0, &view, size_of(view))
        }
        if command.uniforms.size > 0 && command.uniforms != uniforms {
            uniforms = command.uniforms
            sdl.PushGPUFragmentUniformData(command_buffer, 0, &gpu.frame.uniform_data[uniforms.offset], u32(uniforms.size))
        }
        if sampled {
            texture_binding := sdl.GPUTextureSamplerBinding{command.texture, gpu.sampler}
            sdl.BindGPUFragmentSamplers(render_pass, 0, &texture_binding, 1)
        }

        scissor := scissor_pixels(command.scissor, target_size, offset, zoom)
        sdl.SetGPUScissor(render_pass, {scissor.x, scissor.y, scissor.width, scissor.height})
        sdl.DrawGPUPrimitives(render_pass, command.vertex_count, 1, command.first_vertex, 0)
    }
}

// The rest of the frame at the limited rate, counted from the start of the frame in should_close.
// A little short of it, the swapchain waits for the vsync that ends it, a sleep a touch too long
// would miss that one and hold the frame on screen a refresh longer.
// Not from the drag's loop, its timer paces the frames, see live_resize_frames
wait_for_max_fps :: proc() {
    VSYNC_MARGIN_S :: 0.002
    if clock.max_fps == 0 || live_resize.resizing do return

    elapsed := f64(sdl.GetPerformanceCounter() - clock.last_counter) / f64(sdl.GetPerformanceFrequency())
    remaining := 1 / f64(clock.max_fps) - elapsed - VSYNC_MARGIN_S
    if remaining > 0 do sdl.DelayPrecise(u64(remaining * 1e9))
}

// Pixels per drawing point, the display's density times the UI scale. Text rasterized at it lands texel for
// pixel.
dpi_scale :: proc() -> f32 {
    return sdl.GetWindowPixelDensity(window.handle) * window.ui_scale
}

// The window's own size, in the system's points
window_points :: proc() -> [2]f32 {
    width, height: i32
    sdl.GetWindowSize(window.handle, &width, &height)
    return {f32(width), f32(height)}
}

// The system's points per density-independent one, the points a phone or a tablet is sized in: 1 on macOS
// and iOS, whose points are, the screen's density on Android, where the window is in pixels, the scale setting
// on a Linux desktop
content_scale :: proc() -> f32 {
    density, display := sdl.GetWindowPixelDensity(window.handle), sdl.GetWindowDisplayScale(window.handle)
    if density <= 0 || display <= 0 do return 1

    return display / density
}

// The window's top left corner, in the system's points across the displays
window_position :: proc() -> [2]i32 {
    position: [2]i32
    sdl.GetWindowPosition(window.handle, &position.x, &position.y)
    return position
}

// The desktop window, in the system's points, the size is seen at the next poll
set_window_size :: proc(width, height: i32) {
    when !MOBILE do sdl.SetWindowSize(window.handle, width, height)
}

// In a frame drawn from the OS's own loop, a drag's, a zoom's or an open menu's, see live_resize_frames
resizing :: proc() -> bool {
    return live_resize.resizing
}

// Part of the window clear of the notch and the home indicator
safe_area :: proc() -> Rect {
    area: sdl.Rect
    if !sdl.GetWindowSafeArea(window.handle, &area) {
        size := window_size()
        return {0, 0, size.x, size.y}
    }
    scale := window.ui_scale
    return {f32(area.x) / scale, f32(area.y) / scale, f32(area.w) / scale, f32(area.h) / scale}
}

key_down :: proc(key: Key) -> bool {
    return sdl.GetKeyboardState(nil)[scancodes[key]]
}

mouse_position :: proc() -> [2]f32 {
    position: [2]f32
    _ = sdl.GetMouseState(&position.x, &position.y)
    return position / window.ui_scale
}

mouse_down :: proc() -> bool {
    return .LEFT in sdl.GetMouseState(nil, nil)
}

// At once, not after the frame: a texture drawn earlier in the frame is still to be drawn in end_frame
unload_texture :: proc(texture: Texture) {
    if texture.handle != nil do sdl.ReleaseGPUTexture(gpu.device, texture.handle)
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
    if handle == nil do fmt.eprintln("Could not create a render target", width, "x", height, ":", sdl.GetError())

    return {{handle, width, height}}
}

// False when the buffers couldn't be made, nothing can be drawn then
upload_vertices :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
    if len(gpu.frame.vertices) == 0 do return true

    size := len(gpu.frame.vertices) * size_of(Vertex)

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
    mem.copy(mapped, raw_data(gpu.frame.vertices), size)
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

// Straight alpha RGBA, the sampler is linear already. An empty texture when it fails, the draws with it are
// skipped.
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
    if command_buffer == nil {
        fmt.eprintln("SDL_AcquireGPUCommandBuffer failed:", sdl.GetError())
        sdl.ReleaseGPUTexture(gpu.device, handle)
        return {}
    }

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
