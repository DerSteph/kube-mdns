const std = @import("std");
const types = @import("../dns/types.zig");
const packet_mod = @import("../dns/packet.zig");
const record_store = @import("../store/record_store.zig");

pub const MdnsService = struct {
    allocator: std.mem.Allocator,
    store: *record_store.RecordStore,

    pub fn init(allocator: std.mem.Allocator, store: *record_store.RecordStore) MdnsService {
        return .{
            .allocator = allocator,
            .store = store,
        };
    }

    pub fn buildAnnouncementPacket(
        self: *MdnsService,
        rec: record_store.Record,
        is_goodbye: bool,
    ) !packet_mod.Packet {
        var packet = packet_mod.Packet.init(self.allocator);
        errdefer packet.deinit();

        const ttl: u32 = if (is_goodbye) 0 else types.DEFAULT_TTL;

        // Instance name: e.g. "paperless._http._tcp.local."
        var host_prefix = rec.hostname;
        if (std.mem.endsWith(u8, host_prefix, ".local")) {
            host_prefix = host_prefix[0 .. host_prefix.len - ".local".len];
        }

        const instance_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ host_prefix, rec.service_type });
        defer self.allocator.free(instance_name);

        // 1. PTR record: _http._tcp.local. -> paperless._http._tcp.local.
        const ptr_rec = types.ResourceRecord{
            .name = rec.service_type,
            .rtype = .PTR,
            .class = 1,
            .cache_flush = false, // shared record
            .ttl = ttl,
            .data = .{ .PTR = .{ .target = instance_name } },
        };
        try packet.answers.append(ptr_rec);

        // 2. SRV record: paperless._http._tcp.local. -> paperless.local. : port
        const srv_rec = types.ResourceRecord{
            .name = instance_name,
            .rtype = .SRV,
            .class = 1,
            .cache_flush = true,
            .ttl = ttl,
            .data = .{ .SRV = .{
                .priority = 0,
                .weight = 0,
                .port = rec.port,
                .target = rec.hostname,
            } },
        };
        try packet.answers.append(srv_rec);

        // 3. TXT record: empty TXT
        const txt_rec = types.ResourceRecord{
            .name = instance_name,
            .rtype = .TXT,
            .class = 1,
            .cache_flush = true,
            .ttl = ttl,
            .data = .{ .TXT = .{ .entries = &[_][]const u8{} } },
        };
        try packet.answers.append(txt_rec);

        // 4. A records for each IP
        for (rec.ips.items) |ip| {
            const a_rec = types.ResourceRecord{
                .name = rec.hostname,
                .rtype = .A,
                .class = 1,
                .cache_flush = true,
                .ttl = ttl,
                .data = .{ .A = .{ .ip = ip } },
            };
            try packet.answers.append(a_rec);
        }

        return packet;
    }

    pub fn handleQuery(
        self: *MdnsService,
        query: *const packet_mod.Packet,
    ) !?packet_mod.Packet {
        var response = packet_mod.Packet.init(self.allocator);
        errdefer response.deinit();

        for (query.questions.items) |q| {
            var trimmed_qname = q.name;
            if (std.mem.endsWith(u8, trimmed_qname, ".")) {
                trimmed_qname = trimmed_qname[0 .. trimmed_qname.len - 1];
            }

            // Check if asking for a hostname A record
            if (self.store.findByHostname(trimmed_qname)) |mut_rec| {
                var rec = mut_rec;
                defer rec.deinit(self.allocator);

                if (q.qtype == .A or q.qtype == .ANY) {
                    for (rec.ips.items) |ip| {
                        try response.answers.append(.{
                            .name = rec.hostname,
                            .rtype = .A,
                            .class = 1,
                            .cache_flush = true,
                            .ttl = types.DEFAULT_TTL,
                            .data = .{ .A = .{ .ip = ip } },
                        });
                    }
                }
            }

            // Check if asking for PTR of a service type
            var all_records = try self.store.getAllRecords();
            defer {
                for (all_records.items) |*r| r.deinit(self.allocator);
                all_records.deinit();
            }

            for (all_records.items) |rec| {
                var trimmed_st = rec.service_type;
                if (std.mem.endsWith(u8, trimmed_st, ".")) {
                    trimmed_st = trimmed_st[0 .. trimmed_st.len - 1];
                }

                if (std.ascii.eqlIgnoreCase(trimmed_qname, trimmed_st)) {
                    if (q.qtype == .PTR or q.qtype == .ANY) {
                        var host_prefix = rec.hostname;
                        if (std.mem.endsWith(u8, host_prefix, ".local")) {
                            host_prefix = host_prefix[0 .. host_prefix.len - ".local".len];
                        }
                        const instance_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ host_prefix, rec.service_type });
                        defer self.allocator.free(instance_name);

                        try response.answers.append(.{
                            .name = rec.service_type,
                            .rtype = .PTR,
                            .class = 1,
                            .cache_flush = false,
                            .ttl = types.DEFAULT_TTL,
                            .data = .{ .PTR = .{ .target = instance_name } },
                        });

                        try response.additionals.append(.{
                            .name = instance_name,
                            .rtype = .SRV,
                            .class = 1,
                            .cache_flush = true,
                            .ttl = types.DEFAULT_TTL,
                            .data = .{ .SRV = .{
                                .priority = 0,
                                .weight = 0,
                                .port = rec.port,
                                .target = rec.hostname,
                            } },
                        });

                        for (rec.ips.items) |ip| {
                            try response.additionals.append(.{
                                .name = rec.hostname,
                                .rtype = .A,
                                .class = 1,
                                .cache_flush = true,
                                .ttl = types.DEFAULT_TTL,
                                .data = .{ .A = .{ .ip = ip } },
                            });
                        }
                    }
                }
            }
        }

        if (response.answers.items.len == 0 and response.additionals.items.len == 0) {
            response.deinit();
            return null;
        }

        return response;
    }
};

test "mdns service build announcement" {
    const allocator = std.testing.allocator;

    var store = record_store.RecordStore.init(allocator);
    defer store.deinit();

    try store.addManual("paperless.local", "192.168.1.102", 8080, "_http._tcp.local.");

    var svc = MdnsService.init(allocator, &store);

    const rec = store.findByHostname("paperless.local").?;
    var r = rec;
    defer r.deinit(allocator);

    var packet = try svc.buildAnnouncementPacket(r, false);
    defer packet.deinit();

    // Should have PTR, SRV, TXT, A
    try std.testing.expectEqual(@as(usize, 4), packet.answers.items.len);
}
