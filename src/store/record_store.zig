const std = @import("std");

pub const Record = struct {
    id: []const u8,
    namespace: []const u8,
    name: []const u8,
    hostname: []const u8,
    ips: std.ArrayList([4]u8),
    port: u16,
    service_type: []const u8,
    is_manual: bool,

    pub fn clone(self: Record, allocator: std.mem.Allocator) !Record {
        var new_ips = std.ArrayList([4]u8).init(allocator);
        try new_ips.appendSlice(self.ips.items);
        return Record{
            .id = try allocator.dupe(u8, self.id),
            .namespace = try allocator.dupe(u8, self.namespace),
            .name = try allocator.dupe(u8, self.name),
            .hostname = try allocator.dupe(u8, self.hostname),
            .ips = new_ips,
            .port = self.port,
            .service_type = try allocator.dupe(u8, self.service_type),
            .is_manual = self.is_manual,
        };
    }

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.namespace);
        allocator.free(self.name);
        allocator.free(self.hostname);
        allocator.free(self.service_type);
        self.ips.deinit();
    }
};

pub const RecordStore = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    records: std.StringHashMap(Record),

    pub fn init(allocator: std.mem.Allocator) RecordStore {
        return RecordStore{
            .allocator = allocator,
            .records = std.StringHashMap(Record).init(allocator),
        };
    }

    pub fn deinit(self: *RecordStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.records.iterator();
        while (it.next()) |entry| {
            var rec = entry.value_ptr;
            rec.deinit(self.allocator);
        }
        self.records.deinit();
    }

    pub fn parseIp4(ip_str: []const u8) ![4]u8 {
        var it = std.mem.splitScalar(u8, ip_str, '.');
        var res: [4]u8 = undefined;
        var i: usize = 0;
        while (it.next()) |part| {
            if (i >= 4) return error.InvalidIp;
            res[i] = try std.fmt.parseInt(u8, part, 10);
            i += 1;
        }
        if (i != 4) return error.InvalidIp;
        return res;
    }

    pub fn addManual(
        self: *RecordStore,
        hostname: []const u8,
        ip: []const u8,
        port: u16,
        service_type: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ip_bytes = try parseIp4(ip);

        // Check if manual host with same hostname already exists
        if (self.records.getPtr(hostname)) |existing| {
            if (existing.is_manual) {
                // Update
                existing.ips.clearRetainingCapacity();
                try existing.ips.append(ip_bytes);
                existing.port = port;
                return;
            }
        }

        const id = try self.allocator.dupe(u8, hostname);
        errdefer self.allocator.free(id);

        var ips = std.ArrayList([4]u8).init(self.allocator);
        try ips.append(ip_bytes);

        const rec = Record{
            .id = id,
            .namespace = try self.allocator.dupe(u8, "manual"),
            .name = try self.allocator.dupe(u8, hostname),
            .hostname = try self.allocator.dupe(u8, hostname),
            .ips = ips,
            .port = port,
            .service_type = try self.allocator.dupe(u8, service_type),
            .is_manual = true,
        };

        try self.records.put(rec.hostname, rec);
    }

    pub fn addOrUpdateIngress(
        self: *RecordStore,
        namespace: []const u8,
        name: []const u8,
        hostname: []const u8,
        ips: []const [4]u8,
        port: u16,
        service_type: []const u8,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If defined by manual config, ignore Ingress definition (matching Python logic)
        if (self.records.get(hostname)) |existing| {
            if (existing.is_manual) {
                return false;
            }
        }

        const id = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ namespace, name, hostname });
        errdefer self.allocator.free(id);

        var ips_list = std.ArrayList([4]u8).init(self.allocator);
        try ips_list.appendSlice(ips);

        if (self.records.fetchRemove(hostname)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
        }

        const rec = Record{
            .id = id,
            .namespace = try self.allocator.dupe(u8, namespace),
            .name = try self.allocator.dupe(u8, name),
            .hostname = try self.allocator.dupe(u8, hostname),
            .ips = ips_list,
            .port = port,
            .service_type = try self.allocator.dupe(u8, service_type),
            .is_manual = false,
        };

        try self.records.put(rec.hostname, rec);
        return true;
    }

    pub fn removeIngress(
        self: *RecordStore,
        namespace: []const u8,
        name: []const u8,
    ) !std.ArrayList(Record) {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed = std.ArrayList(Record).init(self.allocator);

        var it = self.records.iterator();
        var keys_to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer keys_to_remove.deinit();

        while (it.next()) |entry| {
            const rec = entry.value_ptr;
            if (!rec.is_manual and
                std.mem.eql(u8, rec.namespace, namespace) and
                std.mem.eql(u8, rec.name, name))
            {
                try keys_to_remove.append(entry.key_ptr.*);
            }
        }

        for (keys_to_remove.items) |key| {
            if (self.records.fetchRemove(key)) |kv| {
                try removed.append(kv.value);
            }
        }

        return removed;
    }

    pub fn findByHostname(self: *RecordStore, hostname: []const u8) ?Record {
        self.mutex.lock();
        defer self.mutex.unlock();

        var trimmed = hostname;
        if (std.mem.endsWith(u8, trimmed, ".")) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        if (self.records.get(trimmed)) |rec| {
            return rec.clone(self.allocator) catch null;
        }
        return null;
    }

    pub fn getAllRecords(self: *RecordStore) !std.ArrayList(Record) {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.ArrayList(Record).init(self.allocator);
        var it = self.records.valueIterator();
        while (it.next()) |rec| {
            try list.append(try rec.clone(self.allocator));
        }
        return list;
    }
};

test "record store operations" {
    const allocator = std.testing.allocator;

    var store = RecordStore.init(allocator);
    defer store.deinit();

    // Add manual record
    try store.addManual("homeassistant.local", "192.168.1.101", 443, "_http._tcp.local.");

    // Ingress with same hostname should be ignored
    const ips = [_][4]u8{.{ 10, 0, 0, 1 }};
    const added = try store.addOrUpdateIngress("default", "ha", "homeassistant.local", &ips, 80, "_http._tcp.local.");
    try std.testing.expectEqual(false, added);

    // Ingress with different hostname should be accepted
    const added2 = try store.addOrUpdateIngress("default", "paperless", "paperless.local", &ips, 8080, "_http._tcp.local.");
    try std.testing.expectEqual(true, added2);

    const rec = store.findByHostname("paperless.local");
    try std.testing.expect(rec != null);
    if (rec) |mut_rec| {
        var r = mut_rec;
        defer r.deinit(allocator);
        try std.testing.expectEqualStrings("paperless.local", r.hostname);
        try std.testing.expectEqual(@as(u16, 8080), r.port);
    }

    // Remove ingress
    var removed = try store.removeIngress("default", "paperless");
    defer {
        for (removed.items) |*r| r.deinit(allocator);
        removed.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), removed.items.len);
    try std.testing.expect(store.findByHostname("paperless.local") == null);
}
