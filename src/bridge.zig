const std = @import("std");
const posix = std.posix;

/// Microkernel wire format — 28-byte packed header + payload.
/// Host byte order for Unix sockets, network byte order for TCP.
pub const WIRE_HEADER_SIZE: usize = 28;

pub const WireHeader = extern struct {
    source: u64, // actor_id_t
    dest: u64, // actor_id_t
    msg_type: u32, // msg_type_t
    payload_size: u32,
    reserved: u32,
};

pub const Message = struct {
    source: u64,
    dest: u64,
    msg_type: u32,
    payload: []const u8,
};

/// Connection mode determines byte ordering.
pub const Mode = enum { local, network };

/// Serialize a message to wire format. Caller owns returned slice.
pub fn serialize(alloc: std.mem.Allocator, msg: Message, mode: Mode) ![]u8 {
    const total = WIRE_HEADER_SIZE + msg.payload.len;
    const buf = try alloc.alloc(u8, total);

    var hdr: WireHeader = .{
        .source = msg.source,
        .dest = msg.dest,
        .msg_type = msg.msg_type,
        .payload_size = @intCast(msg.payload.len),
        .reserved = 0,
    };

    if (mode == .network) {
        hdr.source = @byteSwap(hdr.source);
        hdr.dest = @byteSwap(hdr.dest);
        hdr.msg_type = @byteSwap(hdr.msg_type);
        hdr.payload_size = @byteSwap(hdr.payload_size);
    }

    const hdr_bytes: *const [WIRE_HEADER_SIZE]u8 = @ptrCast(&hdr);
    @memcpy(buf[0..WIRE_HEADER_SIZE], hdr_bytes);
    if (msg.payload.len > 0) {
        @memcpy(buf[WIRE_HEADER_SIZE..], msg.payload);
    }
    return buf;
}

/// Deserialize a wire header from bytes. Returns null if buffer too small.
pub fn deserializeHeader(buf: []const u8, mode: Mode) ?WireHeader {
    if (buf.len < WIRE_HEADER_SIZE) return null;
    const ptr: *const WireHeader = @ptrCast(@alignCast(buf.ptr));
    var hdr = ptr.*;

    if (mode == .network) {
        hdr.source = @byteSwap(hdr.source);
        hdr.dest = @byteSwap(hdr.dest);
        hdr.msg_type = @byteSwap(hdr.msg_type);
        hdr.payload_size = @byteSwap(hdr.payload_size);
    }
    return hdr;
}

// ---------------------------------------------------------------
// Connection — non-blocking Unix socket or TCP
// ---------------------------------------------------------------

pub const MAX_MSG_SIZE: usize = 64 * 1024;

pub const Connection = struct {
    fd: posix.fd_t = -1,
    mode: Mode = .local,
    connected: bool = false,

    // Read buffer for accumulating partial messages
    read_buf: [WIRE_HEADER_SIZE + MAX_MSG_SIZE]u8 = undefined,
    read_len: usize = 0,

    /// Connect to a Unix domain socket.
    pub fn connectUnix(self: *Connection, path: []const u8) !void {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const copy_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..copy_len], path[0..copy_len]);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            if (err != error.WouldBlock and err != error.ConnectionRefused) {
                return err;
            }
            // Non-blocking connect in progress or refused
            if (err == error.ConnectionRefused) return err;
        };

        self.fd = fd;
        self.mode = .local;
        self.connected = true;
        self.read_len = 0;
    }

    /// Connect to a TCP host:port (network byte order).
    pub fn connectTcp(self: *Connection, host: []const u8, port: u16) !void {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        // Parse host as IPv4 dotted quad
        var ip4: u32 = 0;
        var octet: u32 = 0;
        var shift: u5 = 0;
        for (host) |ch| {
            if (ch == '.') {
                ip4 |= octet << (shift * 8);
                octet = 0;
                shift += 1;
            } else if (ch >= '0' and ch <= '9') {
                octet = octet * 10 + (ch - '0');
            }
        }
        ip4 |= octet << (shift * 8);

        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = ip4,
            .zero = .{0} ** 8,
        };

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch |err| {
            if (err != error.WouldBlock) return err;
        };

        self.fd = fd;
        self.mode = .network;
        self.connected = true;
        self.read_len = 0;
    }

    /// Send a message. Returns true on success.
    pub fn send(self: *Connection, alloc: std.mem.Allocator, msg: Message) bool {
        if (!self.connected) return false;

        const buf = serialize(alloc, msg, self.mode) catch return false;
        defer alloc.free(buf);

        var sent: usize = 0;
        while (sent < buf.len) {
            const n = posix.write(self.fd, buf[sent..]) catch return false;
            if (n == 0) return false;
            sent += n;
        }
        return true;
    }

    /// Try to receive a message. Non-blocking, returns null if nothing ready.
    pub fn recv(self: *Connection, alloc: std.mem.Allocator) ?Message {
        if (!self.connected) return null;

        // Try to read more data
        const space = self.read_buf.len - self.read_len;
        if (space > 0) {
            const n = posix.read(self.fd, self.read_buf[self.read_len..]) catch |err| {
                if (err == error.WouldBlock) {
                    // Nothing available right now
                } else {
                    self.connected = false;
                }
                return self.tryParseMessage(alloc);
            };
            if (n == 0) {
                self.connected = false;
                return null;
            }
            self.read_len += n;
        }

        return self.tryParseMessage(alloc);
    }

    fn tryParseMessage(self: *Connection, alloc: std.mem.Allocator) ?Message {
        if (self.read_len < WIRE_HEADER_SIZE) return null;

        const hdr = deserializeHeader(self.read_buf[0..WIRE_HEADER_SIZE], self.mode) orelse return null;
        const total = WIRE_HEADER_SIZE + hdr.payload_size;

        if (hdr.payload_size > MAX_MSG_SIZE) {
            // Invalid message — discard and disconnect
            self.connected = false;
            return null;
        }

        if (self.read_len < total) return null; // need more data

        // Extract payload
        var payload: []const u8 = &.{};
        if (hdr.payload_size > 0) {
            const owned = alloc.alloc(u8, hdr.payload_size) catch return null;
            @memcpy(owned, self.read_buf[WIRE_HEADER_SIZE..total]);
            payload = owned;
        }

        // Shift remaining data
        const remaining = self.read_len - total;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[total..self.read_len]);
        }
        self.read_len = remaining;

        return .{
            .source = hdr.source,
            .dest = hdr.dest,
            .msg_type = hdr.msg_type,
            .payload = payload,
        };
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }
        self.connected = false;
    }

    /// Check if connected.
    pub fn isConnected(self: *const Connection) bool {
        return self.connected;
    }
};

// ---------------------------------------------------------------
// Name cache — maps paths to actor IDs
// ---------------------------------------------------------------

const MAX_CACHE_ENTRIES = 64;

pub const NameCache = struct {
    paths: [MAX_CACHE_ENTRIES][128]u8 = undefined,
    path_lens: [MAX_CACHE_ENTRIES]u8 = .{0} ** MAX_CACHE_ENTRIES,
    ids: [MAX_CACHE_ENTRIES]u64 = .{0} ** MAX_CACHE_ENTRIES,
    count: usize = 0,

    pub fn lookup(self: *const NameCache, path: []const u8) ?u64 {
        for (0..self.count) |i| {
            if (self.path_lens[i] == path.len and
                std.mem.eql(u8, self.paths[i][0..self.path_lens[i]], path))
            {
                return self.ids[i];
            }
        }
        return null;
    }

    pub fn put(self: *NameCache, path: []const u8, id: u64) void {
        if (path.len > 127) return;

        // Update existing
        for (0..self.count) |i| {
            if (self.path_lens[i] == path.len and
                std.mem.eql(u8, self.paths[i][0..self.path_lens[i]], path))
            {
                self.ids[i] = id;
                return;
            }
        }

        // Add new
        if (self.count < MAX_CACHE_ENTRIES) {
            @memcpy(self.paths[self.count][0..path.len], path);
            self.path_lens[self.count] = @intCast(path.len);
            self.ids[self.count] = id;
            self.count += 1;
        }
    }
};

// ---------------------------------------------------------------
// Well-known message types (from microkernel/services.h)
// ---------------------------------------------------------------

pub const MSG = struct {
    // Namespace
    pub const NS_REGISTER: u32 = 0xFF000014;
    pub const NS_LOOKUP: u32 = 0xFF000015;
    pub const NS_LIST: u32 = 0xFF000016;
    pub const NS_REPLY: u32 = 0xFF000019;

    // Console
    pub const CONSOLE_WRITE: u32 = 0xFF000060;
    pub const CONSOLE_CLEAR: u32 = 0xFF000061;

    // Display
    pub const DISPLAY_DRAW: u32 = 0xFF000051;
    pub const DISPLAY_FILL: u32 = 0xFF000052;
    pub const DISPLAY_CLEAR: u32 = 0xFF000053;
    pub const DISPLAY_TEXT: u32 = 0xFF000056;
    pub const DISPLAY_TEXT_ATTR: u32 = 0xFF000057;

    // GPIO
    pub const GPIO_WRITE: u32 = 0xFF000021;
    pub const GPIO_READ: u32 = 0xFF000022;
    pub const GPIO_EVENT: u32 = 0xFF000025;

    // Timer
    pub const TIMER: u32 = 0xFF000001;

    // Lifecycle
    pub const CHILD_EXIT: u32 = 0xFF000010;
    pub const LOG: u32 = 0xFF000003;
};
