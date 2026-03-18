const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");
const terminal_mod = @import("terminal.zig");
const js_mod = @import("js.zig");
const perf_mod = @import("perf.zig");
const display_mod = @import("display.zig");

const TITLE_BAR_H = display_mod.TITLE_BAR_H;
const RESIZE_GRIP: f32 = 6; // edge zone for resize

const DragTarget = enum { none, term_title, term_resize, display };

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

    // Terminal window position (top-left of title bar)
    var term_wx: f32 = 50;
    var term_wy: f32 = 50;


    // Which display is focused (null = terminal or nothing)
    var focused_display: ?usize = null;

    // Drag state
    var drag_target: DragTarget = .none;
    var drag_offset_x: f32 = 0;
    var drag_offset_y: f32 = 0;
    // For resize: initial window size and mouse pos at drag start
    var resize_start_w: f32 = 0;
    var resize_start_h: f32 = 0;
    var resize_start_mx: f32 = 0;
    var resize_start_my: f32 = 0;

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

        // --- Terminal geometry ---
        const term_tex_w: f32 = @floatFromInt(term.render_tex.texture.width);
        const term_tex_h: f32 = @floatFromInt(term.render_tex.texture.height);
        const term_content_y = term_wy + TITLE_BAR_H;
        const term_total_h = TITLE_BAR_H + term_tex_h;

        // --- Hit testing ---
        const mouse = rl.c.GetMousePosition();

        const mouse_over_term_title = term.visible and
            mouse.x >= term_wx and mouse.x < term_wx + term_tex_w and
            mouse.y >= term_wy and mouse.y < term_content_y;

        const mouse_over_term_content = term.visible and
            mouse.x >= term_wx and mouse.x < term_wx + term_tex_w and
            mouse.y >= term_content_y and mouse.y < term_content_y + term_tex_h;

        const mouse_over_term_resize = term.visible and
            mouse.x >= term_wx + term_tex_w - RESIZE_GRIP and mouse.x < term_wx + term_tex_w + RESIZE_GRIP and
            mouse.y >= term_wy + term_total_h - RESIZE_GRIP and mouse.y < term_wy + term_total_h + RESIZE_GRIP;

        const mouse_over_term_any = mouse_over_term_title or mouse_over_term_content or mouse_over_term_resize;

        // Set cursor shape for resize grip
        if (mouse_over_term_resize and drag_target == .none) {
            rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_RESIZE_NWSE);
        } else if (drag_target == .term_resize) {
            rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_RESIZE_NWSE);
        } else {
            rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_DEFAULT);
        }

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
            // Check display close button first
            if (js.display_mgr.hitTestCloseBtn(mouse.x, mouse.y)) |idx| {
                js.display_mgr.displays[idx].active = false;
                // Interrupt the JS program so it stops rendering to this display
                js.c_flags[1] = 1;
                if (focused_display) |fd| {
                    if (fd == idx) {
                        focused_display = null;
                        term.focused = true;
                    }
                }
            }
            // Terminal resize grip
            else if (mouse_over_term_resize) {
                drag_target = .term_resize;
                resize_start_w = term_tex_w;
                resize_start_h = term_tex_h;
                resize_start_mx = mouse.x;
                resize_start_my = mouse.y;
                term.focused = true;
                focused_display = null;
            }
            // Terminal title bar → drag
            else if (mouse_over_term_title) {
                drag_target = .term_title;
                drag_offset_x = mouse.x - term_wx;
                drag_offset_y = mouse.y - term_wy;
                term.focused = true;
                focused_display = null;
            }
            // Terminal content → focus
            else if (mouse_over_term_content) {
                term.focused = true;
                focused_display = null;
            }
            // Display title bar → drag
            else if (js.display_mgr.hitTestTitleBar(mouse.x, mouse.y)) |idx| {
                js.display_mgr.dragging = @intCast(idx);
                js.display_mgr.drag_offset_x = mouse.x - js.display_mgr.displays[idx].screen_x;
                js.display_mgr.drag_offset_y = mouse.y - js.display_mgr.displays[idx].screen_y;
                js.display_mgr.bringToFront(@intCast(idx));
                focused_display = idx;
                term.focused = false;
                drag_target = .display;
            }
            // Display content → focus + bring to front
            else if (js.display_mgr.hitTestContent(mouse.x, mouse.y)) |idx| {
                js.display_mgr.bringToFront(@intCast(idx));
                focused_display = idx;
                term.focused = false;
            }
            // Empty space → focus terminal
            else {
                term.focused = true;
                focused_display = null;
            }
        }

        // Drag update
        if (rl.c.IsMouseButtonDown(rl.c.MOUSE_BUTTON_LEFT)) {
            switch (drag_target) {
                .term_title => {
                    term_wx = mouse.x - drag_offset_x;
                    term_wy = mouse.y - drag_offset_y;
                },
                .term_resize => {
                    const new_w = resize_start_w + (mouse.x - resize_start_mx);
                    const new_h = resize_start_h + (mouse.y - resize_start_my);
                    const new_cols: u16 = @intFromFloat(@max(10, new_w / term.cell_w));
                    const new_rows: u16 = @intFromFloat(@max(4, new_h / term.cell_h));
                    term.resize(new_cols, new_rows);
                },
                .display => {
                    if (js.display_mgr.dragging) |drag_id| {
                        js.display_mgr.displays[drag_id].screen_x = mouse.x - js.display_mgr.drag_offset_x;
                        js.display_mgr.displays[drag_id].screen_y = mouse.y - js.display_mgr.drag_offset_y;
                    }
                },
                .none => {},
            }
        }

        // Drag end
        if (rl.c.IsMouseButtonReleased(rl.c.MOUSE_BUTTON_LEFT)) {
            drag_target = .none;
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

            term.handleInputNoScroll();
            term.update(rl.getFrameTime());
        } else {
            // No terminal focus — perf toggle
            perf.handleInput();
        }

        // Scroll goes to terminal whenever mouse is over it, regardless of focus
        if (mouse_over_term_any) {
            term.handleScroll();
        }

        // --- Render ---
        perf.lapStart();
        term.render();
        perf.lapEnd(perf_mod.TERM);

        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        // Process gfx commands (must happen before drawing)
        js.display_mgr.processAndRender();

        // Draw in z-order: unfocused layer first, focused layer on top
        perf.lapStart();
        if (term.focused) {
            // Display windows behind, terminal on top
            js.display_mgr.drawAll(focused_display);
            drawTerminal(&term, term_wx, term_wy, true);
        } else {
            // Terminal behind, display windows on top
            drawTerminal(&term, term_wx, term_wy, false);
            js.display_mgr.drawAll(focused_display);
        }
        perf.lapEnd(perf_mod.DISPLAY);

        perf.endFrame();
        perf.draw(font, sw, sh);
        rl.drawFPS(sw - 90, 10);
        perf.lapEnd(perf_mod.DRAW);

        rl.endDrawing();
    }
}

fn drawTerminal(term: *const terminal_mod.Terminal, wx: f32, wy: f32, focused: bool) void {
    if (!term.visible) return;

    const tw: f32 = @floatFromInt(term.render_tex.texture.width);
    const th: f32 = @floatFromInt(term.render_tex.texture.height);
    const cy = wy + TITLE_BAR_H;

    // Title bar
    const title_color = if (focused) rl.color(0, 120, 90, 240) else rl.color(0, 80, 60, 220);
    rl.c.DrawRectangleV(.{ .x = wx, .y = wy }, .{ .x = tw, .y = TITLE_BAR_H }, title_color);

    // Debug: show scroll state in title bar
    var title_buf: [128:0]u8 = undefined;
    const wheel = rl.c.GetMouseWheelMove();
    const tl = std.fmt.bufPrint(&title_buf, "Terminal {d}x{d}  sb={d} off={d} wh={d:.1}", .{ term.cols, term.rows, term.scrollback_count, term.scroll_offset, wheel }) catch "";
    title_buf[tl.len] = 0;
    rl.c.DrawText(&title_buf, @intFromFloat(wx + 6), @intFromFloat(wy + 4), 14, rl.color(0, 255, 180, 220));

    // Content
    term.draw(wx, cy);

    // Border
    const border_color = if (focused) rl.color(0, 255, 180, 220) else rl.color(0, 255, 180, 80);
    rl.c.DrawRectangleLinesEx(.{ .x = wx, .y = wy, .width = tw, .height = TITLE_BAR_H + th }, 1, border_color);

    // Resize grip
    const gx = wx + tw;
    const gy = wy + TITLE_BAR_H + th;
    rl.c.DrawTriangle(
        .{ .x = gx, .y = gy - 12 },
        .{ .x = gx, .y = gy },
        .{ .x = gx - 12, .y = gy },
        rl.color(0, 255, 180, 100),
    );
}

fn findScript(name: []const u8, buf: *[512]u8) ?[]const u8 {
    const p1 = std.fmt.bufPrint(buf, "scripts/{s}.js", .{name}) catch return null;
    if (std.fs.cwd().access(p1, .{})) |_| return p1 else |_| {}
    return null;
}
