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

#+build darwin
package gfx

import "base:intrinsics"
import CG "core:sys/darwin/CoreGraphics"
import NS "core:sys/darwin/Foundation"
import sdl "vendor:sdl3"

// The window's colors read as Display P3 rather than sRGB, on the iPhone, iPad and Mac. The colors are picked
// on the simulator, which puts them on the Mac's P3 screen as they are; an sRGB layer, what SDL gives an SDR
// swapchain, has the system turn them into sRGB's paler coral on a device (2026-11-22, #FF6767 showed as P3
// #ED716C on an iPhone). Grays are the same in both. The values drawn don't change, only how they're read.
//
// SDL keeps its Metal view to itself, the layer is found under the window: the Mac's content view, the root
// view controller's view on iOS. Called after the swapchain is set up, as SDL sets the layer's color space
// there.
use_display_p3 :: proc() {
    properties := sdl.GetWindowProperties(window.handle)
    root: ^NS.Object
    when IOS {
        ui_window := cast(^NS.Object)sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_UIKIT_WINDOW_POINTER, nil)
        if ui_window == nil do return
        controller := intrinsics.objc_send(^NS.Object, ui_window, "rootViewController")
        if controller == nil do return
        root = intrinsics.objc_send(^NS.Object, controller, "view")
    } else {
        ns_window := cast(^NS.Object)sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
        if ns_window == nil do return
        root = intrinsics.objc_send(^NS.Object, ns_window, "contentView")
    }

    layer := find_metal_layer(root)
    if layer == nil do return
    if !intrinsics.objc_send(NS.BOOL, layer, "respondsToSelector:", intrinsics.objc_find_selector("setColorspace:")) {
        return
    }

    display_p3 := CG.ColorSpaceCreateWithName(CG.ColorSpaceDisplayP3)
    defer CG.ColorSpaceRelease(display_p3)
    intrinsics.objc_send(nil, layer, "setColorspace:", display_p3)
}

// The first CAMetalLayer at or under the view, nil if there's none
find_metal_layer :: proc(view: ^NS.Object) -> ^NS.Object {
    if view == nil do return nil

    layer := intrinsics.objc_send(^NS.Object, view, "layer")
    if layer != nil && intrinsics.objc_send(NS.BOOL, layer, "isKindOfClass:", intrinsics.objc_find_class("CAMetalLayer")) {
        return layer
    }

    subviews := intrinsics.objc_send(^NS.Object, view, "subviews")
    if subviews == nil do return nil
    for index in 0 ..< intrinsics.objc_send(NS.UInteger, subviews, "count") {
        found := find_metal_layer(intrinsics.objc_send(^NS.Object, subviews, "objectAtIndex:", index))
        if found != nil do return found
    }
    return nil
}
