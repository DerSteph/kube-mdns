const std = @import("std");

pub const K8sClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    token: ?[]const u8 = null,
    use_tls: bool = true,

    pub fn initInCluster(allocator: std.mem.Allocator) !K8sClient {
        const host = std.posix.getenv("KUBERNETES_SERVICE_HOST") orelse return error.NotInCluster;
        const port_str = std.posix.getenv("KUBERNETES_SERVICE_PORT") orelse "443";
        const port = try std.fmt.parseInt(u16, port_str, 10);

        // Read token
        const token_file = std.fs.openFileAbsolute(
            "/var/run/secrets/kubernetes.io/serviceaccount/token",
            .{},
        ) catch |err| {
            std.log.err("Failed to open serviceaccount token: {any}", .{err});
            return error.TokenNotFound;
        };
        defer token_file.close();

        const token_size = (try token_file.stat()).size;
        const token = try token_file.readToEndAlloc(allocator, @intCast(token_size));

        return K8sClient{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .token = token,
            .use_tls = true,
        };
    }

    pub fn initDebug(allocator: std.mem.Allocator, host: []const u8, port: u16) !K8sClient {
        return K8sClient{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .token = null,
            .use_tls = false,
        };
    }

    pub fn deinit(self: *K8sClient) void {
        self.allocator.free(self.host);
        if (self.token) |tok| {
            self.allocator.free(tok);
        }
    }

    pub fn makeStreamRequest(
        self: *K8sClient,
        path: []const u8,
    ) !std.net.Stream {
        const addr_list = try std.net.getAddressList(self.allocator, self.host, self.port);
        defer addr_list.deinit();

        if (addr_list.addrs.len == 0) return error.HostNotFound;
        const addr = addr_list.addrs[0];

        const stream = try std.net.tcpConnectToAddress(addr);
        errdefer stream.close();

        var header_buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&header_buf);
        const writer = fbs.writer();

        try writer.print("GET {s} HTTP/1.1\r\n", .{path});
        try writer.print("Host: {s}:{d}\r\n", .{ self.host, self.port });
        try writer.print("Accept: application/json\r\n", .{});
        try writer.print("Connection: close\r\n", .{});

        if (self.token) |tok| {
            try writer.print("Authorization: Bearer {s}\r\n", .{tok});
        }
        try writer.print("\r\n", .{});

        try stream.writeAll(fbs.getWritten());

        return stream;
    }
};
