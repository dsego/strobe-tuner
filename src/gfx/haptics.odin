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

import "base:intrinsics"
import sdl "vendor:sdl3"

// A short tap felt in the hand: the Taptic Engine on an iPhone, the vibrator on an Android phone. An iPad, a
// Mac or a phone without one has none, has_haptics says so and haptic_tap does nothing.

Haptics :: struct {
    checked:   bool,
    available: bool,
    android:   ^sdl.Haptic, // the phone's vibrator, SDL lists it as a haptic device
    ios:       ^UIImpactFeedbackGenerator, // made once, prepared after each tap so the next one comes on time
}

haptics: Haptics

has_haptics :: proc() -> bool {
    if haptics.checked do return haptics.available

    haptics.checked = true
    when IOS {
        // UIUserInterfaceIdiomPhone, an iPad has no Taptic Engine
        device := intrinsics.objc_send(^UIDevice, UIDevice, "currentDevice")
        if intrinsics.objc_send(int, device, "userInterfaceIdiom") != 0 do return false

        // UIImpactFeedbackStyleLight, a tap rather than a knock
        generator := intrinsics.objc_send(^UIImpactFeedbackGenerator, UIImpactFeedbackGenerator, "alloc")
        haptics.ios = intrinsics.objc_send(^UIImpactFeedbackGenerator, generator, "initWithStyle:", int(0))
        intrinsics.objc_send(nil, haptics.ios, "prepare")
        haptics.available = haptics.ios != nil
    } else when ANDROID {
        if !sdl.InitSubSystem({.HAPTIC}) do return false

        count: i32
        ids := sdl.GetHaptics(&count)
        defer sdl.free(ids)

        for index in 0 ..< count {
            haptic := sdl.OpenHaptic(([^]sdl.HapticID)(ids)[index])
            if haptic != nil && sdl.InitHapticRumble(haptic) {
                haptics.android = haptic
                break
            }
            if haptic != nil do sdl.CloseHaptic(haptic)
        }
        haptics.available = haptics.android != nil
    }
    return haptics.available
}

haptic_tap :: proc() {
    if !has_haptics() do return

    when IOS {
        intrinsics.objc_send(nil, haptics.ios, "impactOccurred")
        intrinsics.objc_send(nil, haptics.ios, "prepare")
    } else when ANDROID {
        _ = sdl.PlayHapticRumble(haptics.android, 0.5, 20)
    }
}

when IOS {
    @(objc_class = "UIDevice")
    UIDevice :: struct {
        using _: intrinsics.objc_object,
    }

    @(objc_class = "UIImpactFeedbackGenerator")
    UIImpactFeedbackGenerator :: struct {
        using _: intrinsics.objc_object,
    }
} else {
    UIImpactFeedbackGenerator :: struct {}
}
