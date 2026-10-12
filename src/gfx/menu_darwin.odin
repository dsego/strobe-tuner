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
import NS "core:sys/darwin/Foundation"

// The macOS menu bar, nothing on iOS. SDL makes the app menu and the Window menu when it starts, the app
// adds its own items to them and menus of its own between them. A chosen item's command is picked up once
// a frame with menu_command.
//
// SDL sees every key before the menu does, a key equivalent reaches the app's key handling too. Each item
// has Command in its key, and the plain keys the app handles skip while Command is down.

menu: struct {
    target:  ^NS.Object, // gets every item's action, see menu_target
    chosen:  int, // the last item chosen, 0 none
    items:   [MAX_MENU_COMMANDS]^NS.MenuItem, // by command, for set_menu_checked
    checked: [MAX_MENU_COMMANDS]bool,
}

// The items go into the app menu after its Settings…, SDL's Preferences… that macOS renames, found by its
// Command+, as the title may be either or another language's
add_app_menu_items :: proc(settings: int, items: []MenuItem) {
    when !IOS {
        app_menu := NS.MenuItem_submenu(NS.Menu_itemAtIndex(main_menu(), 0))
        comma := ns_string(",")
        index := NS.Integer(-1)
        for position in 0 ..< NS.Menu_numberOfItems(app_menu) {
            key := intrinsics.objc_send(^NS.String, NS.Menu_itemAtIndex(app_menu, position), "keyEquivalent")
            if NS.String_isEqualToString(key, comma) {
                index = position
                break
            }
        }
        if index < 0 do return

        settings_item := NS.Menu_itemAtIndex(app_menu, index)
        NS.MenuItem_setTitle(settings_item, ns_string("Settings…"))
        attach_item(settings_item, settings)

        for item, offset in items {
            NS.Menu_insertItem(app_menu, make_menu_item(item), index + 1 + NS.Integer(offset))
        }
    }
}

// A menu of its own, before the Window menu
add_menu :: proc(title: cstring, items: []MenuItem) {
    when !IOS {
        submenu := NS.Menu_initWithTitle(NS.Menu_alloc(), ns_string(title))
        for item in items do NS.Menu_addItem(submenu, make_menu_item(item))

        bar_item := NS.MenuItem_init(NS.MenuItem_alloc())
        NS.MenuItem_setSubmenu(bar_item, submenu)

        bar := main_menu()
        index := NS.Menu_indexOfItemWithSubmenu(bar, NS.Application_windowsMenu(NS.Application_sharedApplication()))
        if index < 0 do index = NS.Menu_numberOfItems(bar)

        NS.Menu_insertItem(bar, bar_item, index)
    }
}

// The items go at the end of the Window menu, after a separator
add_window_menu_items :: proc(items: []MenuItem) {
    when !IOS {
        window_menu := NS.Application_windowsMenu(NS.Application_sharedApplication())
        if window_menu == nil do return

        NS.Menu_addItem(window_menu, NS.MenuItem_separatorItem())
        for item in items do NS.Menu_addItem(window_menu, make_menu_item(item))
    }
}

// The command of the item chosen since the last call, 0 for none
menu_command :: proc() -> int {
    command := menu.chosen
    menu.chosen = 0
    return command
}

// A check mark before the item, its command's state as the app has it
set_menu_checked :: proc(command: int, checked: bool) {
    when !IOS {
        item := menu.items[command]
        if item == nil || menu.checked[command] == checked do return

        intrinsics.objc_send(nil, item, "setState:", NS.Integer(1 if checked else 0))
        menu.checked[command] = checked
    }
}

main_menu :: proc() -> ^NS.Menu {
    return NS.Application_mainMenu(NS.Application_sharedApplication())
}

ns_string :: proc(text: cstring) -> ^NS.String {
    return NS.String_initWithCString(NS.String_alloc(), text, .UTF8)
}

make_menu_item :: proc(item: MenuItem) -> ^NS.MenuItem {
    if item.title == nil do return NS.MenuItem_separatorItem()

    key: cstring = item.key if item.key != nil else ""
    made := NS.MenuItem_initWithTitle(NS.MenuItem_alloc(), ns_string(item.title), nil, ns_string(key))
    if item.shift do NS.MenuItem_setKeyEquivalentModifierMask(made, {.Command, .Shift})

    attach_item(made, item.command)
    return made
}

attach_item :: proc(item: ^NS.MenuItem, command: int) {
    assert(command > 0 && command < MAX_MENU_COMMANDS)

    NS.MenuItem_setTarget(item, menu_target())
    NS.MenuItem_setAction(item, intrinsics.objc_find_selector("menuChosen:"))
    NS.MenuItem_setTag(item, NS.Integer(command))
    menu.items[command] = item
}

// An object of a class made here at run time, its one method keeps the chosen item's tag
menu_target :: proc() -> ^NS.Object {
    if menu.target != nil do return menu.target

    chosen :: proc "c" (self: NS.id, selector: NS.SEL, sender: ^NS.MenuItem) {
        menu.chosen = int(NS.MenuItem_tag(sender))
    }

    class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "StrobieMenuTarget", 0)
    NS.class_addMethod(class, intrinsics.objc_find_selector("menuChosen:"), auto_cast chosen, "v@:@")
    NS.objc_registerClassPair(class)

    menu.target = intrinsics.objc_send(^NS.Object, cast(^NS.Object)NS.class_createInstance(class, 0), "init")
    return menu.target
}
