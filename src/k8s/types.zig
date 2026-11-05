const std = @import("std");

pub const PortInfo = struct {
    port: u16,
};

pub const LoadBalancerIngress = struct {
    ip: ?[]const u8 = null,
    ports: ?[]PortInfo = null,
};

pub const LoadBalancerStatus = struct {
    ingress: ?[]LoadBalancerIngress = null,
};

pub const IngressStatus = struct {
    loadBalancer: ?LoadBalancerStatus = null,
};

pub const IngressRule = struct {
    host: ?[]const u8 = null,
};

pub const IngressSpec = struct {
    rules: ?[]IngressRule = null,
};

pub const ObjectMeta = struct {
    name: []const u8,
    namespace: ?[]const u8 = "default",
};

pub const Ingress = struct {
    metadata: ObjectMeta,
    spec: ?IngressSpec = null,
    status: ?IngressStatus = null,
};

pub const WatchEvent = struct {
    type: []const u8,
    object: Ingress,
};

pub const MdnsRecordSpec = struct {
    host: []const u8,
    ip: []const u8,
    port: ?u16 = 443,
    serviceType: ?[]const u8 = "_http._tcp.local.",
};

pub const MdnsRecord = struct {
    metadata: ObjectMeta,
    spec: MdnsRecordSpec,
};

pub const MdnsRecordWatchEvent = struct {
    type: []const u8,
    object: MdnsRecord,
};

test "parse ingress watch event json" {
    const allocator = std.testing.allocator;

    const event_json =
        \\ {
        \\   "type": "ADDED",
        \\   "object": {
        \\     "metadata": {
        \\       "name": "paperless-ingress",
        \\       "namespace": "paperless-system"
        \\     },
        \\     "spec": {
        \\       "rules": [
        \\         {"host": "paperless.local"}
        \\       ]
        \\     },
        \\     "status": {
        \\       "loadBalancer": {
        \\         "ingress": [
        \\           {
        \\             "ip": "192.168.1.120",
        \\             "ports": [
        \\               {"port": 443}
        \\             ]
        \\           }
        \\         ]
        \\       }
        \\     }
        \\   }
        \\ }
    ;

    var parsed = try std.json.parseFromSlice(WatchEvent, allocator, event_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ADDED", parsed.value.type);
    try std.testing.expectEqualStrings("paperless-ingress", parsed.value.object.metadata.name);
    try std.testing.expectEqualStrings("paperless.local", parsed.value.object.spec.?.rules.?[0].host.?);
    try std.testing.expectEqualStrings("192.168.1.120", parsed.value.object.status.?.loadBalancer.?.ingress.?[0].ip.?);
    try std.testing.expectEqual(@as(u16, 443), parsed.value.object.status.?.loadBalancer.?.ingress.?[0].ports.?[0].port);
}
