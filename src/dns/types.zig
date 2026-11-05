const std = @import("std");

pub const MDNS_IPV4 = "224.0.0.251";
pub const MDNS_PORT: u16 = 5353;
pub const DEFAULT_TTL: u32 = 120;
pub const DEFAULT_PORT: u16 = 443;
pub const DEFAULT_SERVICE_TYPE = "_http._tcp.local.";

pub const Type = enum(u16) {
    A = 1,
    PTR = 12,
    TXT = 16,
    SRV = 33,
    ANY = 255,
    _,

    pub fn fromInt(val: u16) Type {
        return @enumFromInt(val);
    }
};

pub const Class = enum(u16) {
    IN = 1,
    ANY = 255,
    _,
};

pub const Flags = struct {
    pub const RESPONSE: u16 = 0x8000;
    pub const AUTHORITATIVE: u16 = 0x0400;
    pub const CACHE_FLUSH: u16 = 0x8000;
};

pub const Header = struct {
    id: u16 = 0,
    flags: u16 = Flags.RESPONSE | Flags.AUTHORITATIVE,
    qdcount: u16 = 0,
    ancount: u16 = 0,
    nscount: u16 = 0,
    arcount: u16 = 0,

    pub fn write(self: Header, writer: anytype) !void {
        try writer.writeInt(u16, self.id, .big);
        try writer.writeInt(u16, self.flags, .big);
        try writer.writeInt(u16, self.qdcount, .big);
        try writer.writeInt(u16, self.ancount, .big);
        try writer.writeInt(u16, self.nscount, .big);
        try writer.writeInt(u16, self.arcount, .big);
    }

    pub fn read(reader: anytype) !Header {
        return Header{
            .id = try reader.readInt(u16, .big),
            .flags = try reader.readInt(u16, .big),
            .qdcount = try reader.readInt(u16, .big),
            .ancount = try reader.readInt(u16, .big),
            .nscount = try reader.readInt(u16, .big),
            .arcount = try reader.readInt(u16, .big),
        };
    }
};

pub const Question = struct {
    name: []const u8,
    qtype: Type,
    qclass: u16,
    unicast_response: bool,
};

pub const ARecord = struct {
    ip: [4]u8,
};

pub const PtrRecord = struct {
    target: []const u8,
};

pub const SrvRecord = struct {
    priority: u16 = 0,
    weight: u16 = 0,
    port: u16,
    target: []const u8,
};

pub const TxtRecord = struct {
    entries: []const []const u8,
};

pub const RecordData = union(Type) {
    A: ARecord,
    PTR: PtrRecord,
    TXT: TxtRecord,
    SRV: SrvRecord,
    ANY: void,
};

pub const ResourceRecord = struct {
    name: []const u8,
    rtype: Type,
    class: u16 = 1,
    cache_flush: bool = false,
    ttl: u32 = DEFAULT_TTL,
    data: RecordData,
};
