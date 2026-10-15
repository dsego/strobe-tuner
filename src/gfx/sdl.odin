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

// SDL3 GPU backend, Metal shaders on macOS and iOS and Vulkan SPIR-V elsewhere, see gfx.odin
//
// Drawing only records vertices and draw commands, end_frame uploads the vertices in one go
// and replays the commands. Every begin/end_render_target splits the frame into another render pass.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"

Texture :: struct {
    handle:        ^sdl.GPUTexture,
    width, height: i32,
}

// A texture's new pixels, from offset in this frame's texture_pixels
TextureUpload :: struct {
    texture: Texture,
    offset:  int,
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
    SCOPE,
}

// The textures each program's fragment shader samples, the strobe and the shadow draw theirs from uniforms
PROGRAM_SAMPLERS :: [Program]u32 {
    .SPRITE = 1,
    .STROBE = 0,
    .BLOOM  = 1,
    .SHADOW = 0,
    .SCOPE  = 1,
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
    offscreen:     bool, // into a render target, not the window
    target:        ^sdl.GPUTexture, // the render target's, nil for one that couldn't be made: its draws are dropped
    target_size:   [2]f32, // in pixels
    clear:         Maybe(Color), // a target's, or the draws cover all of it, the window clears to gpu.drawing.clear
    offset:        [2]f32,
    zoom:          f32,
    first_command: int,
}

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

// What the frame draws, filled by the draw calls and sent to the GPU by end_frame
GpuFrame :: struct {
    vertices:        [dynamic]Vertex,
    commands:        [dynamic]DrawCommand,
    passes:          [dynamic]Pass,
    uniform_data:    [dynamic]u8,
    texture_pixels:  [dynamic]u8, // the textures updated this frame, see update_texture
    texture_uploads: [dynamic]TextureUpload,
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
    texture_transfer: ^sdl.GPUTransferBuffer,
    texture_capacity: int,

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
        .SCOPE  = {#load("../shaders/metal/scope.metal"), "scope_fragment"},
    }
} else {
    SHADER_FORMAT :: sdl.GPUShaderFormat{.SPIRV}

    vertex_shader_code := ShaderCode{#load("../../build/spirv/sprite.vert.spv"), "main"}
    fragment_shader_code := [Program]ShaderCode {
        .SPRITE = {#load("../../build/spirv/sprite.frag.spv"), "main"},
        .STROBE = {#load("../../build/spirv/strobe.frag.spv"), "main"},
        .BLOOM  = {#load("../../build/spirv/bloom.frag.spv"), "main"},
        .SHADOW = {#load("../../build/spirv/shadow.frag.spv"), "main"},
        .SCOPE  = {#load("../../build/spirv/scope.frag.spv"), "main"},
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
input:       Input
clock:       Clock
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
    if gpu.texture_transfer != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.texture_transfer)

    delete(gpu.frame.vertices)
    delete(gpu.frame.commands)
    delete(gpu.frame.passes)
    delete(gpu.frame.uniform_data)
    delete(gpu.frame.texture_pixels)
    delete(gpu.frame.texture_uploads)

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

// The last frame wasn't drawn, what was drawn into the render targets during it isn't there
last_frame_dropped :: proc() -> bool {
    return gpu.dropped
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

begin_frame :: proc(clear: Color) {
    clear_dynamic_array(&gpu.frame.vertices)
    clear_dynamic_array(&gpu.frame.commands)
    clear_dynamic_array(&gpu.frame.passes)
    clear_dynamic_array(&gpu.frame.uniform_data)
    clear_dynamic_array(&gpu.frame.texture_pixels)
    clear_dynamic_array(&gpu.frame.texture_uploads)
    gpu.drawing = {
        program = .SPRITE,
        blend   = .ALPHA,
        clear   = clear,
    }

    begin_window_pass()
}

// Uploads the frame's textures and vertices, draws the render targets, then the window
end_frame :: proc() {
    // Without one nothing is drawn, the render targets hold what they had, see last_frame_dropped
    command_buffer := acquire_command_buffer()
    if command_buffer == nil {
        gpu.dropped = true
        submit_gpu_command_buffer(command_buffer)
        return
    }

    swapchain, swapchain_size := acquire_swapchain(command_buffer)

    // The textures' new pixels go up first, before the passes that draw them. No vertex buffer, nothing to
    // draw with.
    upload_textures(command_buffer)
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

// The draw commands recorded between this pass's start and the next one's
pass_commands :: proc(pass_index: int) -> []DrawCommand {
    last_command := len(gpu.frame.commands)
    if pass_index + 1 < len(gpu.frame.passes) do last_command = gpu.frame.passes[pass_index + 1].first_command

    return gpu.frame.commands[gpu.frame.passes[pass_index].first_command:last_command]
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

        sdl.SetGPUScissor(render_pass, scissor_pixels(command.scissor, target_size, offset, zoom))
        sdl.DrawGPUPrimitives(render_pass, command.vertex_count, 1, command.first_vertex, 0)
    }
}

// A scissor in drawing coordinates as the target's pixels, none is all of it
scissor_pixels :: proc(scissor: Maybe(Rect), target_size, offset: [2]f32, zoom: f32) -> sdl.Rect {
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

// 0 for the display's rate, the swapchain waits for vsync
limit_fps :: proc(fps: int) {
    clock.max_fps = fps
}

frame_time :: proc() -> f32 {
    return clock.frame_time
}

// Pixels per drawing point, the display's density times the UI scale. Text rasterized at it lands texel for
// pixel.
dpi_scale :: proc() -> f32 {
    return sdl.GetWindowPixelDensity(window.handle) * window.ui_scale
}

// In drawing points, see set_ui_scale
window_size :: proc() -> [2]f32 {
    return window_points() / window.ui_scale
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

key_pressed :: proc(key: Key) -> bool {
    return key in input.keys_pressed
}

key_down :: proc(key: Key) -> bool {
    return sdl.GetKeyboardState(nil)[scancodes[key]]
}

mouse_position :: proc() -> [2]f32 {
    position: [2]f32
    _ = sdl.GetMouseState(&position.x, &position.y)
    return position / window.ui_scale
}

mouse_pressed :: proc() -> bool {
    return input.mouse_clicked
}

mouse_down :: proc() -> bool {
    return .LEFT in sdl.GetMouseState(nil, nil)
}

// Whether the last press was a finger rather than a mouse or a trackpad, a finger covers what it presses
touch_input :: proc() -> bool {
    return input.touch
}

mouse_wheel :: proc() -> f32 {
    return input.wheel
}

// One byte a texel, read as the red channel, for pixels the CPU redraws every frame with update_texture.
// Starts out undefined, an empty texture when it fails.
create_gray_texture :: proc(width, height: i32) -> Texture {
    handle := sdl.CreateGPUTexture(
        gpu.device,
        {
            type = .D2,
            format = .R8_UNORM,
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
    return {handle, width, height}
}

// New pixels for a create_gray_texture texture, uploaded before this frame draws. The draws earlier in the
// frame see them too.
update_texture :: proc(texture: Texture, pixels: []u8) {
    if texture.handle == nil do return

    assert(len(pixels) == int(texture.width * texture.height))

    // Each texture's pixels start on a 16 byte boundary, as copies from a buffer want it
    offset := (len(gpu.frame.texture_pixels) + 15) &~ 15
    resize(&gpu.frame.texture_pixels, offset)
    append(&gpu.frame.texture_pixels, ..pixels)
    append(&gpu.frame.texture_uploads, TextureUpload{texture, offset})
}

// At once, not after the frame: a texture drawn earlier in the frame is still to be drawn in end_frame
unload_texture :: proc(texture: Texture) {
    if texture.handle != nil do sdl.ReleaseGPUTexture(gpu.device, texture.handle)
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

// The pixels update_texture queued this frame, in one copy pass. A texture that can't be uploaded keeps the
// pixels it had, the frame is still drawn.
upload_textures :: proc(command_buffer: ^sdl.GPUCommandBuffer) {
    if len(gpu.frame.texture_uploads) == 0 do return

    size := len(gpu.frame.texture_pixels)
    if size > gpu.texture_capacity {
        if gpu.texture_transfer != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.texture_transfer)

        gpu.texture_capacity = max(size, 2 * gpu.texture_capacity)
        gpu.texture_transfer = sdl.CreateGPUTransferBuffer(gpu.device, {usage = .UPLOAD, size = u32(gpu.texture_capacity)})
        if gpu.texture_transfer == nil {
            fmt.eprintln("Could not create the texture transfer buffer:", sdl.GetError())
            gpu.texture_capacity = 0 // tried again next frame
            return
        }
    }

    mapped := sdl.MapGPUTransferBuffer(gpu.device, gpu.texture_transfer, true)
    if mapped == nil {
        fmt.eprintln("SDL_MapGPUTransferBuffer failed:", sdl.GetError())
        return
    }
    mem.copy(mapped, raw_data(gpu.frame.texture_pixels), size)
    sdl.UnmapGPUTransferBuffer(gpu.device, gpu.texture_transfer)

    // Every texel is replaced, the GPU can take a fresh copy instead of waiting for the frames still drawing
    // the old one
    copy_pass := sdl.BeginGPUCopyPass(command_buffer)
    for upload in gpu.frame.texture_uploads {
        texture := upload.texture
        sdl.UploadToGPUTexture(
            copy_pass,
            {transfer_buffer = gpu.texture_transfer, offset = u32(upload.offset)},
            {texture = texture.handle, w = u32(texture.width), h = u32(texture.height), d = 1},
            true,
        )
    }
    sdl.EndGPUCopyPass(copy_pass)
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
