pub const types = @import("dns/types.zig");
pub const packet = @import("dns/packet.zig");
pub const record_store = @import("store/record_store.zig");
pub const service = @import("mdns/service.zig");
pub const server = @import("mdns/server.zig");
pub const config = @import("config.zig");
pub const k8s_types = @import("k8s/types.zig");
pub const k8s_client = @import("k8s/client.zig");
pub const k8s_watcher = @import("k8s/watcher.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
