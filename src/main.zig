const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");
const terminal_mod = @import("terminal.zig");
const js_mod = @import("js.zig");
const perf_mod = @import("perf.zig");
const display_mod = @import("display.zig");
const node_mod = @import("node.zig");
const bridge_mod = @import("bridge.zig");
const wm = @import("wm.zig");

pub fn main() !void {
    // --- Raylib init ---
    rl.setConfigFlags(rl.FLAG_MSAA_4X_HINT | rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.initWindow(constants.WINDOW_W, constants.WINDOW_H, "MiOS");
    defer rl.closeWindow();
    rl.setTargetFPS(constants.TARGET_FPS);
    rl.c.SetExitKey(0);

    const font = rl.getFontDefault();
    const allocator = std.heap.page_allocator;

    // --- Window manager ---
    var win_mgr = wm.WindowManager{};
    win_mgr.init();

    // --- Local terminal ---
    var term = terminal_mod.Terminal{};
    term.init(100, 30, 14);
    defer term.deinit();
    term.visible = true;
    term.focused = true;
    const local_win = win_mgr.createWindow(&term, .local, "Terminal", 50, 50) orelse 0;
    win_mgr.focused = local_win;

    // --- JavaScript runtime ---
    var js: js_mod.JsRuntime = .{};
    js.init(&term);
    defer js.deinit();

    // --- Node manager (bridge thread) ---
    var nodes = node_mod.NodeManager{};
    nodes.start();
    defer nodes.stop();
    js.node_mgr = &nodes;

    // --- Performance monitor ---
    var perf = perf_mod.PerfTimers{ .js = &js };

    // Auto-launch shell.js
    var shell_started = false;

    // Display focus (for gfx windows, separate from terminal windows)
    var focused_display: ?usize = null;

    while (!rl.windowShouldClose()) {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        // Drain JS output to terminal
        js.drainOutput();

        // --- Node manager: process mount results ---
        while (nodes.popMountResult()) |result| {
            if (result.disconnected) {
                // TODO: close terminal window for this node
                term.write("\x1b[1;31mNode disconnected\x1b[0m\r\n");
            } else if (result.success) {
                const rt = allocator.create(terminal_mod.Terminal) catch continue;
                rt.* = .{};
                rt.init(80, 24, 14);
                rt.visible = true;
                rt.focused = false;

                // Build title from identity
                var title_buf: [48]u8 = .{0} ** 48;
                const ident = result.identity[0..result.identity_len];
                _ = std.fmt.bufPrint(&title_buf, "{s}", .{ident}) catch {};

                const offset: f32 = @floatFromInt(result.slot);
                const win_idx = win_mgr.createWindow(rt, .{ .remote = result.slot }, &title_buf, 250 + offset * 30, 50 + offset * 30);

                if (win_idx) |wi| {
                    // Welcome message
                    var buf: [256]u8 = undefined;
                    const welcome = std.fmt.bufPrint(&buf, "\x1b[1;32mConnected to node {d} ({s})\x1b[0m\r\n", .{ result.node_id, ident }) catch "";
                    rt.write(welcome);

                    // Focus the new window
                    win_mgr.focused = wi;
                    term.focused = false;
                }

                // Notify local terminal
                const node = nodes.nodes[result.slot];
                var nbuf: [256]u8 = undefined;
                const notify = std.fmt.bufPrint(&nbuf, "\x1b[1;32mMounted {s} — console=0x{x}\x1b[0m\r\n", .{
                    ident, node.console_remote_id,
                }) catch "";
                term.write(notify);
            } else {
                term.write("\x1b[1;31mMount failed\x1b[0m\r\n");
            }
        }

        // --- Node manager: process inbound messages ---
        while (nodes.inbound.pop()) |routed| {
            const idx = routed.node_idx;
            const node = &nodes.nodes[idx];

            if (routed.msg.dest == node.console_actor_id and
                routed.msg.msg_type == bridge_mod.MSG.CONSOLE_WRITE)
            {
                // Find the terminal window for this node
                for (&win_mgr.windows) |*w| {
                    if (!w.active) continue;
                    switch (w.kind) {
                        .remote => |ni| {
                            if (ni == idx) {
                                if (w.term) |t| {
                                    if (routed.msg.payload.len > 0) {
                                        t.write(routed.msg.payload);
                                    }
                                }
                            }
                        },
                        else => {},
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

        // --- Input ---
        const mouse = rl.c.GetMousePosition();
        const hit = win_mgr.hitTest(mouse.x, mouse.y);

        // Resize cursor
        if (hit) |h| {
            if (h.zone == .resize and win_mgr.drag_target == .none) {
                rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_RESIZE_NWSE);
            } else {
                rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_DEFAULT);
            }
        } else if (win_mgr.drag_target == .resize) {
            rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_RESIZE_NWSE);
        } else {
            rl.c.SetMouseCursor(rl.c.MOUSE_CURSOR_DEFAULT);
        }

        if (rl.isKeyPressed(rl.c.KEY_F11)) rl.c.ToggleBorderlessWindowed();

        // Backtick: toggle local terminal
        if (rl.isKeyPressed(rl.c.KEY_GRAVE)) {
            term.visible = !term.visible;
            if (term.visible) {
                win_mgr.focused = local_win;
                win_mgr.bringToFront(local_win);
                focused_display = null;
            }
        }

        // --- Mouse click ---
        if (rl.c.IsMouseButtonPressed(rl.c.MOUSE_BUTTON_LEFT)) {
            // Display close button
            if (js.display_mgr.hitTestCloseBtn(mouse.x, mouse.y)) |idx| {
                js.display_mgr.displays[idx].active = false;
                js.c_flags[1] = 1;
                focused_display = null;
                win_mgr.focused = local_win;
            }
            // Terminal windows (unified)
            else if (hit) |h| {
                win_mgr.focused = h.idx;
                win_mgr.bringToFront(h.idx);
                focused_display = null;

                // Update Terminal.focused flags
                for (&win_mgr.windows, 0..) |*w, i| {
                    if (w.term) |t| t.focused = (i == h.idx);
                }

                switch (h.zone) {
                    .title => {
                        win_mgr.drag_target = .title;
                        win_mgr.drag_window = h.idx;
                        win_mgr.drag_offset_x = mouse.x - win_mgr.windows[h.idx].x;
                        win_mgr.drag_offset_y = mouse.y - win_mgr.windows[h.idx].y;
                    },
                    .resize => {
                        win_mgr.drag_target = .resize;
                        win_mgr.drag_window = h.idx;
                        const t = win_mgr.windows[h.idx].term orelse unreachable;
                        win_mgr.resize_start_w = @floatFromInt(t.render_tex.texture.width);
                        win_mgr.resize_start_h = @floatFromInt(t.render_tex.texture.height);
                        win_mgr.resize_start_mx = mouse.x;
                        win_mgr.resize_start_my = mouse.y;
                    },
                    .content => {},
                }
            }
            // Display windows
            else if (js.display_mgr.hitTestTitleBar(mouse.x, mouse.y)) |idx| {
                js.display_mgr.dragging = @intCast(idx);
                js.display_mgr.drag_offset_x = mouse.x - js.display_mgr.displays[idx].screen_x;
                js.display_mgr.drag_offset_y = mouse.y - js.display_mgr.displays[idx].screen_y;
                js.display_mgr.bringToFront(@intCast(idx));
                focused_display = idx;
                win_mgr.focused = null;
                for (&win_mgr.windows) |*w| if (w.term) |t| { t.focused = false; };
                win_mgr.drag_target = .display;
            } else if (js.display_mgr.hitTestContent(mouse.x, mouse.y)) |idx| {
                js.display_mgr.bringToFront(@intCast(idx));
                focused_display = idx;
                win_mgr.focused = null;
                for (&win_mgr.windows) |*w| if (w.term) |t| { t.focused = false; };
            }
            // Empty space → focus local terminal
            else {
                win_mgr.focused = local_win;
                win_mgr.bringToFront(local_win);
                focused_display = null;
                for (&win_mgr.windows, 0..) |*w, i| {
                    if (w.term) |t| t.focused = (i == local_win);
                }
            }
        }

        // Drag update
        if (rl.c.IsMouseButtonDown(rl.c.MOUSE_BUTTON_LEFT)) {
            switch (win_mgr.drag_target) {
                .title => {
                    win_mgr.windows[win_mgr.drag_window].x = mouse.x - win_mgr.drag_offset_x;
                    win_mgr.windows[win_mgr.drag_window].y = mouse.y - win_mgr.drag_offset_y;
                },
                .resize => {
                    const new_w = win_mgr.resize_start_w + (mouse.x - win_mgr.resize_start_mx);
                    const new_h = win_mgr.resize_start_h + (mouse.y - win_mgr.resize_start_my);
                    if (win_mgr.windows[win_mgr.drag_window].term) |t| {
                        const new_cols: u16 = @intFromFloat(@max(10, new_w / t.cell_w));
                        const new_rows: u16 = @intFromFloat(@max(4, new_h / t.cell_h));
                        t.resize(new_cols, new_rows);
                    }
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

        if (rl.c.IsMouseButtonReleased(rl.c.MOUSE_BUTTON_LEFT)) {
            win_mgr.drag_target = .none;
            js.display_mgr.dragging = null;
        }

        // --- Keyboard routing ---
        if (win_mgr.focused) |fi| {
            const w = &win_mgr.windows[fi];
            switch (w.kind) {
                .local => {
                    // Local terminal — keyboard goes to JS runtime
                    if (rl.c.IsKeyDown(rl.c.KEY_LEFT_CONTROL) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_CONTROL)) {
                        if (rl.isKeyPressed(rl.c.KEY_C)) js.c_flags[1] = 1;
                    }
                    term.handleInputNoScroll();
                    term.update(rl.getFrameTime());
                },
                .remote => |node_idx| {
                    // Remote terminal — keyboard sends to remote shell
                    if (w.term) |t| {
                        // Typed characters
                        while (true) {
                            const ch = rl.c.GetCharPressed();
                            if (ch == 0) break;
                            if (ch >= 32 and ch < 127 and w.input_len < w.input_buf.len - 1) {
                                w.input_buf[w.input_len] = @intCast(ch);
                                w.input_len += 1;
                                var echo: [1]u8 = .{@intCast(ch)};
                                t.write(&echo);
                            }
                        }

                        if (rl.isKeyPressed(rl.c.KEY_ENTER)) {
                            t.write("\r\n");
                            const node = &nodes.nodes[node_idx];
                            if (node.console_remote_id != 0) {
                                // Send even if empty — shell needs it for a new prompt
                                const payload = if (w.input_len > 0) w.input_buf[0..w.input_len] else " ";
                                nodes.sendTo(node_idx, node.console_remote_id, 100, payload);
                            }
                            w.input_len = 0;
                        }

                        if (rl.isKeyPressed(rl.c.KEY_BACKSPACE) or rl.c.IsKeyPressedRepeat(rl.c.KEY_BACKSPACE)) {
                            if (w.input_len > 0) {
                                w.input_len -= 1;
                                t.write("\x08 \x08");
                            }
                        }

                        t.update(rl.getFrameTime());
                    }
                },
            }
        } else {
            perf.handleInput();
        }

        // Scroll — goes to whatever window the mouse is over
        if (win_mgr.mouseOverAny(mouse.x, mouse.y)) |wi| {
            if (win_mgr.windows[wi].term) |t| t.handleScroll();
        }

        // --- Render ---
        perf.lapStart();
        win_mgr.renderTextures();
        perf.lapEnd(perf_mod.TERM);

        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        js.display_mgr.processAndRender();

        perf.lapStart();
        js.display_mgr.drawAll(focused_display);
        win_mgr.renderAll();
        perf.lapEnd(perf_mod.DISPLAY);

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
