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

#+build darwin:default
package gfx

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import ObjC "core:sys/darwin/ObjectiveC"
import AK "vendor:darwin/AppKit"
import sdl "vendor:sdl3"

// The macOS menu bar, iOS has none, see menu.odin. SDL makes the app menu and the Window menu when it starts, the app
// adds its own items to them and menus of its own between them. A chosen item's command is picked up once
// a frame with menu_command.
//
// SDL sees every key before the menu does, a key equivalent reaches the app's key handling too. Each item
// has Command in its key, and the plain keys the app handles skip while Command is down.

Menu :: struct {
    target:   ^NS.Object, // gets every item's action, see menu_target
    chosen:   int, // the last item chosen, 0 none
    items:    [MAX_MENU_COMMANDS]^AK.MenuItem, // by command, for set_menu_checked
    checked:  [MAX_MENU_COMMANDS]bool,

    // The app's own menus by what add_menu returned, and what each calls as it opens, see menu_delegate
    menus:    [MAX_MENUS]^AK.Menu,
    openings: [MAX_MENUS]MenuOpening,
    count:    int,
    delegate: ^NS.Object,
    ctx:      runtime.Context, // the app's, its allocator for what opening makes
}

menu: Menu

MAX_MENUS :: 4

MenuOpening :: struct {
    callback: proc(data: rawptr),
    data:     rawptr,
}

// The items go into the app menu after its Settings…, SDL's Preferences… that macOS renames, found by its
// Command+, as the title may be either or another language's
add_app_menu_items :: proc(settings: int, items: []MenuItem) {
    app_menu := AK.MenuItem_submenu(AK.Menu_itemAtIndex(main_menu(), 0))
    comma := ns_string(",")
    defer comma->release()

    index := NS.Integer(-1)
    for position in 0 ..< AK.Menu_numberOfItems(app_menu) {
        key := intrinsics.objc_send(^NS.String, AK.Menu_itemAtIndex(app_menu, position), "keyEquivalent")
        if NS.String_isEqualToString(key, comma) {
            index = position
            break
        }
    }
    if index < 0 do return

    settings_title := ns_string("Settings…")
    defer settings_title->release()

    settings_item := AK.Menu_itemAtIndex(app_menu, index)
    AK.MenuItem_setTitle(settings_item, settings_title)
    attach_item(settings_item, settings)

    for item, offset in items do add_menu_item(app_menu, item, index + 1 + NS.Integer(offset))
}

// A menu of its own, before the Window menu. opening is called with data as it opens, from inside the
// frame's events, and may set its items then, see set_menu_items. Returns the menu for that, -1 for none.
add_menu :: proc(title: cstring, items: []MenuItem, opening: proc(data: rawptr) = nil, data: rawptr = nil) -> int {
    if menu.count == MAX_MENUS do return -1

    menu_title := ns_string(title)
    defer menu_title->release()

    // Kept by the bar's item, as long as the app runs
    submenu := AK.Menu_initWithTitle(NS.alloc(AK.Menu), menu_title)
    defer submenu->release()

    for item in items do add_menu_item(submenu, item)

    bar_item := NS.new(AK.MenuItem)
    defer bar_item->release()

    AK.MenuItem_setSubmenu(bar_item, submenu)

    bar := main_menu()
    index := AK.Menu_indexOfItemWithSubmenu(bar, AK.Application_windowsMenu(AK.Application_sharedApplication()))
    if index < 0 do index = AK.Menu_numberOfItems(bar)

    AK.Menu_insertItem(bar, bar_item, index)

    if opening != nil {
        menu.ctx = context
        AK.Menu_setDelegate(submenu, cast(^AK.MenuDelegate)menu_delegate())
    }
    menu.menus[menu.count] = submenu
    menu.openings[menu.count] = {opening, data}
    menu.count += 1
    return menu.count - 1
}

// The menu's items replaced, their commands start unchecked
set_menu_items :: proc(which: int, items: []MenuItem) {
    if which < 0 || which >= menu.count do return

    submenu := menu.menus[which]
    for position in 0 ..< AK.Menu_numberOfItems(submenu) {
        command := int(AK.MenuItem_tag(AK.Menu_itemAtIndex(submenu, position)))
        if command > 0 && command < MAX_MENU_COMMANDS do menu.items[command] = nil
    }
    AK.Menu_removeAllItems(submenu)

    for item in items do add_menu_item(submenu, item)
}

// The items go at the end of the Window menu, after a separator
add_window_menu_items :: proc(items: []MenuItem) {
    window_menu := AK.Application_windowsMenu(AK.Application_sharedApplication())
    if window_menu == nil do return

    add_menu_item(window_menu, {})
    for item in items do add_menu_item(window_menu, item)
}

// The command of the item chosen since the last call, 0 for none
menu_command :: proc() -> int {
    command := menu.chosen
    menu.chosen = 0
    return command
}

// A check mark before the item, its command's state as the app has it
set_menu_checked :: proc(command: int, checked: bool) {
    item := menu.items[command]
    if item == nil || menu.checked[command] == checked do return

    intrinsics.objc_send(nil, item, "setState:", NS.Integer(1 if checked else 0))
    menu.checked[command] = checked
}

// An open menu keeps the main loop stuck in should_close like a drag does, see live_resize_frames. A timer
// that only runs in the menu's loop draws the frames meanwhile, a drag's frames are left to the drag.
MENU_FRAME_S :: 0.016

start_menu_frames :: proc() {
    timer := intrinsics.objc_send(
        ^NS.Timer,
        NS.Timer,
        "timerWithTimeInterval:target:selector:userInfo:repeats:",
        NS.TimeInterval(MENU_FRAME_S),
        menu_target(),
        intrinsics.objc_find_selector("menuFrame:"),
        NS.id(nil),
        NS.BOOL(true),
    )
    NS.RunLoop_addTimer(NS.RunLoop_mainRunLoop(), timer, AK.EventTrackingRunLoopMode)
}

main_menu :: proc() -> ^AK.Menu {
    return AK.Application_mainMenu(AK.Application_sharedApplication())
}

// Made here, released by the caller once what it went into keeps its own
ns_string :: proc(text: cstring) -> ^NS.String {
    return NS.String_initWithCString_encoding(NS.alloc(NS.String), text, NS.UTF8StringEncoding)
}

// At index, at the end for -1. The menu keeps the item, the Input menu's are made again each time it opens.
add_menu_item :: proc(to: ^AK.Menu, item: MenuItem, index: NS.Integer = -1) {
    made: ^AK.MenuItem
    if item.title == nil {
        made = AK.MenuItem_separatorItem()
        made->retain()
    } else {
        title, key := ns_string(item.title), ns_string(item.key if item.key != nil else "")
        defer title->release()
        defer key->release()

        made = AK.MenuItem_initWithTitle(NS.alloc(AK.MenuItem), title, nil, key)

        // Without an action the menu greys it out
        if item.command > 0 do attach_item(made, item.command)
    }

    if index < 0 do AK.Menu_addItem(to, made)
    else do AK.Menu_insertItem(to, made, index)

    made->release()
}

attach_item :: proc(item: ^AK.MenuItem, command: int) {
    assert(command > 0 && command < MAX_MENU_COMMANDS)

    AK.MenuItem_setTarget(item, auto_cast menu_target())
    AK.MenuItem_setAction(item, intrinsics.objc_find_selector("menuChosen:"))
    AK.MenuItem_setTag(item, NS.Integer(command))
    menu.items[command] = item
    menu.checked[command] = false
}

// An object of a class made here at run time, one method keeps the chosen item's tag, the other is the
// timer's of start_menu_frames
menu_target :: proc() -> ^NS.Object {
    if menu.target != nil do return menu.target

    chosen :: proc "c" (self: NS.id, selector: NS.SEL, sender: ^AK.MenuItem) {
        menu.chosen = int(AK.MenuItem_tag(sender))
    }
    frame :: proc "c" (self: NS.id, selector: NS.SEL, timer: ^NS.Timer) {
        if live_resize.frame == nil || !live_resize.polling || live_resize.resizing do return
        if sdl.GetTicks() - live_resize.drag_tick < DRAG_TIMER_MS do return

        draw_from_os_loop()
    }

    class := ObjC.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "StrobieMenuTarget", 0)
    ObjC.class_addMethod(class, intrinsics.objc_find_selector("menuChosen:"), auto_cast chosen, "v@:@")
    ObjC.class_addMethod(class, intrinsics.objc_find_selector("menuFrame:"), auto_cast frame, "v@:@")
    ObjC.objc_registerClassPair(class)

    menu.target = intrinsics.objc_send(^NS.Object, cast(^NS.Object)ObjC.class_createInstance(class, 0), "init")
    return menu.target
}

// The delegate of the menus with an opening, made like menu_target. It calls it as the menu opens. Asked for
// a key equivalent it says there's none without filling the menu, it would otherwise be filled on keys.
menu_delegate :: proc() -> ^NS.Object {
    if menu.delegate != nil do return menu.delegate

    needs_update :: proc "c" (self: NS.id, selector: NS.SEL, opened: ^AK.Menu) {
        context = menu.ctx
        for which in 0 ..< menu.count {
            opening := menu.openings[which]
            if menu.menus[which] == opened && opening.callback != nil do opening.callback(opening.data)
        }
    }
    has_key_equivalent :: proc "c" (
        self: NS.id,
        selector: NS.SEL,
        opened: ^AK.Menu,
        event: NS.id,
        target: ^NS.id,
        action: ^NS.SEL,
    ) -> bool {
        return false
    }

    class := ObjC.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "StrobieMenuDelegate", 0)
    ObjC.class_addMethod(class, intrinsics.objc_find_selector("menuNeedsUpdate:"), auto_cast needs_update, "v@:@")
    ObjC.class_addMethod(
        class,
        intrinsics.objc_find_selector("menuHasKeyEquivalent:forEvent:target:action:"),
        auto_cast has_key_equivalent,
        "B@:@@^@^:",
    )
    ObjC.objc_registerClassPair(class)

    menu.delegate = intrinsics.objc_send(^NS.Object, cast(^NS.Object)ObjC.class_createInstance(class, 0), "init")
    return menu.delegate
}
