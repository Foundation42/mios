const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");
const terminal_mod = @import("terminal.zig");
const js_mod = @import("js.zig");
const perf_mod = @import("perf.zig");

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

        // If shell exited, allow re-launch on next open
        if (shell_started and !js.isBusy() and term.visible) {
            shell_started = false;
            var shell_path_buf: [512]u8 = undefined;
            const shell_path = findScript("shell", &shell_path_buf);
            if (shell_path) |sp| {
                js.evalFile(sp);
                shell_started = true;
            }
        }

        // --- Input ---
        // F11: fullscreen toggle (always available)
        if (rl.isKeyPressed(rl.c.KEY_F11)) {
            rl.c.ToggleBorderlessWindowed();
        }

        if (term.focused) {
            // Ctrl+C: interrupt running JS program
            if (rl.c.IsKeyDown(rl.c.KEY_LEFT_CONTROL) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_CONTROL)) {
                if (rl.isKeyPressed(rl.c.KEY_C)) {
                    js.c_flags[1] = 1;
                }
            }
            term.handleInput();
            term.update(rl.getFrameTime());
        } else {
            // Terminal not focused — perf toggle
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
        js.display_mgr.drawAll();
        perf.lapEnd(perf_mod.DISPLAY);

        // Terminal — fill the window
        perf.lapStart();
        if (term.visible) {
            const term_tex_w: f32 = @floatFromInt(term.render_tex.texture.width);
            const term_tex_h: f32 = @floatFromInt(term.render_tex.texture.height);
            const screen_w: f32 = @floatFromInt(sw);
            const screen_h: f32 = @floatFromInt(sh);

            // Center the terminal
            const tx = (screen_w - term_tex_w) / 2;
            const ty = (screen_h - term_tex_h) / 2;
            term.draw(tx, ty);
        }

        perf.endFrame();
        perf.draw(font, sw, sh);
        rl.drawFPS(sw - 90, 10);
        perf.lapEnd(perf_mod.DRAW);

        rl.endDrawing();
    }
}

fn findScript(name: []const u8, buf: *[512]u8) ?[]const u8 {
    const p1 = std.fmt.bufPrint(buf, "scripts/{s}.js", .{name}) catch return null;
    if (std.fs.cwd().access(p1, .{})) |_| return p1 else |_| {}
    return null;
}
