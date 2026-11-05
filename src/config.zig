const std = @import("std");

pub const Config = struct {
    debug: bool = false,
    logging: []const u8 = "INFO",
    interface: ?[]const u8 = null,
    port: ?u16 = null,
    service_type: []const u8 = "_http._tcp.local.",
    config_path: ?[]const u8 = null,
    enable_crd: bool = false,

    pub const ManualHost = struct {
        hostname: []const u8,
        ip: []const u8,
        port: ?u16 = null,
        service_type: ?[]const u8 = null,
    };

    pub fn parseArgs(allocator: std.mem.Allocator) !Config {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        var cfg = Config{};
        _ = args.next(); // Skip executable name

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--debug")) {
                cfg.debug = true;
            } else if (std.mem.eql(u8, arg, "--operator") or std.mem.eql(u8, arg, "--enable-crd")) {
                cfg.enable_crd = true;
            } else if (std.mem.eql(u8, arg, "--logging")) {
                if (args.next()) |val| {
                    cfg.logging = val;
                }
            } else if (std.mem.eql(u8, arg, "--interface")) {
                if (args.next()) |val| {
                    cfg.interface = val;
                }
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (args.next()) |val| {
                    cfg.port = try std.fmt.parseInt(u16, val, 10);
                }
            } else if (std.mem.eql(u8, arg, "--service-type")) {
                if (args.next()) |val| {
                    cfg.service_type = val;
                }
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (args.next()) |val| {
                    cfg.config_path = val;
                }
            }
        }

        return cfg;
    }

    pub fn loadManualHosts(allocator: std.mem.Allocator, filepath: []const u8) !std.json.Parsed([]ManualHost) {
        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        const file_size = (try file.stat()).size;
        if (file_size > 10 * 1024 * 1024) return error.FileTooLarge;

        const content = try file.readToEndAlloc(allocator, @intCast(file_size));
        defer allocator.free(content);

        return try std.json.parseFromSlice([]ManualHost, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

test "load manual hosts json" {
    const allocator = std.testing.allocator;

    const sample_json =
        \\ [
        \\     {
        \\         "hostname": "homeassistant.local",
        \\         "ip": "192.168.1.101",
        \\         "port": 8080,
        \\         "service_type": "_https._tcp.local."
        \\     },
        \\     {
        \\         "hostname": "paperless.local",
        \\         "ip": "192.168.1.102"
        \\     }
        \\ ]
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "test_hosts.json", .data = sample_json });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test_hosts.json", &path_buf);

    var parsed = try Config.loadManualHosts(allocator, real_path);
    defer parsed.deinit();

    try std.testing.expectEqual(parsed.value.len, 2);
    try std.testing.expectEqualStrings("homeassistant.local", parsed.value[0].hostname);
    try std.testing.expectEqual(@as(u16, 8080), parsed.value[0].port.?);
    try std.testing.expectEqualStrings("_https._tcp.local.", parsed.value[0].service_type.?);
    try std.testing.expectEqualStrings("paperless.local", parsed.value[1].hostname);
    try std.testing.expect(parsed.value[1].port == null);
}
