#include <raylib.h>
#define RAYGUI_IMPLEMENTATION
#include "../../raygui/src/raygui.h"
#include "../../miniaudio/miniaudio.h"



#define SCREEN_WIDTH 1024
#define SCREEN_HEIGHT 768
#define SAMPLERATE 44100
#define SIZE 4096


typedef struct {
    Font font;
    float sliderValue;
} AppContext;

AppContext ctx = {};


void init_window(void) {
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Filter");
    SetTargetFPS(60);
    SetConfigFlags(FLAG_VSYNC_HINT | FLAG_WINDOW_HIGHDPI);
    ctx.font = LoadFontEx("./media/JetBrainsMono-Regular.ttf", 16, NULL, 0);

    ctx.sliderValue = 50.0f;

    GuiSetFont(ctx.font);
}

void cleanup(void) {
    CloseWindow();
    UnloadFont(ctx.font);
}

void draw_screen(void) {
    BeginDrawing();
    ClearBackground(BLACK);
    DrawTextEx(ctx.font, "free fonts included with raylib", (Vector2){250, 20}, 16, 1, LIGHTGRAY);


    GuiSlider((Rectangle){ 355, 400, 165, 20 }, "TEST", TextFormat("%2.2f", ctx.sliderValue), &ctx.sliderValue, -50, 100);

    EndDrawing();
}


int main() {
    init_window();
    while (!WindowShouldClose()) {
        draw_screen();
    }
    cleanup();
}
