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

package com.dsego.strobetuner;

import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;

import org.libsdl.app.SDLActivity;

// SDL's activity runs the app. Odin emits a C main that starts its runtime and calls the app's main,
// SDL calls that instead of SDL_main.
public class StrobieActivity extends SDLActivity {
    // Sent by allow_microphone in src/audio/capture_android.odin
    private static final int COMMAND_OPEN_APP_SETTINGS = COMMAND_USER;

    @Override
    protected String getMainFunction() {
        return "main";
    }

    @Override
    protected boolean onUnhandledMessage(int command, Object param) {
        if (command == COMMAND_OPEN_APP_SETTINGS) {
            Uri app = Uri.fromParts("package", getPackageName(), null);
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, app));
            return true;
        }
        return super.onUnhandledMessage(command, param);
    }
}
