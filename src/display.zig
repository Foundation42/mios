const std = @import("std");
const rl = @import("rl.zig");

pub const MAX_DISPLAYS: usize = 4;

// ---------------------------------------------------------------
// Color helper
// ---------------------------------------------------------------

pub const Color4 = extern struct { r: u8, g: u8, b: u8, a: u8 };

pub fn toRlColor(c: Color4) rl.c.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub fn fromU32(v: u32) Color4 {
    return .{
        .r = @truncate(v),
        .g = @truncate(v >> 8),
        .b = @truncate(v >> 16),
        .a = @truncate(v >> 24),
    };
}

// ---------------------------------------------------------------
// Draw command — compact, flows through the ring
// ---------------------------------------------------------------

pub const CmdTag = enum(u8) {
    // Control
    begin_frame, // starts drawing to RenderTexture
    end_frame, // present: stops drawing
    create, // create/resize display (w,h in f[0],f[1])
    destroy,
    move_display, // screen position (x,y in f[0],f[1])
    set_camera, // dist, pitch, yaw in f[0..2]

    // 2D primitives
    clear,
    line,
    rect,
    rect_lines,
    circle,
    triangle,
    text,
    pixel,

    // 3D mode
    begin3d, // enter 3D mode with camera
    end3d, // back to 2D
    line3d,
    cube3d,
    triangle3d,
    cube3d_solid,
};

pub const DrawCmd = struct {
    tag: CmdTag,
    display_id: u8 = 0,
    color: Color4 = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    f: [12]f32 = .{0} ** 12,
    text_buf: [64]u8 = .{0} ** 64,
    text_len: u8 = 0,
};

// ---------------------------------------------------------------
// Command ring buffer — producer/consumer, grows if needed
// ---------------------------------------------------------------

const INITIAL_RING_SIZE: usize = 2048;

pub const CmdRing = struct {
    buf: []DrawCmd,
    capacity: usize = 0,
    head: usize = 0, // write position (producer)
    tail: usize = 0, // read position (consumer)
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CmdRing {
        const buf = allocator.alloc(DrawCmd, INITIAL_RING_SIZE) catch {
            return .{
                .buf = &.{},
                .capacity = 0,
                .allocator = allocator,
            };
        };
        return .{
            .buf = buf,
            .capacity = INITIAL_RING_SIZE,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CmdRing) void {
        if (self.capacity > 0) {
            self.allocator.free(self.buf);
            self.capacity = 0;
        }
    }

    /// Push a command (producer/worker thread)
    pub fn push(self: *CmdRing, cmd: DrawCmd) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const next = (self.head + 1) % self.capacity;
        if (next == self.tail) {
            // Ring full — grow
            self.grow();
        }
        self.buf[self.head] = cmd;
        self.head = (self.head + 1) % self.capacity;
    }

    /// Pop a command (consumer/main thread). Returns null if empty.
    pub fn pop(self: *CmdRing) ?DrawCmd {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tail == self.head) return null;
        const cmd = self.buf[self.tail];
        self.tail = (self.tail + 1) % self.capacity;
        return cmd;
    }

    fn grow(self: *CmdRing) void {
        const new_cap = if (self.capacity == 0) INITIAL_RING_SIZE else self.capacity * 2;
        const new_buf = self.allocator.alloc(DrawCmd, new_cap) catch return;

        // Linearize existing data
        if (self.capacity > 0) {
            var i: usize = 0;
            var pos = self.tail;
            while (pos != self.head) {
                new_buf[i] = self.buf[pos];
                pos = (pos + 1) % self.capacity;
                i += 1;
            }
            self.allocator.free(self.buf);
            self.tail = 0;
            self.head = i;
        }
        self.buf = new_buf;
        self.capacity = new_cap;
    }
};

// ---------------------------------------------------------------
// Display — just the render target and camera, no command storage
// ---------------------------------------------------------------

pub const TITLE_BAR_H: f32 = 22;
const TITLE_COLOR = rl.color(0, 80, 60, 220);
const TITLE_FOCUSED_COLOR = rl.color(0, 120, 90, 240);
const TITLE_TEXT_COLOR = rl.color(0, 255, 180, 220);
const BORDER_COLOR = rl.color(0, 255, 180, 80);
const CLOSE_BTN_PAD: f32 = 4;

pub const Display = struct {
    active: bool = false,
    tex_front: rl.c.RenderTexture2D = undefined, // blitted to screen
    tex_back: rl.c.RenderTexture2D = undefined, // being rendered into
    width: u16 = 320,
    height: u16 = 240,
    tex_loaded: bool = false,
    needs_resize: bool = false,
    screen_x: f32 = 10, // window left (including chrome)
    screen_y: f32 = 10, // window top (title bar top)
    in_frame: bool = false, // between begin/end
    in_3d: bool = false, // between begin3d/end3d
    has_good_frame: bool = false, // the RenderTexture contains a fully rendered frame
    title: [32]u8 = .{0} ** 32,
    title_len: u8 = 0,

    /// Content top-left (below title bar)
    pub fn contentY(self: *const Display) f32 {
        return self.screen_y + TITLE_BAR_H;
    }
};

// ---------------------------------------------------------------
// Display Manager — thin, processes commands from ring each frame
// ---------------------------------------------------------------

pub const DisplayManager = struct {
    displays: [MAX_DISPLAYS]Display = .{.{}} ** MAX_DISPLAYS,
    ring: CmdRing,

    // Z-order: indices into displays[], last = topmost
    draw_order: [MAX_DISPLAYS]u8 = .{ 0, 1, 2, 3 },

    // Drag state (main thread only)
    dragging: ?u8 = null,
    drag_offset_x: f32 = 0,
    drag_offset_y: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) DisplayManager {
        return .{ .ring = CmdRing.init(allocator) };
    }

    pub fn deinit(self: *DisplayManager) void {
        for (&self.displays) |*d| {
            if (d.tex_loaded) {
                rl.c.UnloadRenderTexture(d.tex_front);
                rl.c.UnloadRenderTexture(d.tex_back);
                d.tex_loaded = false;
            }
        }
        self.ring.deinit();
    }

    /// Process all pending commands from the ring. Call from main thread each frame.
    pub fn processAndRender(self: *DisplayManager) void {
        while (self.ring.pop()) |cmd| {
            const id = cmd.display_id;
            if (id >= MAX_DISPLAYS) continue;
            var d = &self.displays[id];

            switch (cmd.tag) {
                .create => {
                    d.active = true;
                    d.width = @intFromFloat(cmd.f[0]);
                    d.height = @intFromFloat(cmd.f[1]);
                    d.needs_resize = true;
                    // Default title
                    const title = std.fmt.bufPrint(&d.title, "Display {d}", .{id}) catch "";
                    d.title_len = @intCast(title.len);
                    self.bringToFront(@intCast(id));
                },
                .destroy => {
                    if (d.in_frame) {
                        rl.c.EndTextureMode();
                        d.in_frame = false;
                    }
                    d.active = false;
                    if (self.dragging) |drag_id| {
                        if (drag_id == id) self.dragging = null;
                    }
                },
                .move_display => {
                    // JS coordinates = content origin; adjust for title bar
                    // Skip if currently being dragged
                    if (self.dragging) |drag_id| {
                        if (drag_id == id) continue;
                    }
                    d.screen_x = cmd.f[0];
                    d.screen_y = cmd.f[1] - TITLE_BAR_H;
                },
                .set_camera => {
                    // Legacy — camera now set via begin3d
                },
                .begin_frame => {
                    if (!d.active) continue;
                    self.ensureTexture(d);
                    rl.c.BeginTextureMode(d.tex_back);
                    rl.c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
                    d.in_frame = true;
                },
                .end_frame => {
                    if (d.in_3d) {
                        rl.c.EndMode3D();
                        d.in_3d = false;
                    }
                    if (d.in_frame) {
                        rl.c.EndTextureMode();
                        d.in_frame = false;
                        // Swap: back becomes front (complete frame ready to blit)
                        const tmp = d.tex_front;
                        d.tex_front = d.tex_back;
                        d.tex_back = tmp;
                        d.has_good_frame = true;
                    }
                },
                // 2D primitives
                .clear => {
                    if (!d.in_frame) continue;
                    rl.c.ClearBackground(toRlColor(cmd.color));
                },
                .line => {
                    if (!d.in_frame) continue;
                    rl.c.DrawLineEx(
                        .{ .x = cmd.f[0], .y = cmd.f[1] },
                        .{ .x = cmd.f[2], .y = cmd.f[3] },
                        if (cmd.f[4] > 0) cmd.f[4] else 1.0,
                        toRlColor(cmd.color),
                    );
                },
                .rect => {
                    if (!d.in_frame) continue;
                    rl.c.DrawRectangleV(
                        .{ .x = cmd.f[0], .y = cmd.f[1] },
                        .{ .x = cmd.f[2], .y = cmd.f[3] },
                        toRlColor(cmd.color),
                    );
                },
                .rect_lines => {
                    if (!d.in_frame) continue;
                    rl.c.DrawRectangleLinesEx(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .width = cmd.f[2], .height = cmd.f[3] },
                        if (cmd.f[4] > 0) cmd.f[4] else 1.0,
                        toRlColor(cmd.color),
                    );
                },
                .circle => {
                    if (!d.in_frame) continue;
                    rl.c.DrawCircleV(.{ .x = cmd.f[0], .y = cmd.f[1] }, cmd.f[2], toRlColor(cmd.color));
                },
                .triangle => {
                    if (!d.in_frame) continue;
                    rl.c.DrawTriangle(
                        .{ .x = cmd.f[0], .y = cmd.f[1] },
                        .{ .x = cmd.f[2], .y = cmd.f[3] },
                        .{ .x = cmd.f[4], .y = cmd.f[5] },
                        toRlColor(cmd.color),
                    );
                },
                .text => {
                    if (!d.in_frame) continue;
                    var buf: [65]u8 = undefined;
                    @memcpy(buf[0..cmd.text_len], cmd.text_buf[0..cmd.text_len]);
                    buf[cmd.text_len] = 0;
                    const size: c_int = if (cmd.f[2] > 0) @intFromFloat(cmd.f[2]) else 10;
                    rl.c.DrawText(&buf, @intFromFloat(cmd.f[0]), @intFromFloat(cmd.f[1]), size, toRlColor(cmd.color));
                },
                .pixel => {
                    if (!d.in_frame) continue;
                    rl.c.DrawPixelV(.{ .x = cmd.f[0], .y = cmd.f[1] }, toRlColor(cmd.color));
                },
                .begin3d => {
                    if (!d.in_frame) continue;
                    // f[0..2] = camera position, f[3..5] = target, f[6] = fovy
                    const cam3d = rl.c.Camera3D{
                        .position = .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        .target = .{ .x = cmd.f[3], .y = cmd.f[4], .z = cmd.f[5] },
                        .up = .{ .x = 0, .y = 1, .z = 0 },
                        .fovy = if (cmd.f[6] > 0) cmd.f[6] else 45.0,
                        .projection = rl.c.CAMERA_PERSPECTIVE,
                    };
                    rl.c.BeginMode3D(cam3d);
                    d.in_3d = true;
                },
                .end3d => {
                    if (d.in_3d) {
                        rl.c.EndMode3D();
                        d.in_3d = false;
                    }
                },
                .line3d => {
                    if (!d.in_frame) continue;
                    rl.c.DrawLine3D(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        .{ .x = cmd.f[3], .y = cmd.f[4], .z = cmd.f[5] },
                        toRlColor(cmd.color),
                    );
                },
                .cube3d => {
                    if (!d.in_frame) continue;
                    // Wireframe cube: position + size
                    rl.c.DrawCubeWires(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        cmd.f[3], cmd.f[3], cmd.f[3], // width, height, length = size
                        toRlColor(cmd.color),
                    );
                },
                .triangle3d => {
                    if (!d.in_frame) continue;
                    rl.c.DrawTriangle3D(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        .{ .x = cmd.f[3], .y = cmd.f[4], .z = cmd.f[5] },
                        .{ .x = cmd.f[6], .y = cmd.f[7], .z = cmd.f[8] },
                        toRlColor(cmd.color),
                    );
                },
                .cube3d_solid => {
                    if (!d.in_frame) continue;
                    rl.c.DrawCube(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        cmd.f[3], cmd.f[3], cmd.f[3],
                        toRlColor(cmd.color),
                    );
                },
            }
        }

        // Safety: force-close any open texture/3D modes that didn't get an end command this frame
        for (&self.displays) |*d| {
            if (d.in_3d) {
                rl.c.EndMode3D();
                d.in_3d = false;
            }
            if (d.in_frame) {
                rl.c.EndTextureMode();
                d.in_frame = false;
            }
        }
    }

    /// Blit all active displays to screen with window chrome, in z-order. Clean up inactive ones.
    pub fn drawAll(self: *DisplayManager, focused_display: ?usize) void {
        // Clean up deactivated displays
        for (&self.displays) |*d| {
            if (!d.active and d.tex_loaded) {
                if (d.in_frame) {
                    rl.c.EndTextureMode();
                    d.in_frame = false;
                }
                rl.c.UnloadRenderTexture(d.tex_front);
                rl.c.UnloadRenderTexture(d.tex_back);
                d.tex_loaded = false;
                d.has_good_frame = false;
            }
        }

        // Draw in z-order (back to front)
        for (self.draw_order) |idx| {
            const d = &self.displays[idx];
            if (!d.active or !d.tex_loaded or !d.has_good_frame) continue;
            if (d.in_frame) {
                rl.c.EndTextureMode();
                d.in_frame = false;
            }

            const w: f32 = @floatFromInt(d.width);
            const h: f32 = @floatFromInt(d.height);
            const wx = d.screen_x;
            const wy = d.screen_y;
            const cy = wy + TITLE_BAR_H;
            const is_focused = if (focused_display) |fi| fi == idx else false;

            // Title bar
            rl.c.DrawRectangleV(
                .{ .x = wx, .y = wy },
                .{ .x = w, .y = TITLE_BAR_H },
                if (is_focused) TITLE_FOCUSED_COLOR else TITLE_COLOR,
            );

            // Title text
            var title_z: [33]u8 = undefined;
            @memcpy(title_z[0..d.title_len], d.title[0..d.title_len]);
            title_z[d.title_len] = 0;
            rl.c.DrawText(&title_z, @intFromFloat(wx + 6), @intFromFloat(wy + 4), 14, TITLE_TEXT_COLOR);

            // Close button (X)
            const bx = wx + w - TITLE_BAR_H + CLOSE_BTN_PAD;
            const by = wy + CLOSE_BTN_PAD;
            const bs = TITLE_BAR_H - CLOSE_BTN_PAD * 2;
            rl.c.DrawLineEx(.{ .x = bx + 2, .y = by + 2 }, .{ .x = bx + bs - 2, .y = by + bs - 2 }, 2, TITLE_TEXT_COLOR);
            rl.c.DrawLineEx(.{ .x = bx + bs - 2, .y = by + 2 }, .{ .x = bx + 2, .y = by + bs - 2 }, 2, TITLE_TEXT_COLOR);

            // Content texture
            const tex = d.tex_front.texture;
            const tw: f32 = @floatFromInt(tex.width);
            const th: f32 = @floatFromInt(tex.height);
            const src = rl.c.Rectangle{ .x = 0, .y = 0, .width = tw, .height = -th };
            const dst = rl.c.Rectangle{ .x = wx, .y = cy, .width = w, .height = h };
            rl.c.BeginBlendMode(rl.c.BLEND_ALPHA);
            rl.c.DrawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, 0, rl.c.WHITE);
            rl.c.EndBlendMode();

            // Border around entire window
            rl.c.DrawRectangleLinesEx(
                .{ .x = wx, .y = wy, .width = w, .height = TITLE_BAR_H + h },
                1,
                if (is_focused) TITLE_TEXT_COLOR else BORDER_COLOR,
            );
        }
    }

    /// Bring a display to the front of the z-order.
    pub fn bringToFront(self: *DisplayManager, id: u8) void {
        // Find current position
        var pos: usize = 0;
        for (self.draw_order, 0..) |v, i| {
            if (v == id) {
                pos = i;
                break;
            }
        }
        // Shift everything after it down, put id at end
        var i = pos;
        while (i < MAX_DISPLAYS - 1) : (i += 1) {
            self.draw_order[i] = self.draw_order[i + 1];
        }
        self.draw_order[MAX_DISPLAYS - 1] = id;
    }

    /// Hit-test: is the point over any display's title bar? Returns display index (topmost first).
    pub fn hitTestTitleBar(self: *const DisplayManager, px: f32, py: f32) ?usize {
        var i: usize = MAX_DISPLAYS;
        while (i > 0) {
            i -= 1;
            const idx = self.draw_order[i];
            const d = self.displays[idx];
            if (!d.active or !d.has_good_frame) continue;
            const w: f32 = @floatFromInt(d.width);
            if (px >= d.screen_x and px < d.screen_x + w and
                py >= d.screen_y and py < d.screen_y + TITLE_BAR_H)
                return idx;
        }
        return null;
    }

    /// Hit-test: is the point over a close button? Returns display index.
    pub fn hitTestCloseBtn(self: *const DisplayManager, px: f32, py: f32) ?usize {
        var i: usize = MAX_DISPLAYS;
        while (i > 0) {
            i -= 1;
            const idx = self.draw_order[i];
            const d = self.displays[idx];
            if (!d.active or !d.has_good_frame) continue;
            const w: f32 = @floatFromInt(d.width);
            const bx = d.screen_x + w - TITLE_BAR_H;
            if (px >= bx and px < d.screen_x + w and
                py >= d.screen_y and py < d.screen_y + TITLE_BAR_H)
                return idx;
        }
        return null;
    }

    /// Hit-test: is the point over any display's content area? Returns display index (topmost first).
    pub fn hitTestContent(self: *const DisplayManager, px: f32, py: f32) ?usize {
        var i: usize = MAX_DISPLAYS;
        while (i > 0) {
            i -= 1;
            const idx = self.draw_order[i];
            const d = self.displays[idx];
            if (!d.active or !d.has_good_frame) continue;
            const w: f32 = @floatFromInt(d.width);
            const h: f32 = @floatFromInt(d.height);
            const cy = d.screen_y + TITLE_BAR_H;
            if (px >= d.screen_x and px < d.screen_x + w and
                py >= cy and py < cy + h)
                return idx;
        }
        return null;
    }

    /// Hit-test: any part of any display window (title bar + content).
    pub fn hitTestAny(self: *const DisplayManager, px: f32, py: f32) ?usize {
        var i: usize = MAX_DISPLAYS;
        while (i > 0) {
            i -= 1;
            const idx = self.draw_order[i];
            const d = self.displays[idx];
            if (!d.active or !d.has_good_frame) continue;
            const w: f32 = @floatFromInt(d.width);
            const h: f32 = @floatFromInt(d.height);
            if (px >= d.screen_x and px < d.screen_x + w and
                py >= d.screen_y and py < d.screen_y + TITLE_BAR_H + h)
                return idx;
        }
        return null;
    }

    fn ensureTexture(self: *DisplayManager, d: *Display) void {
        _ = self;
        if (!d.tex_loaded or d.needs_resize) {
            if (d.tex_loaded) {
                rl.c.UnloadRenderTexture(d.tex_front);
                rl.c.UnloadRenderTexture(d.tex_back);
            }
            d.tex_front = rl.c.LoadRenderTexture(@intCast(d.width), @intCast(d.height));
            d.tex_back = rl.c.LoadRenderTexture(@intCast(d.width), @intCast(d.height));
            rl.c.SetTextureFilter(d.tex_front.texture, rl.c.TEXTURE_FILTER_BILINEAR);
            rl.c.SetTextureFilter(d.tex_back.texture, rl.c.TEXTURE_FILTER_BILINEAR);
            for ([_]rl.c.RenderTexture2D{ d.tex_front, d.tex_back }) |tex| {
                rl.c.BeginTextureMode(tex);
                rl.c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
                rl.c.EndTextureMode();
            }
            d.tex_loaded = true;
            d.needs_resize = false;
        }
    }
};
