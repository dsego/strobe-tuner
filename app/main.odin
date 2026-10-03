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

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

// Building for iOS, see ios/build-sim.sh
IOS :: #config(IOS, false)
// Building for Android, see android/build.sh
ANDROID :: ODIN_PLATFORM_SUBTARGET == .Android
// A phone: touch sized controls, portrait, suspended in the background, the system picks the input
MOBILE :: IOS || ANDROID

#assert(!MOBILE || RENDERER == "sdl", "iOS and Android need the sdl renderer")


main :: proc() {
    when IOS {
        // UIKit owns the main thread, SDL starts the app from its application delegate
        sdl.RunApp(c.int(len(runtime.args__)), raw_data(runtime.args__), ios_main, nil)
    } else {
        // On Android SDL's Java activity loads libmain.so and calls its C main on a thread of its own,
        // see android/StrobieActivity.java
        run()
    }
}

ios_main :: proc "c" (argc: c.int, argv: [^]cstring) -> c.int {
    context = runtime.default_context()
    run()
    return 0
}

run :: proc() {

    // Tracking allocator that warns you if your program is leaking memory
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer mem.tracking_allocator_destroy(&track)
        context.allocator = mem.tracking_allocator(&track)
        defer {
            for _, leak in track.allocation_map {
                fmt.printf("%v leaked %m\n", leak.location, leak.size)
            }
            for bad_free in track.bad_free_array {
                fmt.printf(
                    "%v allocation %p was freed badly\n",
                    bad_free.location,
                    bad_free.memory,
                )
            }
        }
    }

    config := load_config()
    run_app(&config)
    save_config(config)
}
