const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");
const terminal_mod = @import("terminal.zig");
const js_mod = @import("js.zig");
const perf_mod = @import("perf.zig");
const display_mod = @import("display.zig");

pub fn main() !void {
    // --- Raylib init ---
    rl.setConfigFlags(rl.FLAG_MSAA_4X_HINT | rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.initWindow(constants.WINDOW_W, constants.WINDOW_H, "MiOS");
    defer rl.closeWindow();
    rl.setTargetFPS(constants.TARGET_FPS);
    rl.c.SetExitKey(0); // ESC is for programs, not quitting

    const font = rl.getFontDefault();

    // --- Terminal ---
    var term = terminal_mod.Terminal{};
    term.init(100, 30, 14);
    defer term.deinit();
    term.visible = true;
    term.focused = true;

    // --- JavaScript runtime ---
    var js: js_mod.JsRuntime = .{};
    js.init(&term);
    defer js.deinit();

    // --- Performance monitor ---
    var perf = perf_mod.PerfTimers{ .js = &js };

    // Auto-launch shell.js
    var shell_started = false;

    // Terminal screen position (updated each frame)
    var term_x: f32 = 0;
    var term_y: f32 = 0;

    // Which display is focused (null = terminal or nothing)
    var focused_display: ?usize = null;

    while (!rl.windowShouldClose()) {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        // Drain JS output to terminal
        js.drainOutput();

        // Launch shell on first frame
        if (!shell_started) {
            shell_started = true;
            var shell_path_buf: [512]u8 = undefined;
            const shell_path = findScript("shell", &shell_path_buf);
            if (shell_path) |sp| {
                js.evalFile(sp);
            } else {
                term.write("\x1b[1;31mshell.js not found!\x1b[0m\r\n");
            }
        }

        // If shell exited, allow re-launch
        if (shell_started and !js.isBusy() and term.visible) {
            shell_started = false;
            var shell_path_buf: [512]u8 = undefined;
            const shell_path = findScript("shell", &shell_path_buf);
            if (shell_path) |sp| {
                js.evalFile(sp);
                shell_started = true;
            }
        }

        // --- Hit testing ---
        const mouse = rl.c.GetMousePosition();
        const mouse_over_term = term.visible and hitTestRect(
            mouse,
            term_x,
            term_y,
            @floatFromInt(term.render_tex.texture.width),
            @floatFromInt(term.render_tex.texture.height),
        );

        // --- Input ---
        // F11: fullscreen toggle (always available)
        if (rl.isKeyPressed(rl.c.KEY_F11)) {
            rl.c.ToggleBorderlessWindowed();
        }

        // Backtick: toggle terminal visibility
        if (rl.isKeyPressed(rl.c.KEY_GRAVE)) {
            term.visible = !term.visible;
            if (term.visible) {
                term.focused = true;
                focused_display = null;
            } else {
                term.focused = false;
            }
        }

        // --- Mouse click handling ---
        if (rl.c.IsMouseButtonPressed(rl.c.MOUSE_BUTTON_LEFT)) {
            // Check close button first (topmost window)
            if (js.display_mgr.hitTestCloseBtn(mouse.x, mouse.y)) |idx| {
                js.display_mgr.displays[idx].active = false;
                if (focused_display) |fd| {
                    if (fd == idx) {
                        focused_display = null;
                        term.focused = true;
                    }
                }
            }
            // Check title bar → start drag
            else if (js.display_mgr.hitTestTitleBar(mouse.x, mouse.y)) |idx| {
                js.display_mgr.dragging = @intCast(idx);
                js.display_mgr.drag_offset_x = mouse.x - js.display_mgr.displays[idx].screen_x;
                js.display_mgr.drag_offset_y = mouse.y - js.display_mgr.displays[idx].screen_y;
                js.display_mgr.bringToFront(@intCast(idx));
                focused_display = idx;
                term.focused = false;
            }
            // Check display content → focus window
            else if (js.display_mgr.hitTestContent(mouse.x, mouse.y)) |idx| {
                js.display_mgr.bringToFront(@intCast(idx));
                focused_display = idx;
                term.focused = false;
            }
            // Check terminal
            else if (mouse_over_term) {
                term.focused = true;
                focused_display = null;
            }
            // Click on empty space — focus terminal
            else {
                term.focused = true;
                focused_display = null;
            }
        }

        // Drag update
        if (rl.c.IsMouseButtonDown(rl.c.MOUSE_BUTTON_LEFT)) {
            if (js.display_mgr.dragging) |drag_id| {
                js.display_mgr.displays[drag_id].screen_x = mouse.x - js.display_mgr.drag_offset_x;
                js.display_mgr.displays[drag_id].screen_y = mouse.y - js.display_mgr.drag_offset_y;
            }
        }

        // Drag end
        if (rl.c.IsMouseButtonReleased(rl.c.MOUSE_BUTTON_LEFT)) {
            js.display_mgr.dragging = null;
        }

        // --- Keyboard routing ---
        if (term.focused) {
            // Ctrl+C: interrupt running JS program
            if (rl.c.IsKeyDown(rl.c.KEY_LEFT_CONTROL) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_CONTROL)) {
                if (rl.isKeyPressed(rl.c.KEY_C)) {
                    js.c_flags[1] = 1;
                }
            }

            // Terminal gets keyboard; scroll only when mouse is over it
            if (mouse_over_term) {
                term.handleInput();
            } else {
                term.handleInputNoScroll();
            }
            term.update(rl.getFrameTime());
        } else {
            // No terminal focus — perf toggle
            perf.handleInput();
        }

        // --- Render ---
        perf.lapStart();
        term.render();
        perf.lapEnd(perf_mod.TERM);

        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        // Display windows (JS gfx API)
        perf.lapStart();
        js.display_mgr.processAndRender();
        js.display_mgr.drawAll(focused_display);
        perf.lapEnd(perf_mod.DISPLAY);

        // Terminal
        perf.lapStart();
        if (term.visible) {
            const term_tex_w: f32 = @floatFromInt(term.render_tex.texture.width);
            const term_tex_h: f32 = @floatFromInt(term.render_tex.texture.height);
            const screen_w: f32 = @floatFromInt(sw);
            const screen_h: f32 = @floatFromInt(sh);

            // Center the terminal
            term_x = (screen_w - term_tex_w) / 2;
            term_y = (screen_h - term_tex_h) / 2;
            term.draw(term_x, term_y);
        }

        perf.endFrame();
        perf.draw(font, sw, sh);
        rl.drawFPS(sw - 90, 10);
        perf.lapEnd(perf_mod.DRAW);

        rl.endDrawing();
    }
}

/// Point-in-rectangle hit test
fn hitTestRect(p: rl.c.Vector2, x: f32, y: f32, w: f32, h: f32) bool {
    return p.x >= x and p.x < x + w and p.y >= y and p.y < y + h;
}

fn findScript(name: []const u8, buf: *[512]u8) ?[]const u8 {
    const p1 = std.fmt.bufPrint(buf, "scripts/{s}.js", .{name}) catch return null;
    if (std.fs.cwd().access(p1, .{})) |_| return p1 else |_| {}
    return null;
}
