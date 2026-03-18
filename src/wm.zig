const std = @import("std");
const rl = @import("rl.zig");
const terminal_mod = @import("terminal.zig");
const display_mod = @import("display.zig");

pub const TITLE_BAR_H = display_mod.TITLE_BAR_H;
const RESIZE_GRIP: f32 = 8;

pub const MAX_WINDOWS: usize = 12;

/// What happens when keyboard input goes to this window.
pub const WindowKind = union(enum) {
    /// Local terminal — keyboard goes to JS runtime
    local,
    /// Remote terminal — keyboard sends MSG_SHELL_INPUT to node
    remote: u8, // node index
};

/// A terminal window managed by the window manager.
pub const TermWindow = struct {
    active: bool = false,
    term: ?*terminal_mod.Terminal = null,
    kind: WindowKind = .local,
    x: f32 = 50,
    y: f32 = 50,
    title: [48:0]u8 = .{0} ** 48,

    // Remote terminal input buffer
    input_buf: [1024]u8 = undefined,
    input_len: usize = 0,
};

pub const DragTarget = enum { none, title, resize, display };

/// Unified window manager for all terminal windows.
pub const WindowManager = struct {
    windows: [MAX_WINDOWS]TermWindow = .{.{}} ** MAX_WINDOWS,

    // Focus
    focused: ?usize = null, // which window has keyboard focus

    // Drag state
    drag_target: DragTarget = .none,
    drag_window: usize = 0,
    drag_offset_x: f32 = 0,
    drag_offset_y: f32 = 0,
    resize_start_w: f32 = 0,
    resize_start_h: f32 = 0,
    resize_start_mx: f32 = 0,
    resize_start_my: f32 = 0,

    // Z-order: indices into windows[], last = topmost
    z_order: [MAX_WINDOWS]u8 = undefined,
    z_count: usize = 0,

    pub fn init(self: *WindowManager) void {
        for (&self.z_order, 0..) |*z, i| z.* = @intCast(i);
    }

    /// Create a terminal window. Returns the window index.
    pub fn createWindow(self: *WindowManager, term: *terminal_mod.Terminal, kind: WindowKind, title: []const u8, x: f32, y: f32) ?usize {
        for (&self.windows, 0..) |*w, i| {
            if (!w.active) {
                w.active = true;
                w.term = term;
                w.kind = kind;
                w.x = x;
                w.y = y;
                w.input_len = 0;
                const tl = @min(title.len, 47);
                @memcpy(w.title[0..tl], title[0..tl]);
                w.title[tl] = 0;
                self.bringToFront(i);
                return i;
            }
        }
        return null;
    }

    pub fn bringToFront(self: *WindowManager, idx: usize) void {
        // Find and remove from z_order
        var found = false;
        var write: usize = 0;
        for (0..self.z_count) |r| {
            if (self.z_order[r] == @as(u8, @intCast(idx))) {
                found = true;
                continue;
            }
            self.z_order[write] = self.z_order[r];
            write += 1;
        }
        if (!found and self.z_count < MAX_WINDOWS) {
            // New entry
            self.z_order[self.z_count] = @intCast(idx);
            self.z_count += 1;
        } else if (found) {
            self.z_order[write] = @intCast(idx);
            // z_count stays the same
        }
    }

    /// Hit test all windows (topmost first). Returns window index and hit zone.
    pub fn hitTest(self: *const WindowManager, mx: f32, my: f32) ?struct { idx: usize, zone: enum { title, content, resize } } {
        var i: usize = self.z_count;
        while (i > 0) {
            i -= 1;
            const idx = self.z_order[i];
            const w = self.windows[idx];
            if (!w.active) continue;
            const t = w.term orelse continue;
            const tw: f32 = @floatFromInt(t.render_tex.texture.width);
            const th: f32 = @floatFromInt(t.render_tex.texture.height);

            // Resize grip (check first — overlaps content corner)
            if (mx >= w.x + tw - RESIZE_GRIP and mx < w.x + tw + RESIZE_GRIP and
                my >= w.y + TITLE_BAR_H + th - RESIZE_GRIP and my < w.y + TITLE_BAR_H + th + RESIZE_GRIP)
            {
                return .{ .idx = idx, .zone = .resize };
            }

            // Title bar
            if (mx >= w.x and mx < w.x + tw and my >= w.y and my < w.y + TITLE_BAR_H) {
                return .{ .idx = idx, .zone = .title };
            }

            // Content
            if (mx >= w.x and mx < w.x + tw and my >= w.y + TITLE_BAR_H and my < w.y + TITLE_BAR_H + th) {
                return .{ .idx = idx, .zone = .content };
            }
        }
        return null;
    }

    /// Check if mouse is over any window (for scroll routing).
    pub fn mouseOverAny(self: *const WindowManager, mx: f32, my: f32) ?usize {
        return if (self.hitTest(mx, my)) |h| h.idx else null;
    }

    /// Render all terminal windows in z-order.
    pub fn renderAll(self: *const WindowManager) void {
        for (0..self.z_count) |zi| {
            const idx = self.z_order[zi];
            const w = self.windows[idx];
            if (!w.active) continue;
            const t = w.term orelse continue;
            if (!t.visible) continue;

            const tw: f32 = @floatFromInt(t.render_tex.texture.width);
            const th: f32 = @floatFromInt(t.render_tex.texture.height);
            const is_focused = if (self.focused) |f| f == idx else false;

            // Title bar
            const title_color = if (is_focused) rl.color(0, 120, 90, 240) else rl.color(0, 80, 60, 220);
            rl.c.DrawRectangleV(.{ .x = w.x, .y = w.y }, .{ .x = tw, .y = TITLE_BAR_H }, title_color);
            rl.c.DrawText(&w.title, @intFromFloat(w.x + 6), @intFromFloat(w.y + 4), 14, rl.color(0, 255, 180, 220));

            // Content
            t.draw(w.x, w.y + TITLE_BAR_H);

            // Border
            const border_color = if (is_focused) rl.color(0, 255, 180, 220) else rl.color(0, 255, 180, 80);
            rl.c.DrawRectangleLinesEx(.{ .x = w.x, .y = w.y, .width = tw, .height = TITLE_BAR_H + th }, 1, border_color);

            // Resize grip
            const gx = w.x + tw;
            const gy = w.y + TITLE_BAR_H + th;
            rl.c.DrawTriangle(
                .{ .x = gx, .y = gy - 12 },
                .{ .x = gx, .y = gy },
                .{ .x = gx - 12, .y = gy },
                rl.color(0, 255, 180, 100),
            );
        }
    }

    /// Pre-render all terminal textures (call before beginDrawing).
    pub fn renderTextures(self: *const WindowManager) void {
        for (self.windows) |w| {
            if (!w.active) continue;
            if (w.term) |t| t.render();
        }
    }
};
