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
import "core:fmt"
import "core:strings"

import "../audio"
import "../gfx"

foreign import strobie_storage "strobie_storage"

// The config's text in the page's local storage, see platform/web/strobie.js
@(default_calling_convention = "contextless")
foreign strobie_storage {
    // In bytes, -1 without one
    config_length :: proc() -> int ---
    load_config_text :: proc(buffer: [^]u8, capacity: int) -> int ---
    save_config_text :: proc(text: string) ---
}

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

// The config as save_ini left it in the page's storage, the defaults on the first visit
load_ini :: proc() -> (ini.Map, bool) {
    length := config_length()
    if length < 0 {
        fmt.println("No config in the page's storage")
        return nil, false
    }

    text := make([]u8, length)
    defer delete(text)

    load_config_text(raw_data(text), length)
    ini_map, err := ini.load_map_from_string(string(text), context.allocator)
    if err != nil {
        fmt.println("Failed to read the config", err)
        return nil, false
    }
    return ini_map, true
}

save_ini :: proc(ini_map: ini.Map) {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    if !write_ini_pairs(strings.to_stream(&builder), ini_map) {
        fmt.println("Failed to write the config")
        return
    }
    save_config_text(strings.to_string(builder))
}
