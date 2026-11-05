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

    pub const ANN_PREFIX = "mdns.net-pilgrim.dev";
    pub const ANN_ENABLED = "mdns.net-pilgrim.dev/enabled";
    pub const ANN_HOSTNAME = "mdns.net-pilgrim.dev/hostname";
    pub const ANN_IP = "mdns.net-pilgrim.dev/ip";
    pub const ANN_PORT = "mdns.net-pilgrim.dev/port";
    pub const ANN_SERVICE_TYPE = "mdns.net-pilgrim.dev/service-type";
    pub const LBL_PUBLISH = "mdns.net-pilgrim.dev/publish";

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
        const meta = ingress.metadata;
        const namespace = meta.namespace orelse "default";
        const name = meta.name;

        // Check explicit opt-out via annotation or label
        const enabled_ann = meta.getAnnotation(ANN_ENABLED);
        const publish_lbl = meta.getLabel(LBL_PUBLISH);
        const is_disabled = (enabled_ann != null and std.mem.eql(u8, enabled_ann.?, "false")) or
            (publish_lbl != null and std.mem.eql(u8, publish_lbl.?, "false"));

        if (std.mem.eql(u8, event.type, "DELETED") or is_disabled) {
            std.log.info("Ingress {s}/{s} deleted or disabled, unregistering...", .{ namespace, name });
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
            var ip_list = std.ArrayList([4]u8).init(self.allocator);
            defer ip_list.deinit();

            // Check if IP is provided via annotation
            if (meta.getAnnotation(ANN_IP)) |ann_ip| {
                if (record_store.RecordStore.parseIp4(ann_ip)) |parsed_ip| {
                    try ip_list.append(parsed_ip);
                } else |_| {}
            }

            // If no annotation IP, check loadBalancer status
            if (ip_list.items.len == 0) {
                const lb_ingresses = if (ingress.status) |st|
                    (if (st.loadBalancer) |lb| lb.ingress else null)
                else
                    null;

                if (lb_ingresses) |lbs| {
                    for (lbs) |lbi| {
                        if (lbi.ip) |ip_str| {
                            if (record_store.RecordStore.parseIp4(ip_str)) |parsed_ip| {
                                try ip_list.append(parsed_ip);
                            } else |_| {}
                        }
                    }
                }
            }

            if (ip_list.items.len == 0) {
                std.log.debug("Ingress {s}/{s} has no load balancer IP and no annotation IP, skipping...", .{ namespace, name });
                return;
            }

            // Resolve port: annotation > status > fallback
            var port: u16 = 443;
            if (meta.getAnnotation(ANN_PORT)) |ann_port_str| {
                port = std.fmt.parseInt(u16, ann_port_str, 10) catch self.selectPreferredPort(null);
            } else {
                const lb_ingresses = if (ingress.status) |st|
                    (if (st.loadBalancer) |lb| lb.ingress else null)
                else
                    null;
                const ports_list = if (lb_ingresses != null and lb_ingresses.?.len > 0) lb_ingresses.?[0].ports else null;
                port = self.selectPreferredPort(ports_list);
            }

            // Resolve service type: annotation > default
            const service_type = meta.getAnnotation(ANN_SERVICE_TYPE) orelse self.default_service_type;

            // Collect target hostnames
            var target_hostnames = std.ArrayList([]const u8).init(self.allocator);
            defer target_hostnames.deinit();

            // 1. Explicit hostname annotation
            if (meta.getAnnotation(ANN_HOSTNAME)) |ann_host| {
                try target_hostnames.append(ann_host);
            }

            // 2. Ingress rules hostnames
            const is_force_enabled = (enabled_ann != null and std.mem.eql(u8, enabled_ann.?, "true")) or
                (publish_lbl != null and std.mem.eql(u8, publish_lbl.?, "true"));

            if (ingress.spec) |s| {
                if (s.rules) |rules| {
                    for (rules) |rule| {
                        if (rule.host) |host| {
                            if (is_force_enabled or std.mem.endsWith(u8, host, ".local")) {
                                // Avoid duplicate if already added by annotation
                                var already_present = false;
                                for (target_hostnames.items) |h| {
                                    if (std.mem.eql(u8, h, host)) {
                                        already_present = true;
                                        break;
                                    }
                                }
                                if (!already_present) {
                                    try target_hostnames.append(host);
                                }
                            }
                        }
                    }
                }
            }

            if (target_hostnames.items.len == 0) return;

            for (target_hostnames.items) |host| {
                std.log.info("Publishing mDNS for Ingress {s}/{s}: {s} -> {d} ({s})", .{
                    namespace,
                    name,
                    host,
                    port,
                    service_type,
                });

                const updated = try self.store.addOrUpdateIngress(
                    namespace,
                    name,
                    host,
                    ip_list.items,
                    port,
                    service_type,
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

    pub fn handleHttpRouteEventJson(self: *Watcher, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(k8s_types.HTTPRouteWatchEvent, self.allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.debug("Skipping unparseable HTTPRoute watch line: {any}", .{err});
            return;
        };
        defer parsed.deinit();

        const event = parsed.value;
        const route = event.object;
        const meta = route.metadata;
        const namespace = meta.namespace orelse "default";
        const name = meta.name;

        const enabled_ann = meta.getAnnotation(ANN_ENABLED);
        const is_disabled = enabled_ann != null and std.mem.eql(u8, enabled_ann.?, "false");

        if (std.mem.eql(u8, event.type, "DELETED") or is_disabled) {
            std.log.info("HTTPRoute {s}/{s} deleted or disabled, unregistering...", .{ namespace, name });
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
            // HTTPRoute requires IP from annotation (or Gateway resolution)
            const ann_ip = meta.getAnnotation(ANN_IP) orelse return;
            const parsed_ip = record_store.RecordStore.parseIp4(ann_ip) catch return;
            const ips = [_][4]u8{parsed_ip};

            const port = if (meta.getAnnotation(ANN_PORT)) |p|
                (std.fmt.parseInt(u16, p, 10) catch (self.default_port orelse 443))
            else
                (self.default_port orelse 443);

            const service_type = meta.getAnnotation(ANN_SERVICE_TYPE) orelse self.default_service_type;

            var target_hostnames = std.ArrayList([]const u8).init(self.allocator);
            defer target_hostnames.deinit();

            if (meta.getAnnotation(ANN_HOSTNAME)) |h| {
                try target_hostnames.append(h);
            } else if (route.spec) |sp| {
                if (sp.hostnames) |hosts| {
                    for (hosts) |h| {
                        if (std.mem.endsWith(u8, h, ".local")) {
                            try target_hostnames.append(h);
                        }
                    }
                }
            }

            for (target_hostnames.items) |host| {
                std.log.info("Publishing mDNS for HTTPRoute {s}/{s}: {s} -> {d}", .{ namespace, name, host, port });
                const updated = try self.store.addOrUpdateIngress(namespace, name, host, &ips, port, service_type);
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

    pub fn handleTraefikIngressRouteEventJson(self: *Watcher, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(k8s_types.TraefikIngressRouteWatchEvent, self.allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.debug("Skipping unparseable Traefik IngressRoute watch line: {any}", .{err});
            return;
        };
        defer parsed.deinit();

        const event = parsed.value;
        const route = event.object;
        const meta = route.metadata;
        const namespace = meta.namespace orelse "default";
        const name = meta.name;

        if (std.mem.eql(u8, event.type, "DELETED")) {
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

        const ann_ip = meta.getAnnotation(ANN_IP) orelse return;
        const parsed_ip = record_store.RecordStore.parseIp4(ann_ip) catch return;
        const ips = [_][4]u8{parsed_ip};

        const port = if (meta.getAnnotation(ANN_PORT)) |p|
            (std.fmt.parseInt(u16, p, 10) catch 443)
        else
            443;

        const service_type = meta.getAnnotation(ANN_SERVICE_TYPE) orelse self.default_service_type;
        const host = meta.getAnnotation(ANN_HOSTNAME) orelse return;

        _ = try self.store.addOrUpdateIngress(namespace, name, host, &ips, port, service_type);
        if (self.store.findByHostname(host)) |mut_rec| {
            var rec = mut_rec;
            defer rec.deinit(self.allocator);
            if (self.server) |srv| {
                try srv.broadcastRecord(rec, false);
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

test "watcher with annotations: custom hostname and ip override" {
    const allocator = std.testing.allocator;

    var store = record_store.RecordStore.init(allocator);
    defer store.deinit();

    var client = try client_mod.K8sClient.initDebug(allocator, "127.0.0.1", 8001);
    defer client.deinit();

    var watcher = Watcher.init(
        allocator,
        client,
        &store,
        null,
        null,
        "_http._tcp.local.",
        false,
    );

    // Ingress with custom hostname annotation and IP override (no status IP)
    const json_annotated =
        \\ {
        \\   "type": "ADDED",
        \\   "object": {
        \\     "metadata": {
        \\       "name": "myapp",
        \\       "namespace": "default",
        \\       "annotations": {
        \\         "mdns.net-pilgrim.dev/hostname": "myapp.local",
        \\         "mdns.net-pilgrim.dev/ip": "192.168.1.50",
        \\         "mdns.net-pilgrim.dev/port": "8080",
        \\         "mdns.net-pilgrim.dev/service-type": "_https._tcp.local."
        \\       }
        \\     },
        \\     "spec": {
        \\       "rules": [{"host": "public.example.com"}]
        \\     }
        \\   }
        \\ }
    ;

    try watcher.handleIngressEventJson(json_annotated);

    const rec = store.findByHostname("myapp.local");
    try std.testing.expect(rec != null);
    if (rec) |mut_rec| {
        var r = mut_rec;
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("myapp.local", r.hostname);
        try std.testing.expectEqual(@as(u16, 8080), r.port);
        try std.testing.expectEqualStrings("_https._tcp.local.", r.service_type);
        try std.testing.expectEqual(@as(u8, 50), r.ips.items[0][3]);
    }

    // Opt-out annotation disabled test
    const json_disabled =
        \\ {
        \\   "type": "MODIFIED",
        \\   "object": {
        \\     "metadata": {
        \\       "name": "myapp",
        \\       "namespace": "default",
        \\       "annotations": {
        \\         "mdns.net-pilgrim.dev/enabled": "false"
        \\       }
        \\     }
        \\   }
        \\ }
    ;

    try watcher.handleIngressEventJson(json_disabled);
    try std.testing.expect(store.findByHostname("myapp.local") == null);
}

test "watcher with HTTPRoute event" {
    const allocator = std.testing.allocator;

    var store = record_store.RecordStore.init(allocator);
    defer store.deinit();

    var client = try client_mod.K8sClient.initDebug(allocator, "127.0.0.1", 8001);
    defer client.deinit();

    var watcher = Watcher.init(
        allocator,
        client,
        &store,
        null,
        null,
        "_http._tcp.local.",
        false,
    );

    const httproute_json =
        \\ {
        \\   "type": "ADDED",
        \\   "object": {
        \\     "metadata": {
        \\       "name": "gateway-app",
        \\       "namespace": "default",
        \\       "annotations": {
        \\         "mdns.net-pilgrim.dev/ip": "192.168.1.99",
        \\         "mdns.net-pilgrim.dev/port": "443"
        \\       }
        \\     },
        \\     "spec": {
        \\       "hostnames": ["route.local"]
        \\     }
        \\   }
        \\ }
    ;

    try watcher.handleHttpRouteEventJson(httproute_json);
    const rec = store.findByHostname("route.local");
    try std.testing.expect(rec != null);
    if (rec) |mut_rec| {
        var r = mut_rec;
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("route.local", r.hostname);
        try std.testing.expectEqual(@as(u8, 99), r.ips.items[0][3]);
    }
}
