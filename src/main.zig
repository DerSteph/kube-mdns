const std = @import("std");
const config_mod = @import("config.zig");
const record_store = @import("store/record_store.zig");
const server_mod = @import("mdns/server.zig");
const client_mod = @import("k8s/client.zig");
const watcher_mod = @import("k8s/watcher.zig");

var global_server: ?*server_mod.MdnsServer = null;
var global_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn sigHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    global_running.store(false, .release);
    if (global_server) |srv| {
        srv.stop();
        srv.broadcastAll(true) catch {};
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try config_mod.Config.parseArgs(allocator);

    std.log.info("Starting kube-mdns (Zig native)...", .{});
    std.log.info("Log level: {s}, Default service type: {s}", .{ cfg.logging, cfg.service_type });

    // Setup signal handler for graceful shutdown
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    // Initialize in-memory record store
    var store = record_store.RecordStore.init(allocator);
    defer store.deinit();

    // Load manual configuration if provided
    if (cfg.config_path) |path| {
        std.log.info("Loading manual mDNS hosts from {s}...", .{path});
        var parsed_hosts = config_mod.Config.loadManualHosts(allocator, path) catch |err| {
            std.log.err("Failed to load config file: {any}", .{err});
            return err;
        };
        defer parsed_hosts.deinit();

        for (parsed_hosts.value) |host| {
            const port = host.port orelse cfg.port orelse 443;
            const st = host.service_type orelse cfg.service_type;
            store.addManual(host.hostname, host.ip, port, st) catch |err| {
                std.log.err("Failed to add manual host {s}: {any}", .{ host.hostname, err });
            };
            std.log.info("Registered manual host {s} -> {s}:{d} ({s})", .{
                host.hostname,
                host.ip,
                port,
                st,
            });
        }
    }

    // Initialize mDNS UDP server
    var server = server_mod.MdnsServer.init(allocator, &store) catch |err| {
        std.log.err("Failed to bind mDNS server on port 5353: {any}", .{err});
        return err;
    };
    defer server.deinit();
    global_server = &server;

    // Broadcast initial announcements for manual records
    server.broadcastAll(false) catch |err| {
        std.log.err("Failed to broadcast initial manual records: {any}", .{err});
    };

    // Spawn listener thread for incoming mDNS queries
    const listener_thread = try std.Thread.spawn(.{}, server_mod.MdnsServer.runListener, .{&server});
    defer listener_thread.join();

    // Initialize Kubernetes client
    var k8s_client = if (cfg.debug)
        try client_mod.K8sClient.initDebug(allocator, "127.0.0.1", 8001)
    else
        client_mod.K8sClient.initInCluster(allocator) catch |err| {
            std.log.warn("Kubernetes in-cluster config not found ({any}). Running in standalone manual mode.", .{err});
            // Keep running standalone mDNS server
            while (global_running.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
            }
            return;
        };
    defer k8s_client.deinit();

    var watcher = watcher_mod.Watcher.init(
        allocator,
        k8s_client,
        &store,
        &server,
        cfg.port,
        cfg.service_type,
        cfg.enable_crd,
    );
    defer watcher.stop();

    std.log.info("Watching Kubernetes Ingress resources...", .{});

    // Watch loop with auto-reconnect
    while (global_running.load(.acquire)) {
        var stream = k8s_client.makeStreamRequest("/apis/networking.k8s.io/v1/ingresses?watch=true") catch |err| {
            std.log.err("Failed to connect to Kubernetes Ingress stream: {any}. Retrying in 5s...", .{err});
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };
        defer stream.close();

        var reader = stream.reader();
        var line_buf: [16384]u8 = undefined;

        while (global_running.load(.acquire)) {
            const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| {
                std.log.warn("Stream interrupted: {any}. Reconnecting...", .{err});
                break;
            };

            if (line == null) break;
            const trimmed = std.mem.trim(u8, line.?, " \r\t");
            if (trimmed.len == 0) continue;

            watcher.handleIngressEventJson(trimmed) catch |err| {
                std.log.debug("Error processing watch line: {any}", .{err});
            };
        }

        std.time.sleep(1 * std.time.ns_per_s);
    }

    std.log.info("Shutdown complete. Bye!", .{});
}
