const std = @import("std");
const types = @import("../dns/types.zig");
const packet_mod = @import("../dns/packet.zig");
const service_mod = @import("service.zig");
const record_store = @import("../store/record_store.zig");

pub const MdnsServer = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.fd_t,
    mdns_service: service_mod.MdnsService,
    multicast_addr: std.net.Address,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, store: *record_store.RecordStore) !MdnsServer {
        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(sock);

        // Allow multiple processes to bind to port 5353
        const opt_one: c_int = 1;
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&opt_one));
        if (@hasDecl(std.posix.SO, "REUSEPORT")) {
            _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&opt_one)) catch {};
        }

        // Enable multicast loopback and set TTL
        const IP_MULTICAST_LOOP = 34;
        const IP_MULTICAST_TTL = 33;
        const IP_ADD_MEMBERSHIP = 35;

        const loop: u8 = 1;
        _ = std.posix.setsockopt(sock, std.posix.IPPROTO.IP, IP_MULTICAST_LOOP, std.mem.asBytes(&loop)) catch {};
        const ttl: u8 = 255;
        _ = std.posix.setsockopt(sock, std.posix.IPPROTO.IP, IP_MULTICAST_TTL, std.mem.asBytes(&ttl)) catch {};

        // Bind to 0.0.0.0:5353
        var bind_addr = std.net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, types.MDNS_PORT);
        try std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

        // Join multicast group 224.0.0.251
        const mreq = extern struct {
            multiaddr: [4]u8,
            interface: [4]u8,
        }{
            .multiaddr = [_]u8{ 224, 0, 0, 251 },
            .interface = [_]u8{ 0, 0, 0, 0 },
        };
        _ = std.posix.setsockopt(sock, std.posix.IPPROTO.IP, IP_ADD_MEMBERSHIP, std.mem.asBytes(&mreq)) catch {};

        const mcast_addr = std.net.Address.initIp4([_]u8{ 224, 0, 0, 251 }, types.MDNS_PORT);

        return MdnsServer{
            .allocator = allocator,
            .socket = sock,
            .mdns_service = service_mod.MdnsService.init(allocator, store),
            .multicast_addr = mcast_addr,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *MdnsServer) void {
        self.stop();
        std.posix.close(self.socket);
    }

    pub fn stop(self: *MdnsServer) void {
        self.running.store(false, .release);
    }

    pub fn sendPacket(self: *MdnsServer, packet: *const packet_mod.Packet, target_addr: ?std.net.Address) !void {
        const bytes = try packet.serialize(self.allocator);
        defer self.allocator.free(bytes);

        const dest = target_addr orelse self.multicast_addr;
        _ = try std.posix.sendto(self.socket, bytes, 0, &dest.any, dest.getOsSockLen());
    }

    pub fn broadcastRecord(self: *MdnsServer, rec: record_store.Record, is_goodbye: bool) !void {
        var packet = try self.mdns_service.buildAnnouncementPacket(rec, is_goodbye);
        defer packet.deinit();

        try self.sendPacket(&packet, null);
    }

    pub fn broadcastAll(self: *MdnsServer, is_goodbye: bool) !void {
        var all_records = try self.mdns_service.store.getAllRecords();
        defer {
            for (all_records.items) |*r| r.deinit(self.allocator);
            all_records.deinit();
        }

        for (all_records.items) |rec| {
            self.broadcastRecord(rec, is_goodbye) catch |err| {
                std.log.err("Failed to broadcast record {s}: {any}", .{ rec.hostname, err });
            };
        }
    }

    pub fn receiveAndRespond(self: *MdnsServer) !void {
        var buf: [4096]u8 = undefined;
        var src_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const recv_len = std.posix.recvfrom(
            self.socket,
            &buf,
            0,
            &src_addr,
            &addr_len,
        ) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (recv_len == 0) return;

        var query_packet = packet_mod.Packet.parse(self.allocator, buf[0..recv_len]) catch return;
        defer query_packet.deinit();

        // If it's a query (QR == 0), handle it
        if ((query_packet.header.flags & types.Flags.RESPONSE) == 0) {
            if (try self.mdns_service.handleQuery(&query_packet)) |response| {
                var resp = response;
                defer resp.deinit();

                // Respond via multicast
                try self.sendPacket(&resp, null);
            }
        }
    }

    pub fn runListener(self: *MdnsServer) void {
        while (self.running.load(.acquire)) {
            self.receiveAndRespond() catch |err| {
                if (err != error.WouldBlock) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
            };
        }
    }
};
