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


package app

// raylib backend (OpenGL), see gfx.odin

import "base:intrinsics"
import "core:reflect"
import CF "core:sys/darwin/CoreFoundation"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

when RENDERER == "raylib" {

    Texture :: rl.Texture2D
    Font :: rl.Font
    RenderTarget :: rl.RenderTexture2D

    Shader :: struct {
        handle: rl.Shader,
        kind:   ShaderKind,
    }

    raylib_keys := [Key]rl.KeyboardKey {
        .LEFT        = .LEFT,
        .RIGHT       = .RIGHT,
        .UP          = .UP,
        .DOWN        = .DOWN,
        .TAB         = .TAB,
        .SPACE       = .SPACE,
        .COMMA       = .COMMA,
        .ESCAPE      = .ESCAPE,
        .G           = .G,
        .H           = .H,
        .I           = .I,
        .R           = .R,
        .X           = .X,
        .LEFT_SHIFT  = .LEFT_SHIFT,
        .RIGHT_SHIFT = .RIGHT_SHIFT,
        .LEFT_SUPER  = .LEFT_SUPER,
        .RIGHT_SUPER = .RIGHT_SUPER,
    }

    // Uniform locations by field name, per shader
    uniform_locations: [ShaderKind]map[string]i32

    gfx_init :: proc(width, height: i32, title: cstring) -> bool {
        rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
        rl.SetConfigFlags({.WINDOW_HIGHDPI})
        rl.InitWindow(width, height, title)
        // Escape closes the sheets, Cmd+Q quits
        rl.SetExitKey(.KEY_NULL)

        // The colours are sRGB. Untagged, macOS shows the pixels in the display's own colour space and a
        // Display P3 screen oversaturates them.
        when ODIN_OS == .Darwin {
            window := (^NSWindow)(rl.GetWindowHandle())
            srgb := intrinsics.objc_send(^NSColorSpace, NSColorSpace, "sRGBColorSpace")
            intrinsics.objc_send(nil, window, "setColorSpace:", srgb)
        }
        rl.SetTargetFPS(120)
        return rl.IsWindowReady()
    }

    gfx_shutdown :: proc() {
        rl.CloseWindow()
    }

    gfx_should_close :: proc() -> bool {
        return rl.WindowShouldClose()
    }

    // Only iOS sends the app to the background
    gfx_in_background :: proc() -> bool {
        return false
    }

    gfx_wait_for_foreground :: proc() {}

    gfx_open_url :: proc(url: cstring) {
        rl.OpenURL(url)
    }

    gfx_limit_fps :: proc(fps: int) {
        rl.SetTargetFPS(i32(fps if fps > 0 else 120))
    }

    gfx_begin_frame :: proc(clear: Color) {
        rl.BeginDrawing()
        rl.ClearBackground(rl.Color(clear))
    }

    gfx_end_frame :: proc() {
        rl.EndDrawing()
    }

    gfx_frame_time :: proc() -> f32 {
        return rl.GetFrameTime()
    }

    gfx_dpi_scale :: proc() -> f32 {
        return rl.GetWindowScaleDPI().x
    }

    gfx_window_size :: proc() -> [2]f32 {
        return {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
    }

    // No notches on the desktop
    gfx_safe_area :: proc() -> Rect {
        size := gfx_window_size()
        return {0, 0, size.x, size.y}
    }

    key_pressed :: proc(key: Key) -> bool {
        return rl.IsKeyPressed(raylib_keys[key])
    }

    key_down :: proc(key: Key) -> bool {
        return rl.IsKeyDown(raylib_keys[key])
    }

    mouse_position :: proc() -> [2]f32 {
        return rl.GetMousePosition()
    }

    mouse_pressed :: proc() -> bool {
        return rl.IsMouseButtonPressed(.LEFT)
    }

    mouse_down :: proc() -> bool {
        return rl.IsMouseButtonDown(.LEFT)
    }

    // Only on the desktop, a mouse or a trackpad
    touch_input :: proc() -> bool {
        return false
    }

    mouse_wheel :: proc() -> f32 {
        wheel := rl.GetMouseWheelMove()
        // Undo natural scrolling, scrolling up always means up. raylib doesn't say if it's on, ask macOS.
        when ODIN_OS == .Darwin {
            if wheel != 0 && natural_scrolling() do wheel = -wheel
        }
        return wheel
    }

    when ODIN_OS == .Darwin {
        foreign import core_foundation "system:CoreFoundation.framework"

        @(default_calling_convention = "c")
        foreign core_foundation {
            CFPreferencesGetAppBooleanValue :: proc(key, application: CF.String, valid: ^b8) -> b8 ---
        }

        @(objc_class = "NSColorSpace")
        NSColorSpace :: struct {
            using _: intrinsics.objc_object,
        }

        @(objc_class = "NSWindow")
        NSWindow :: struct {
            using _: intrinsics.objc_object,
        }

        // On unless turned off in System Settings, a missing key means the default
        natural_scrolling :: proc() -> bool {
            valid: b8
            natural := CFPreferencesGetAppBooleanValue(CF.STR("com.apple.swipescrolldirection"), CF.STR(".GlobalPreferences"), &valid)
            return bool(natural) || !bool(valid)
        }
    }

    gfx_load_texture :: proc(png: []u8) -> Texture {
        image := rl.LoadImageFromMemory(".png", raw_data(png), i32(len(png)))
        defer rl.UnloadImage(image)
        return rl.LoadTextureFromImage(image)
    }

    // Straight alpha RGBA, filtered so shapes scale smoothly
    gfx_load_texture_rgba :: proc(width, height: i32, pixels: []u8) -> Texture {
        image := rl.Image {
            data    = raw_data(pixels),
            width   = width,
            height  = height,
            mipmaps = 1,
            format  = .UNCOMPRESSED_R8G8B8A8,
        }
        texture := rl.LoadTextureFromImage(image)
        rl.SetTextureFilter(texture, .BILINEAR)
        return texture
    }

    gfx_unload_texture :: proc(texture: Texture) {
        rl.UnloadTexture(texture)
    }

    // Not LoadFontFromMemory, its atlas is sized from the font size and the glyphs' widths and comes out
    // half height for a few narrow glyphs. A 125px ♯ alone got a 128x64 atlas, its bottom spilled past
    // the end. Here the glyphs go in one row as tall as the tallest.
    gfx_load_font :: proc(ttf: []u8, size: i32, codepoints: string) -> Font {
        PADDING :: 4 // like raylib, keeps the filtering from bleeding between glyphs

        ccodepoints := strings.clone_to_cstring(codepoints, context.temp_allocator)
        count := i32(0)
        runes := rl.LoadCodepoints(ccodepoints, &count)
        defer rl.UnloadCodepoints(runes)

        font := Font {
            baseSize     = size,
            glyphCount   = count,
            glyphPadding = PADDING,
        }
        font.glyphs = rl.LoadFontData(raw_data(ttf), i32(len(ttf)), size, runes, count, .DEFAULT, &font.glyphCount)
        if font.glyphs == nil do return font
        // UnloadFont frees them with raylib's allocator
        font.recs = cast([^]rl.Rectangle)rl.MemAlloc(u32(font.glyphCount) * size_of(rl.Rectangle))

        width, height: i32 = PADDING, 0
        for glyph in font.glyphs[:font.glyphCount] {
            width += glyph.image.width + PADDING
            height = max(height, glyph.image.height)
        }
        height += 2 * PADDING

        // White, the glyph in the alpha
        pixels := make([]u8, width * height * 2, context.temp_allocator)
        for i in 0 ..< width * height do pixels[2 * i] = 255
        x: i32 = PADDING
        for glyph, i in font.glyphs[:font.glyphCount] {
            source := ([^]u8)(glyph.image.data)
            for gy in 0 ..< glyph.image.height {
                for gx in 0 ..< glyph.image.width {
                    pixels[2 * ((PADDING + gy) * width + x + gx) + 1] = source[gy * glyph.image.width + gx]
                }
            }
            font.recs[i] = {f32(x), PADDING, f32(glyph.image.width), f32(glyph.image.height)}
            x += glyph.image.width + PADDING
        }

        atlas := rl.Image {
            data    = raw_data(pixels),
            width   = width,
            height  = height,
            mipmaps = 1,
            format  = .UNCOMPRESSED_GRAY_ALPHA,
        }
        font.texture = rl.LoadTextureFromImage(atlas)
        // Smooth drawn at another size, e.g. the ruler's notes growing, at its own size it's texel for pixel
        rl.SetTextureFilter(font.texture, .BILINEAR)
        return font
    }

    gfx_unload_font :: proc(font: Font) {
        rl.UnloadFont(font)
    }

    draw_texture :: proc(texture: Texture, source: Rect, dest: Rect, tint := WHITE) {
        rl.DrawTexturePro(
            texture,
            transmute(rl.Rectangle)source,
            transmute(rl.Rectangle)dest,
            {0, 0},
            0,
            rl.Color(tint),
        )
    }

    draw_rect :: proc(position: [2]f32, size: [2]f32, color: Color) {
        rl.DrawRectangleV(position, size, rl.Color(color))
    }

    draw_rect_lines :: proc(rect: Rect, thickness: f32, color: Color) {
        rl.DrawRectangleLinesEx(transmute(rl.Rectangle)rect, thickness, rl.Color(color))
    }

    draw_line :: proc(start, end: [2]f32, thickness: f32, color: Color) {
        rl.DrawLineEx(start, end, thickness, rl.Color(color))
    }

    draw_circle :: proc(center: [2]f32, radius: f32, color: Color) {
        rl.DrawCircleV(center, radius, rl.Color(color))
    }

    draw_text :: proc(font: Font, text: cstring, position: [2]f32, size: f32, spacing: f32, color: Color) {
        rl.DrawTextEx(font, text, position, size, spacing, rl.Color(color))
    }

    measure_text :: proc(font: Font, text: cstring, size: f32, spacing: f32) -> [2]f32 {
        return rl.MeasureTextEx(font, text, size, spacing)
    }

    begin_scissor :: proc(rect: Rect) {
        rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
    }

    end_scissor :: proc() {
        rl.EndScissorMode()
    }

    set_blend_mode :: proc(mode: BlendMode) {
        rl.EndBlendMode()
        switch mode {
        case .ALPHA:
        case .REPLACE:
            rlgl.SetBlendFactors(rlgl.ONE, rlgl.ZERO, rlgl.FUNC_ADD)
            rl.BeginBlendMode(.CUSTOM)
        case .ADD:
            rlgl.SetBlendFactors(rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD)
            rl.BeginBlendMode(.CUSTOM)
        }
    }

    gfx_load_shader :: proc(kind: ShaderKind) -> Shader {
        source: []u8
        switch kind {
        case .STROBE:
            source = #load("../shaders/strobe-shader.frag")
        case .BLOOM:
            source = #load("../shaders/bloom.frag")
        }
        fragment := strings.clone_to_cstring(string(source), context.temp_allocator)
        return {rl.LoadShaderFromMemory(nil, fragment), kind}
    }

    gfx_unload_shader :: proc(shader: Shader) {
        rl.UnloadShader(shader.handle)
        delete(uniform_locations[shader.kind])
        uniform_locations[shader.kind] = nil
    }

    begin_shader :: proc(shader: Shader) {
        rl.BeginShaderMode(shader.handle)
    }

    end_shader :: proc() {
        rl.EndShaderMode()
    }

    // Sets each field of the uniforms struct to the shader uniform with the same name
    set_shader_uniforms :: proc(shader: Shader, uniforms: ^$T) {
        // Draws still in the batch have to go out with the previous values
        rlgl.DrawRenderBatchActive()

        locations := &uniform_locations[shader.kind]
        for field in reflect.struct_fields_zipped(T) {
            if field.name == "_" do continue

            location, ok := locations[field.name]
            if !ok {
                name := strings.clone_to_cstring(field.name, context.temp_allocator)
                location = rl.GetShaderLocation(shader.handle, name)
                locations[field.name] = location
            }

            type: rl.ShaderUniformDataType
            switch field.type.id {
            case f32:
                type = .FLOAT
            case [2]f32:
                type = .VEC2
            case [4]f32:
                type = .VEC4
            case i32:
                type = .INT
            case:
                panic("unsupported shader uniform type")
            }

            rl.SetShaderValue(shader.handle, location, rawptr(uintptr(uniforms) + field.offset), type)
        }
    }

    draw_shader_quad :: proc(rect: Rect) {
        texture := Texture {
            id      = rlgl.GetTextureIdDefault(),
            width   = 1,
            height  = 1,
            mipmaps = 1,
            format  = .UNCOMPRESSED_R8G8B8A8,
        }
        draw_texture(texture, {0, 0, 1, 1}, rect)
    }

    gfx_load_render_target :: proc(width, height: i32) -> RenderTarget {
        target := rl.LoadRenderTexture(width, height)
        rl.SetTextureFilter(target.texture, .BILINEAR)
        return target
    }

    gfx_unload_render_target :: proc(target: RenderTarget) {
        rl.UnloadRenderTexture(target)
    }

    render_target_size :: proc(target: RenderTarget) -> [2]f32 {
        return {f32(target.texture.width), f32(target.texture.height)}
    }

    // offset is the top left corner of the target in the drawing coordinates, zoom scales them to target pixels
    begin_render_target :: proc(target: RenderTarget, clear: Color, offset: [2]f32 = {}, zoom: f32 = 1) {
        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.Color(clear))
        rl.BeginMode2D(rl.Camera2D{target = offset, zoom = zoom})
    }

    end_render_target :: proc() {
        rl.EndMode2D()
        rl.EndTextureMode()
    }

    // Render textures are stored upside down, the negative source height flips them back
    draw_render_target :: proc(target: RenderTarget, dest: Rect, tint := WHITE) {
        size := render_target_size(target)
        draw_texture(target.texture, {0, 0, size.x, -size.y}, dest, tint)
    }
}
