const std = @import("std");
const k8s_types = @import("types.zig");
const client_mod = @import("client.zig");
const record_store = @import("../store/record_store.zig");
const server_mod = @import("../mdns/server.zig");

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    client: client_mod.K8sClient,
    store: *record_store.RecordStore,
    server: ?*server_mod.MdnsServer,
    default_port: ?u16,
    default_service_type: []const u8,
    enable_crd: bool,
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        client: client_mod.K8sClient,
        store: *record_store.RecordStore,
        server: ?*server_mod.MdnsServer,
        default_port: ?u16,
        default_service_type: []const u8,
        enable_crd: bool,
    ) Watcher {
        return Watcher{
            .allocator = allocator,
            .client = client,
            .store = store,
            .server = server,
            .default_port = default_port,
            .default_service_type = default_service_type,
            .enable_crd = enable_crd,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn stop(self: *Watcher) void {
        self.running.store(false, .release);
    }

    pub fn selectPreferredPort(self: *Watcher, ports: ?[]k8s_types.PortInfo) u16 {
        if (ports) |list| {
            for (list) |p| {
                if (p.port == 443) return 443;
            }
            for (list) |p| {
                if (p.port == 80) return 80;
            }
            if (list.len > 0) return list[0].port;
        }
        if (self.default_port) |dp| return dp;
        return 443;
    }

    pub fn handleIngressEventJson(self: *Watcher, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(k8s_types.WatchEvent, self.allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.debug("Skipping unparseable ingress watch line: {any}", .{err});
            return;
        };
        defer parsed.deinit();

        const event = parsed.value;
        const ingress = event.object;
        const namespace = ingress.metadata.namespace orelse "default";
        const name = ingress.metadata.name;

        if (std.mem.eql(u8, event.type, "DELETED")) {
            std.log.info("Ingress {s}/{s} deleted, unregistering records...", .{ namespace, name });
            var removed = try self.store.removeIngress(namespace, name);
            defer {
                for (removed.items) |*r| r.deinit(self.allocator);
                removed.deinit();
            }

            for (removed.items) |rec| {
                if (self.server) |srv| {
                    try srv.broadcastRecord(rec, true);
                }
            }
            return;
        }

        if (std.mem.eql(u8, event.type, "ADDED") or std.mem.eql(u8, event.type, "MODIFIED")) {
            const rules = if (ingress.spec) |s| s.rules else null;
            if (rules == null or rules.?.len == 0) return;

            const lb_ingresses = if (ingress.status) |st|
                (if (st.loadBalancer) |lb| lb.ingress else null)
            else
                null;

            if (lb_ingresses == null or lb_ingresses.?.len == 0) {
                std.log.debug("Ingress {s}/{s} has no load balancer IP, skipping...", .{ namespace, name });
                return;
            }

            var ip_list = std.ArrayList([4]u8).init(self.allocator);
            defer ip_list.deinit();

            var ports_list: ?[]k8s_types.PortInfo = null;

            for (lb_ingresses.?) |lbi| {
                if (lbi.ip) |ip_str| {
                    if (record_store.RecordStore.parseIp4(ip_str)) |parsed_ip| {
                        try ip_list.append(parsed_ip);
                    } else |_| {}
                }
                if (ports_list == null and lbi.ports != null) {
                    ports_list = lbi.ports;
                }
            }

            if (ip_list.items.len == 0) return;

            const preferred_port = self.selectPreferredPort(ports_list);

            for (rules.?) |rule| {
                if (rule.host) |host| {
                    if (std.mem.endsWith(u8, host, ".local")) {
                        std.log.info("Discovered mDNS Ingress rule: {s} -> port {d} on {s}/{s}", .{
                            host,
                            preferred_port,
                            namespace,
                            name,
                        });

                        const updated = try self.store.addOrUpdateIngress(
                            namespace,
                            name,
                            host,
                            ip_list.items,
                            preferred_port,
                            self.default_service_type,
                        );

                        if (updated) {
                            if (self.store.findByHostname(host)) |mut_rec| {
                                var rec = mut_rec;
                                defer rec.deinit(self.allocator);
                                if (self.server) |srv| {
                                    try srv.broadcastRecord(rec, false);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn handleCrdEventJson(self: *Watcher, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(k8s_types.MdnsRecordWatchEvent, self.allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.debug("Skipping unparseable CRD watch line: {any}", .{err});
            return;
        };
        defer parsed.deinit();

        const event = parsed.value;
        const crd = event.object;
        const namespace = crd.metadata.namespace orelse "default";
        const name = crd.metadata.name;

        if (std.mem.eql(u8, event.type, "DELETED")) {
            std.log.info("MdnsRecord CRD {s}/{s} deleted, unregistering...", .{ namespace, name });
            var removed = try self.store.removeIngress(namespace, name);
            defer {
                for (removed.items) |*r| r.deinit(self.allocator);
                removed.deinit();
            }

            for (removed.items) |rec| {
                if (self.server) |srv| {
                    try srv.broadcastRecord(rec, true);
                }
            }
            return;
        }

        if (std.mem.eql(u8, event.type, "ADDED") or std.mem.eql(u8, event.type, "MODIFIED")) {
            const ip_bytes = try record_store.RecordStore.parseIp4(crd.spec.ip);
            const ips = [_][4]u8{ip_bytes};
            const port = crd.spec.port orelse 443;
            const service_type = crd.spec.serviceType orelse self.default_service_type;

            std.log.info("Reconciling MdnsRecord CRD {s}/{s} -> {s}:{d}", .{
                namespace,
                name,
                crd.spec.host,
                port,
            });

            _ = try self.store.addOrUpdateIngress(
                namespace,
                name,
                crd.spec.host,
                &ips,
                port,
                service_type,
            );

            if (self.store.findByHostname(crd.spec.host)) |mut_rec| {
                var rec = mut_rec;
                defer rec.deinit(self.allocator);
                if (self.server) |srv| {
                    try srv.broadcastRecord(rec, false);
                }
            }
        }
    }
};

test "watcher handles ingress added and deleted events" {
    const allocator = std.testing.allocator;

    var store = record_store.RecordStore.init(allocator);
    defer store.deinit();

    const client = client_mod.K8sClient{
        .allocator = allocator,
        .host = "127.0.0.1",
        .port = 8001,
        .token = null,
        .use_tls = false,
    };

    var watcher = Watcher.init(
        allocator,
        client,
        &store,
        null,
        null,
        "_http._tcp.local.",
        false,
    );

    const added_json =
        \\ {
        \\   "type": "ADDED",
        \\   "object": {
        \\     "metadata": {"name": "app", "namespace": "prod"},
        \\     "spec": {"rules": [{"host": "app.local"}]},
        \\     "status": {
        \\       "loadBalancer": {
        \\         "ingress": [{"ip": "10.0.0.5", "ports": [{"port": 8080}]}]
        \\       }
        \\     }
        \\   }
        \\ }
    ;

    try watcher.handleIngressEventJson(added_json);

    const rec = store.findByHostname("app.local");
    try std.testing.expect(rec != null);
    if (rec) |mut_rec| {
        var r = mut_rec;
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("app.local", r.hostname);
        try std.testing.expectEqual(@as(u16, 8080), r.port);
        try std.testing.expectEqual(@as(u8, 10), r.ips.items[0][0]);
    }

    const deleted_json =
        \\ {
        \\   "type": "DELETED",
        \\   "object": {
        \\     "metadata": {"name": "app", "namespace": "prod"}
        \\   }
        \\ }
    ;

    try watcher.handleIngressEventJson(deleted_json);
    try std.testing.expect(store.findByHostname("app.local") == null);
}
