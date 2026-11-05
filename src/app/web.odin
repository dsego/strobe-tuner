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


// In a browser: the page starts the app once, then asks for a frame at the display's rate, see
// platform/web/strobie.js. Nothing is torn down, the page is closed with everything in it.
#+build js
package app

import "core:encoding/ini"

import "../audio"
import "../gfx"

// What the frames share, run_app keeps them on its stack instead
web_config: Config
web_app: App
web_started: bool

start_web_app :: proc() {
    web_config = load_config()
    web_app = new_app(&web_config)
    web_started = start_app(&web_app)
}

// odin.js calls it for every frame the browser draws, false stops asking
@(export)
step :: proc(delta_time: f64) -> (keep_going: bool) {
    if !web_started do return false
    if !gfx.frame_due() do return true

    // The labels and readouts are formatted into the temp allocator, nothing in it outlives a frame
    defer free_all(context.temp_allocator)

    gfx.begin_web_frame()
    audio.take_input(web_app.input.capture)
    run_frame(&web_app)
    gfx.clear_frame_input()
    return true
}

// The page keeps no settings, every visit starts from the defaults: it's a demo of the app, and a
// visitor sees the defaults as they are now
load_ini :: proc() -> (ini.Map, bool) {
    return nil, false
}

// Settings changed on the page last until it's closed or reloaded
save_ini :: proc(ini_map: ini.Map) {}
