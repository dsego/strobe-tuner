package app

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"


load_ini :: proc(app_name: string) -> (ini.Map, bool) {

    // Load or create config directory in a standard location based on the OS
    dir_path := get_config_directory(app_name)
    {
        err := os.make_directory(dir_path)

        if err != os.ERROR_NONE && err != os.EEXIST {
            return nil, false
        }
    }

    // Load or create an ini file
    ini_path := filepath.join({dir_path, "config.ini"})
    defer delete(ini_path)

    if os.exists(ini_path) {
        fmt.println("Loading config from", ini_path)
    } else {
        fmt.println("No config file at", ini_path)
        return nil, false
    }

    ini_map, err, ok := ini.load_map_from_path(ini_path, allocator = context.allocator)

    if !ok {
        fmt.println("Failed to load config file", ini_path)
        return nil, false
    }

    return ini_map, true
}

get_config_directory :: proc(app_name: string) -> string {
    when ODIN_OS == .Windows {
        // Use %APPDATA% on Windows
        base_path := os.get_env("APPDATA")
        return filepath.join({base_path, app_name})
    } else when ODIN_OS == .Darwin {
        // macOS: ~/Library/Application Support
        home := os.get_env("HOME")
        return filepath.join({home, "Library", "Application Support", app_name})
    } else {
        // Linux/Unix: ~/.config or XDG_CONFIG_HOME
        config_home := os.get_env("XDG_CONFIG_HOME")
        if config_home == "" {
            home := os.get_env("HOME")
            config_home = filepath.join({home, ".config"})
        }
        return filepath.join({config_home, app_name})
    }
}
