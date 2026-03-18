const std = @import("std");
const bridge = @import("bridge.zig");
const terminal_mod = @import("terminal.zig");

/// Maximum remote nodes MiOS can mount simultaneously.
pub const MAX_NODES: usize = 8;

/// Maximum messages in each direction per frame.
const QUEUE_SIZE: usize = 256;

/// A mounted remote microkernel node.
pub const RemoteNode = struct {
    active: bool = false,
    conn: bridge.Connection = .{},
    node_id: u32 = 0,
    identity: [32]u8 = .{0} ** 32,
    identity_len: usize = 0,
    name_cache: bridge.NameCache = .{},

    // Actor IDs we registered on the remote for this node
    console_actor_id: u64 = 0,
    display_actor_id: u64 = 0,

    // Remote shell actor ID (to send keyboard input to)
    shell_actor_id: u64 = 0,
    console_remote_id: u64 = 0, // remote's console actor (for sending output there)
};

/// A routed message with node index.
pub const RoutedMessage = struct {
    node_idx: u8,
    msg: bridge.Message,
    // Owned payload (must be freed by consumer)
    payload_buf: [bridge.MAX_MSG_SIZE]u8 = undefined,
    payload_len: usize = 0,
};

/// Ring buffer for inter-thread message passing.
pub const MessageRing = struct {
    buf: [QUEUE_SIZE]RoutedMessage = undefined,
    head: usize = 0, // write pos
    tail: usize = 0, // read pos
    mutex: std.Thread.Mutex = .{},

    pub fn push(self: *MessageRing, msg: RoutedMessage) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next = (self.head + 1) % QUEUE_SIZE;
        if (next == self.tail) return false; // full
        self.buf[self.head] = msg;
        // Copy payload into the ring entry's own buffer
        if (msg.msg.payload.len > 0 and msg.msg.payload.len <= bridge.MAX_MSG_SIZE) {
            @memcpy(self.buf[self.head].payload_buf[0..msg.msg.payload.len], msg.msg.payload);
            self.buf[self.head].payload_len = msg.msg.payload.len;
        }
        self.head = next;
        return true;
    }

    pub fn pop(self: *MessageRing) ?RoutedMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tail == self.head) return null;
        var entry = self.buf[self.tail];
        // Point payload to the entry's own buffer
        if (entry.payload_len > 0) {
            entry.msg.payload = entry.payload_buf[0..entry.payload_len];
        } else {
            entry.msg.payload = "";
        }
        self.tail = (self.tail + 1) % QUEUE_SIZE;
        return entry;
    }
};

/// Mount request (main/JS thread → bridge thread).
pub const MountRequest = struct {
    host: [256]u8 = .{0} ** 256,
    host_len: usize = 0,
    port: u16 = 4200,
    slot: u8 = 0, // which node slot to use
};

const MOUNT_QUEUE_SIZE: usize = 8;

/// The NodeManager runs on its own thread, managing all remote connections.
pub const NodeManager = struct {
    nodes: [MAX_NODES]RemoteNode = .{.{}} ** MAX_NODES,

    // Inbound: bridge thread → main thread (messages from remote nodes)
    inbound: MessageRing = .{},

    // Outbound: main/JS thread → bridge thread (messages to remote nodes)
    outbound: MessageRing = .{},

    // Mount requests: main/JS thread → bridge thread
    mount_requests: [MOUNT_QUEUE_SIZE]MountRequest = undefined,
    mount_head: usize = 0,
    mount_tail: usize = 0,
    mount_mutex: std.Thread.Mutex = .{},

    // Mount results: bridge thread → main thread
    mount_results: [MOUNT_QUEUE_SIZE]MountResult = undefined,
    mount_result_head: usize = 0,
    mount_result_tail: usize = 0,
    mount_result_mutex: std.Thread.Mutex = .{},

    // Thread control
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    alloc: std.mem.Allocator = std.heap.page_allocator,

    pub fn start(self: *NodeManager) void {
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
    }

    pub fn stop(self: *NodeManager) void {
        self.shutdown.store(true, .release);
        if (self.worker) |w| {
            w.join();
            self.worker = null;
        }
        for (&self.nodes) |*n| {
            if (n.active) n.conn.close();
        }
    }

    /// Request a mount (called from main/JS thread).
    pub fn requestMount(self: *NodeManager, host: []const u8, port: u16) ?u8 {
        // Find a free slot
        var slot: ?u8 = null;
        for (self.nodes, 0..) |n, i| {
            if (!n.active) {
                slot = @intCast(i);
                break;
            }
        }
        if (slot == null) return null;

        self.mount_mutex.lock();
        defer self.mount_mutex.unlock();
        const next = (self.mount_head + 1) % MOUNT_QUEUE_SIZE;
        if (next == self.mount_tail) return null;

        var req = &self.mount_requests[self.mount_head];
        req.slot = slot.?;
        req.port = port;
        const copy_len = @min(host.len, 255);
        @memcpy(req.host[0..copy_len], host[0..copy_len]);
        req.host_len = copy_len;
        self.mount_head = next;
        return slot;
    }

    /// Check for mount results (called from main thread).
    pub fn popMountResult(self: *NodeManager) ?MountResult {
        self.mount_result_mutex.lock();
        defer self.mount_result_mutex.unlock();
        if (self.mount_result_tail == self.mount_result_head) return null;
        const result = self.mount_results[self.mount_result_tail];
        self.mount_result_tail = (self.mount_result_tail + 1) % MOUNT_QUEUE_SIZE;
        return result;
    }

    /// Send a message to a remote node (called from main thread).
    pub fn sendTo(self: *NodeManager, node_idx: u8, dest: u64, msg_type: u32, payload: []const u8) void {
        var routed = RoutedMessage{
            .node_idx = node_idx,
            .msg = .{
                .source = 0,
                .dest = dest,
                .msg_type = msg_type,
                .payload = payload,
            },
        };
        if (payload.len > 0 and payload.len <= bridge.MAX_MSG_SIZE) {
            @memcpy(routed.payload_buf[0..payload.len], payload);
            routed.payload_len = payload.len;
        }
        _ = self.outbound.push(routed);
    }

    // ---------------------------------------------------------------
    // Worker thread
    // ---------------------------------------------------------------

    fn workerLoop(self: *NodeManager) void {
        while (!self.shutdown.load(.acquire)) {
            // Process mount requests
            self.processMountRequests();

            // Poll all active connections for incoming messages
            for (&self.nodes, 0..) |*node, i| {
                if (!node.active) continue;

                // Check connection still alive
                if (!node.conn.isConnected()) {
                    node.active = false;
                    self.pushMountResult(.{
                        .slot = @intCast(i),
                        .success = false,
                        .node_id = node.node_id,
                        .identity = node.identity,
                        .identity_len = node.identity_len,
                        .disconnected = true,
                    });
                    continue;
                }

                // Receive messages
                while (node.conn.recv(self.alloc)) |msg| {
                    defer if (msg.payload.len > 0) self.alloc.free(msg.payload);

                    // Cache namespace sync
                    cacheNameSync(node, msg);

                    // Route to main thread
                    _ = self.inbound.push(.{
                        .node_idx = @intCast(i),
                        .msg = msg,
                    });
                }
            }

            // Send outbound messages
            while (self.outbound.pop()) |routed| {
                if (routed.node_idx < MAX_NODES) {
                    var node = &self.nodes[routed.node_idx];
                    if (node.active) {
                        _ = node.conn.send(self.alloc, routed.msg);
                    }
                }
            }

            std.time.sleep(5 * std.time.ns_per_ms);
        }
    }

    fn processMountRequests(self: *NodeManager) void {
        self.mount_mutex.lock();
        const has_request = self.mount_tail != self.mount_head;
        var req: MountRequest = undefined;
        if (has_request) {
            req = self.mount_requests[self.mount_tail];
            self.mount_tail = (self.mount_tail + 1) % MOUNT_QUEUE_SIZE;
        }
        self.mount_mutex.unlock();

        if (!has_request) return;

        const slot = req.slot;
        var node = &self.nodes[slot];
        const host = req.host[0..req.host_len];

        // Our actor IDs for this node: (MIOS_NODE << 32) | (slot * 16 + offset)
        const base_seq: u32 = @as(u32, slot) * 16;
        const console_id = (@as(u64, MIOS_NODE) << 32) | (base_seq + 1);
        const display_id = (@as(u64, MIOS_NODE) << 32) | (base_seq + 2);

        // Attempt mount
        const result = node.conn.mount(host, req.port, MIOS_NODE, "mios") catch {
            self.pushMountResult(.{
                .slot = slot,
                .success = false,
                .node_id = 0,
                .identity = .{0} ** 32,
                .identity_len = 0,
                .disconnected = false,
            });
            return;
        };

        node.active = true;
        node.node_id = result.node_id;
        node.identity = result.identity;
        node.identity_len = result.identity_len;
        node.console_actor_id = console_id;
        node.display_actor_id = display_id;

        // Wait for namespace sync
        std.time.sleep(100 * std.time.ns_per_ms);
        while (node.conn.recv(self.alloc)) |msg| {
            defer if (msg.payload.len > 0) self.alloc.free(msg.payload);
            cacheNameSync(node, msg);
        }

        // Look up remote shell and console actors
        node.shell_actor_id = node.name_cache.lookup("shell") orelse 0;
        node.console_remote_id = node.name_cache.lookup("console") orelse 0;

        // Register our actors on the remote
        self.registerActors(node, console_id, display_id);

        self.pushMountResult(.{
            .slot = slot,
            .success = true,
            .node_id = result.node_id,
            .identity = result.identity,
            .identity_len = result.identity_len,
            .disconnected = false,
        });
    }

    fn registerActors(self: *NodeManager, node: *RemoteNode, console_id: u64, display_id: u64) void {
        // Register name: mios-console
        var name_payload: [72]u8 = .{0} ** 72;
        @memcpy(name_payload[0..12], "mios-console");
        const cid_bytes: [8]u8 = @bitCast(console_id);
        @memcpy(name_payload[64..72], &cid_bytes);
        _ = node.conn.send(self.alloc, .{
            .source = console_id,
            .dest = 0,
            .msg_type = bridge.MSG.NAME_REGISTER,
            .payload = &name_payload,
        });

        // Register path: /node/mios/console
        var path_payload: [136]u8 = .{0} ** 136;
        @memcpy(path_payload[0..19], "/node/mios/console\x00");
        @memcpy(path_payload[128..136], &cid_bytes);
        _ = node.conn.send(self.alloc, .{
            .source = console_id,
            .dest = 0,
            .msg_type = bridge.MSG.PATH_REGISTER,
            .payload = &path_payload,
        });

        // Register display
        var dname_payload: [72]u8 = .{0} ** 72;
        @memcpy(dname_payload[0..12], "mios-display");
        const did_bytes: [8]u8 = @bitCast(display_id);
        @memcpy(dname_payload[64..72], &did_bytes);
        _ = node.conn.send(self.alloc, .{
            .source = display_id,
            .dest = 0,
            .msg_type = bridge.MSG.NAME_REGISTER,
            .payload = &dname_payload,
        });

        var dpath_payload: [136]u8 = .{0} ** 136;
        @memcpy(dpath_payload[0..19], "/node/mios/display\x00");
        @memcpy(dpath_payload[128..136], &did_bytes);
        _ = node.conn.send(self.alloc, .{
            .source = display_id,
            .dest = 0,
            .msg_type = bridge.MSG.PATH_REGISTER,
            .payload = &dpath_payload,
        });
    }

    fn pushMountResult(self: *NodeManager, result: MountResult) void {
        self.mount_result_mutex.lock();
        defer self.mount_result_mutex.unlock();
        const next = (self.mount_result_head + 1) % MOUNT_QUEUE_SIZE;
        if (next == self.mount_result_tail) return;
        self.mount_results[self.mount_result_head] = result;
        self.mount_result_head = next;
    }

    fn cacheNameSync(node: *RemoteNode, msg: bridge.Message) void {
        if (msg.msg_type == bridge.MSG.NAME_REGISTER and msg.payload.len >= 72) {
            const name = extractCStr(msg.payload[0..64]);
            var id_bytes: [8]u8 = undefined;
            @memcpy(&id_bytes, msg.payload[64..72]);
            node.name_cache.put(name, @bitCast(id_bytes));
        }
        if (msg.msg_type == bridge.MSG.PATH_REGISTER and msg.payload.len >= 136) {
            const path = extractCStr(msg.payload[0..128]);
            var id_bytes: [8]u8 = undefined;
            @memcpy(&id_bytes, msg.payload[128..136]);
            node.name_cache.put(path, @bitCast(id_bytes));
        }
    }

    fn extractCStr(buf: []const u8) []const u8 {
        for (buf, 0..) |ch, i| {
            if (ch == 0) return buf[0..i];
        }
        return buf;
    }
};

pub const MountResult = struct {
    slot: u8,
    success: bool,
    node_id: u32,
    identity: [32]u8,
    identity_len: usize,
    disconnected: bool,
};

const MIOS_NODE: u32 = 15;
