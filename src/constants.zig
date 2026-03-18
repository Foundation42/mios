const rl = @import("rl.zig");

pub const WINDOW_W: c_int = 1200;
pub const WINDOW_H: c_int = 800;
pub const TARGET_FPS: c_int = 60;

pub const BG_COLOR = rl.color(10, 10, 18, 255);
pub const HUD_COLOR = rl.color(0, 255, 180, 255);
pub const HUD_DIM = rl.color(0, 255, 180, 120);
