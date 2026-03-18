const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");
const terminal_mod = @import("terminal.zig");
const js_mod = @import("js.zig");
const perf_mod = @import("perf.zig");
const display_mod = @import("display.zig");
const node_mod = @import("node.zig");
const bridge_mod = @import("bridge.zig");

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
    const allocator = std.heap.page_allocator;

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

    // --- Node manager (bridge thread) ---
    var nodes = node_mod.NodeManager{};
    nodes.start();
    defer nodes.stop();

    // Remote terminals (heap-allocated, one per mounted node)
    var remote_terms: [node_mod.MAX_NODES]?*terminal_mod.Terminal = .{null} ** node_mod.MAX_NODES;
    var remote_term_x: [node_mod.MAX_NODES]f32 = .{0} ** node_mod.MAX_NODES;
    var remote_term_y: [node_mod.MAX_NODES]f32 = .{0} ** node_mod.MAX_NODES;

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
    var resize_start_w: f32 = 0;
    var resize_start_h: f32 = 0;
    var resize_start_mx: f32 = 0;
    var resize_start_my: f32 = 0;

    // Expose node manager to JS runtime so JS can request mounts
    js.node_mgr = &nodes;

    while (!rl.windowShouldClose()) {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        // Drain JS output to terminal
        js.drainOutput();

        // --- Node manager: process mount results ---
        while (nodes.popMountResult()) |result| {
            if (result.disconnected) {
                if (remote_terms[result.slot]) |rt| {
                    rt.deinit();
                    allocator.destroy(rt);
                    remote_terms[result.slot] = null;
                }
                term.write("\x1b[1;31mNode disconnected\x1b[0m\r\n");
            } else if (result.success) {
                // Create terminal for this remote node
                const rt = allocator.create(terminal_mod.Terminal) catch continue;
                rt.* = .{};
                rt.init(80, 24, 14);
                rt.visible = true;
                rt.focused = false;
                remote_terms[result.slot] = rt;

                const offset: f32 = @floatFromInt(result.slot);
                remote_term_x[result.slot] = term_wx + 200 + offset * 30;
                remote_term_y[result.slot] = term_wy + 50 + offset * 30;

                // Welcome message in remote terminal
                const ident = result.identity[0..result.identity_len];
                var buf: [256]u8 = undefined;
                const welcome = std.fmt.bufPrint(&buf, "\x1b[1;32mConnected to node {d} ({s})\x1b[0m\r\n", .{ result.node_id, ident }) catch "";
                rt.write(welcome);

                // Notify local terminal
                var nbuf: [256]u8 = undefined;
                const notify = std.fmt.bufPrint(&nbuf, "\x1b[1;32mMounted {s} — terminal opened\x1b[0m\r\n", .{ident}) catch "";
                term.write(notify);
            } else {
                term.write("\x1b[1;31mMount failed\x1b[0m\r\n");
            }
        }

        // --- Node manager: process inbound messages ---
        while (nodes.inbound.pop()) |routed| {
            const idx = routed.node_idx;
            const node = &nodes.nodes[idx];

            // MSG_CONSOLE_WRITE to our console actor → write to remote terminal
            if (routed.msg.dest == node.console_actor_id and
                routed.msg.msg_type == bridge_mod.MSG.CONSOLE_WRITE)
            {
                if (remote_terms[idx]) |rt| {
                    if (routed.msg.payload.len > 0) {
                        rt.write(routed.msg.payload);
                    }
                }
            }
        }

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
            // Display content → focus
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
            if (rl.c.IsKeyDown(rl.c.KEY_LEFT_CONTROL) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_CONTROL)) {
                if (rl.isKeyPressed(rl.c.KEY_C)) {
                    js.c_flags[1] = 1;
                }
            }
            term.handleInputNoScroll();
            term.update(rl.getFrameTime());
        } else {
            perf.handleInput();
        }

        // Scroll goes to terminal whenever mouse is over it
        if (mouse_over_term_any) {
            term.handleScroll();
        }

        // --- Render ---
        perf.lapStart();
        term.render();
        for (remote_terms) |maybe_rt| {
            if (maybe_rt) |rt| rt.render();
        }
        perf.lapEnd(perf_mod.TERM);

        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        js.display_mgr.processAndRender();

        perf.lapStart();
        // Display windows
        js.display_mgr.drawAll(focused_display);
        // Local terminal
        drawTerminal(&term, term_wx, term_wy, "Terminal", term.focused);
        // Remote terminals
        for (remote_terms, 0..) |maybe_rt, i| {
            if (maybe_rt) |rt| {
                var title_buf: [48:0]u8 = .{0} ** 48;
                const node = nodes.nodes[i];
                const tl = std.fmt.bufPrint(&title_buf, "{s}", .{node.identity[0..node.identity_len]}) catch "";
                title_buf[tl.len] = 0;
                drawTerminal(rt, remote_term_x[i], remote_term_y[i], &title_buf, false);
            }
        }
        perf.lapEnd(perf_mod.DISPLAY);

        perf.endFrame();
        perf.draw(font, sw, sh);
        rl.drawFPS(sw - 90, 10);
        perf.lapEnd(perf_mod.DRAW);

        rl.endDrawing();
    }

    // Cleanup remote terminals
    for (&remote_terms) |*maybe_rt| {
        if (maybe_rt.*) |rt| {
            rt.deinit();
            allocator.destroy(rt);
            maybe_rt.* = null;
        }
    }
}

fn drawTerminal(t: *const terminal_mod.Terminal, wx: f32, wy: f32, title: [*:0]const u8, focused: bool) void {
    if (!t.visible) return;

    const tw: f32 = @floatFromInt(t.render_tex.texture.width);
    const th: f32 = @floatFromInt(t.render_tex.texture.height);
    const cy = wy + TITLE_BAR_H;

    const title_color = if (focused) rl.color(0, 120, 90, 240) else rl.color(0, 80, 60, 220);
    rl.c.DrawRectangleV(.{ .x = wx, .y = wy }, .{ .x = tw, .y = TITLE_BAR_H }, title_color);
    rl.c.DrawText(title, @intFromFloat(wx + 6), @intFromFloat(wy + 4), 14, rl.color(0, 255, 180, 220));

    t.draw(wx, cy);

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
