const std = @import("std");
const types = @import("types.zig");

pub const Packet = struct {
    header: types.Header,
    questions: std.ArrayList(types.Question),
    answers: std.ArrayList(types.ResourceRecord),
    additionals: std.ArrayList(types.ResourceRecord),

    pub fn init(allocator: std.mem.Allocator) Packet {
        return Packet{
            .header = .{},
            .questions = std.ArrayList(types.Question).init(allocator),
            .answers = std.ArrayList(types.ResourceRecord).init(allocator),
            .additionals = std.ArrayList(types.ResourceRecord).init(allocator),
        };
    }

    pub fn deinit(self: *Packet) void {
        self.questions.deinit();
        self.answers.deinit();
        self.additionals.deinit();
    }

    pub fn writeName(writer: anytype, name: []const u8) !void {
        var trimmed = name;
        if (std.mem.endsWith(u8, trimmed, ".")) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        var it = std.mem.splitScalar(u8, trimmed, '.');
        while (it.next()) |label| {
            if (label.len == 0) continue;
            if (label.len > 63) return error.LabelTooLong;
            try writer.writeByte(@intCast(label.len));
            try writer.writeAll(label);
        }
        try writer.writeByte(0);
    }

    pub fn parseName(allocator: std.mem.Allocator, buffer: []const u8, start_offset: *usize) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var offset = start_offset.*;
        var jumped = false;
        var end_offset: usize = 0;
        var max_jumps: usize = 5;

        while (offset < buffer.len) {
            const len_byte = buffer[offset];
            if (len_byte == 0) {
                if (!jumped) {
                    end_offset = offset + 1;
                }
                break;
            }

            // Check for compression pointer (top two bits set: 11xxxxxx)
            if ((len_byte & 0xC0) == 0xC0) {
                if (offset + 1 >= buffer.len) return error.TruncatedPacket;
                if (!jumped) {
                    end_offset = offset + 2;
                    jumped = true;
                }
                const b1: u16 = @intCast(len_byte & 0x3F);
                const b2: u16 = @intCast(buffer[offset + 1]);
                offset = (b1 << 8) | b2;
                max_jumps -= 1;
                if (max_jumps == 0) return error.TooManyCompressionJumps;
                continue;
            }

            offset += 1;
            const label_len: usize = len_byte;
            if (offset + label_len > buffer.len) return error.TruncatedPacket;

            if (result.items.len > 0) {
                try result.append('.');
            }
            try result.appendSlice(buffer[offset .. offset + label_len]);
            offset += label_len;
        }

        if (!jumped) {
            end_offset = offset + 1;
        }
        start_offset.* = end_offset;

        return result.toOwnedSlice();
    }

    pub fn writeRecord(writer: anytype, record: types.ResourceRecord) !void {
        try writeName(writer, record.name);
        try writer.writeInt(u16, @intFromEnum(record.rtype), .big);

        var class_val = record.class;
        if (record.cache_flush) {
            class_val |= types.Flags.CACHE_FLUSH;
        }
        try writer.writeInt(u16, class_val, .big);
        try writer.writeInt(u32, record.ttl, .big);

        // Precompute RDATA into a temporary buffer to get rdlength
        var rdata_buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&rdata_buf);
        const rdata_writer = fbs.writer();

        switch (record.data) {
            .A => |a| {
                try rdata_writer.writeAll(&a.ip);
            },
            .PTR => |ptr| {
                try writeName(rdata_writer, ptr.target);
            },
            .SRV => |srv| {
                try rdata_writer.writeInt(u16, srv.priority, .big);
                try rdata_writer.writeInt(u16, srv.weight, .big);
                try rdata_writer.writeInt(u16, srv.port, .big);
                try writeName(rdata_writer, srv.target);
            },
            .TXT => |txt| {
                if (txt.entries.len == 0) {
                    try rdata_writer.writeByte(0);
                } else {
                    for (txt.entries) |entry| {
                        try rdata_writer.writeByte(@intCast(entry.len));
                        try rdata_writer.writeAll(entry);
                    }
                }
            },
            .ANY => {},
        }

        const rdata_slice = fbs.getWritten();
        try writer.writeInt(u16, @intCast(rdata_slice.len), .big);
        try writer.writeAll(rdata_slice);
    }

    pub fn serialize(self: *const Packet, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        const writer = list.writer();

        var header = self.header;
        header.qdcount = @intCast(self.questions.items.len);
        header.ancount = @intCast(self.answers.items.len);
        header.nscount = 0;
        header.arcount = @intCast(self.additionals.items.len);

        try header.write(writer);

        for (self.questions.items) |q| {
            try writeName(writer, q.name);
            try writer.writeInt(u16, @intFromEnum(q.qtype), .big);
            var qclass = q.qclass;
            if (q.unicast_response) qclass |= 0x8000;
            try writer.writeInt(u16, qclass, .big);
        }

        for (self.answers.items) |a| {
            try writeRecord(writer, a);
        }

        for (self.additionals.items) |add| {
            try writeRecord(writer, add);
        }

        return list.toOwnedSlice();
    }

    pub fn parse(allocator: std.mem.Allocator, buffer: []const u8) !Packet {
        if (buffer.len < 12) return error.TruncatedPacket;

        var fbs = std.io.fixedBufferStream(buffer);
        const reader = fbs.reader();

        const header = try types.Header.read(reader);
        var packet = Packet.init(allocator);
        packet.header = header;
        errdefer packet.deinit();

        var offset: usize = 12;

        var i: usize = 0;
        while (i < header.qdcount) : (i += 1) {
            const name = try parseName(allocator, buffer, &offset);
            if (offset + 4 > buffer.len) return error.TruncatedPacket;

            const qtype_val = std.mem.readInt(u16, buffer[offset..][0..2], .big);
            const qclass_val = std.mem.readInt(u16, buffer[offset + 2 ..][0..2], .big);
            offset += 4;

            try packet.questions.append(.{
                .name = name,
                .qtype = types.Type.fromInt(qtype_val),
                .qclass = qclass_val & 0x7FFF,
                .unicast_response = (qclass_val & 0x8000) != 0,
            });
        }

        return packet;
    }
};

test "packet name serialization and parsing" {
    const allocator = std.testing.allocator;

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Packet.writeName(fbs.writer(), "paperless.local");
    const written = fbs.getWritten();

    var offset: usize = 0;
    const parsed_name = try Packet.parseName(allocator, written, &offset);
    defer allocator.free(parsed_name);

    try std.testing.expectEqualStrings("paperless.local", parsed_name);
}

test "packet build and serialize" {
    const allocator = std.testing.allocator;

    var packet = Packet.init(allocator);
    defer packet.deinit();

    try packet.answers.append(.{
        .name = "myhost.local",
        .rtype = .A,
        .class = 1,
        .cache_flush = true,
        .ttl = 120,
        .data = .{ .A = .{ .ip = .{ 192, 168, 1, 100 } } },
    });

    const serialized = try packet.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 12);
    // Header ancount should be 1
    const ancount = std.mem.readInt(u16, serialized[6..][0..2], .big);
    try std.testing.expectEqual(@as(u16, 1), ancount);
}
