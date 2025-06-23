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
import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// https://github.com/odin-lang/examples/blob/master/metal/learn_metal/02-argbuffers-no-sdl/02-argbuffers-no-sdl.odin


setup_mac_app :: proc() {
    app := NS.Application.sharedApplication()
    defer app->release()
    app->setActivationPolicy(.Regular) // without this window is not brought to foreground on launch
    app->finishLaunching()

    create_main_menu(app)
}

// TODO: custom app menu
create_main_menu :: proc(app: ^NS.Application) {
    // main_menu := NS.Menu.alloc()->init()
    // main_menu->addItem(NS.MenuItem.alloc()->init())

    // main_menu_app_item := main_menu->addItemWithTitle(NS.AT("Metal"), nil, NS.AT(""))
    // app_menu := NS.Menu.alloc()->init()
    // app_menu->addItemWithTitle(NS.AT("Quit"), intrinsics.objc_find_selector("terminate:"), NS.AT("q"))
    // main_menu_app_item->setSubmenu(app_menu)

    // main_menu_edit_item := main_menu->addItemWithTitle(NS.AT("Edit"), nil, NS.AT(""))
    // edit_menu := NS.Menu.alloc()->init()
    // main_menu_edit_item->setSubmenu(edit_menu)

    // main_menu_view_item := main_menu->addItemWithTitle(NS.AT("View"), nil, NS.AT(""))
    // view_menu := NS.Menu.alloc()->init()
    // view_menu->addItemWithTitle(NS.AT("Enter Full Screen"), intrinsics.objc_find_selector("toggleFullScreen:"), NS.AT("f"))
    // main_menu_view_item->setSubmenu(view_menu)

    // app->setMainMenu(main_menu)


}



audio_input_dropdown_shown := false

@(objc_class="AudioInputDropdownDelegate")
AudioInputDropdownDelegate :: struct {
    using _: NS.MenuDelegate
}

@(objc_type=AudioInputDropdownDelegate, objc_name="menuDidClose")
AudioInputDropdownDelegate_menuDidClose :: proc "c" (self: ^AudioInputDropdownDelegate, menu: ^NS.Menu) {
    audio_input_dropdown_shown = false
}

// delegate := NS.MenuDelegate{}
// menuDidClose :: proc(self: ^AudioInputDropdownDelegate, menu: ^NS.Menu) {
//     audio_input_dropdown_shown = false
// }


show_audio_input_dropdown :: proc(x: f32, y: f32) {

    popup_menu := NS.Menu.alloc()->init()
    defer popup_menu->release()

    popup_menu->addItemWithTitle(NS.AT("Test"), nil, NS.AT(""))
    popup_menu->addItemWithTitle(NS.AT("Foo"), nil, NS.AT(""))
    popup_menu->addItemWithTitle(NS.AT("Bar"), nil, NS.AT(""))

    // intrinsics.objc_find_selector("toggleFullScreen:")

    // menu_delegate := NS.objc_allocateClassPair(NS.objc_lookUpClass("NSMenuDelegate"), "AudioInputDropdownDelegate", 0)
    // menu_did_close_selector := intrinsics.objc_find_selector("menuDidClose")
    // NS.class_addMethod(menu_delegate, menu_did_close_selector, auto_cast AudioInputDropdownDelegate_menuDidClose, "v@:@")
    // NS.objc_registerClassPair(menu_delegate)
    // popup_menu->setDelegate(cast(^NS.MenuDelegate) menu_delegate)

    frame := get_window_frame()
    point := NS.Point{frame.x + NS.Float(x), frame.y + NS.Float(y)}
    popup_menu->popUpMenuPositioningItem(nil, point, nil)

    audio_input_dropdown_shown = true
}

get_window_frame :: proc() -> NS.Rect  {
    app := NS.Application.sharedApplication()
    defer app->release()

    window := app->keyWindow()
    frame := window->frame()
    return frame
}
