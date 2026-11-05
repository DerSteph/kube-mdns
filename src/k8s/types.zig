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
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
    labels: ?std.json.ArrayHashMap([]const u8) = null,

    pub fn getAnnotation(self: ObjectMeta, key: []const u8) ?[]const u8 {
        if (self.annotations) |ann| {
            return ann.map.get(key);
        }
        return null;
    }

    pub fn getLabel(self: ObjectMeta, key: []const u8) ?[]const u8 {
        if (self.labels) |lbl| {
            return lbl.map.get(key);
        }
        return null;
    }
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

// Gateway API HTTPRoute models
pub const HTTPRouteSpec = struct {
    hostnames: ?[][]const u8 = null,
};

pub const HTTPRoute = struct {
    metadata: ObjectMeta,
    spec: ?HTTPRouteSpec = null,
};

pub const HTTPRouteWatchEvent = struct {
    type: []const u8,
    object: HTTPRoute,
};

// Traefik IngressRoute models
pub const TraefikRoute = struct {
    match: ?[]const u8 = null,
};

pub const TraefikIngressRouteSpec = struct {
    routes: ?[]TraefikRoute = null,
};

pub const TraefikIngressRoute = struct {
    metadata: ObjectMeta,
    spec: ?TraefikIngressRouteSpec = null,
};

pub const TraefikIngressRouteWatchEvent = struct {
    type: []const u8,
    object: TraefikIngressRoute,
};

// CRD models
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

test "parse ingress with annotations" {
    const allocator = std.testing.allocator;

    const event_json =
        \\ {
        \\   "type": "ADDED",
        \\   "object": {
        \\     "metadata": {
        \\       "name": "annotated-ingress",
        \\       "namespace": "default",
        \\       "annotations": {
        \\         "mdns.net-pilgrim.dev/enabled": "true",
        \\         "mdns.net-pilgrim.dev/hostname": "custom.local",
        \\         "mdns.net-pilgrim.dev/ip": "192.168.1.150",
        \\         "mdns.net-pilgrim.dev/port": "8443",
        \\         "mdns.net-pilgrim.dev/service-type": "_https._tcp.local."
        \\       }
        \\     },
        \\     "spec": {
        \\       "rules": [{"host": "example.com"}]
        \\     }
        \\   }
        \\ }
    ;

    var parsed = try std.json.parseFromSlice(WatchEvent, allocator, event_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const meta = parsed.value.object.metadata;
    try std.testing.expectEqualStrings("custom.local", meta.getAnnotation("mdns.net-pilgrim.dev/hostname").?);
    try std.testing.expectEqualStrings("192.168.1.150", meta.getAnnotation("mdns.net-pilgrim.dev/ip").?);
    try std.testing.expectEqualStrings("8443", meta.getAnnotation("mdns.net-pilgrim.dev/port").?);
}
