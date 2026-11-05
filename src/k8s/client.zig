const std = @import("std");

pub const K8sClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    token: ?[]const u8 = null,
    use_tls: bool = true,
    http_client: std.http.Client,

    pub const WatchStream = struct {
        client: *K8sClient,
        req: std.http.Client.Request,
        auth_header: ?[]u8,
        extra_headers: []std.http.Header,
        header_buf: []u8,

        pub fn deinit(self: *WatchStream) void {
            self.req.deinit();
            if (self.auth_header) |h| self.client.allocator.free(h);
            self.client.allocator.free(self.extra_headers);
            self.client.allocator.free(self.header_buf);
            self.client.allocator.destroy(self);
        }

        pub fn readLine(self: *WatchStream, buf: []u8) !?[]const u8 {
            var reader = self.req.reader();
            return reader.readUntilDelimiterOrEof(buf, '\n');
        }
    };

    pub fn initInCluster(allocator: std.mem.Allocator) !K8sClient {
        _ = std.posix.getenv("KUBERNETES_SERVICE_HOST") orelse return error.NotInCluster;
        const port_str = std.posix.getenv("KUBERNETES_SERVICE_PORT") orelse "443";
        const port = try std.fmt.parseInt(u16, port_str, 10);

        // Standard in-cluster hostname covered by the Kubernetes apiserver TLS certificate SAN
        const host = "kubernetes.default.svc";

        // Read token
        const token_file = std.fs.openFileAbsolute(
            "/var/run/secrets/kubernetes.io/serviceaccount/token",
            .{},
        ) catch |err| {
            std.log.err("Failed to open serviceaccount token: {any}", .{err});
            return error.TokenNotFound;
        };
        defer token_file.close();

        const token_size = (try token_file.stat()).size;
        const token = try token_file.readToEndAlloc(allocator, @intCast(token_size));

        var client = std.http.Client{ .allocator = allocator };
        client.next_https_rescan_certs = false;

        // Load cluster CA certificate
        client.ca_bundle.addCertsFromFilePathAbsolute(
            allocator,
            "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
        ) catch |err| {
            std.log.warn("Failed to load in-cluster CA certificate: {any}", .{err});
        };

        return K8sClient{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .token = token,
            .use_tls = true,
            .http_client = client,
        };
    }

    pub fn initDebug(allocator: std.mem.Allocator, host: []const u8, port: u16) !K8sClient {
        return K8sClient{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .token = null,
            .use_tls = false,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *K8sClient) void {
        self.allocator.free(self.host);
        if (self.token) |tok| {
            self.allocator.free(tok);
        }
        self.http_client.deinit();
    }

    pub fn openWatchStream(self: *K8sClient, path: []const u8) !*WatchStream {
        const scheme = if (self.use_tls) "https" else "http";
        const url_str = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}", .{
            scheme,
            self.host,
            self.port,
            path,
        });
        defer self.allocator.free(url_str);

        const uri = try std.Uri.parse(url_str);

        var auth_header: ?[]u8 = null;
        if (self.token) |tok| {
            auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{tok});
        }
        errdefer if (auth_header) |h| self.allocator.free(h);

        var extra_headers_list = std.ArrayList(std.http.Header).init(self.allocator);
        defer extra_headers_list.deinit();

        try extra_headers_list.append(.{ .name = "Accept", .value = "application/json" });
        if (auth_header) |h| {
            try extra_headers_list.append(.{ .name = "Authorization", .value = h });
        }

        const extra_headers = try extra_headers_list.toOwnedSlice();
        errdefer self.allocator.free(extra_headers);

        const header_buf = try self.allocator.alloc(u8, 32768);
        errdefer self.allocator.free(header_buf);

        const ws = try self.allocator.create(WatchStream);
        errdefer self.allocator.destroy(ws);

        ws.* = WatchStream{
            .client = self,
            .req = undefined,
            .auth_header = auth_header,
            .extra_headers = extra_headers,
            .header_buf = header_buf,
        };

        ws.req = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = ws.header_buf,
            .extra_headers = ws.extra_headers,
            .keep_alive = false,
        });
        errdefer ws.req.deinit();

        try ws.req.send();
        try ws.req.wait();

        if (ws.req.response.status != .ok) {
            std.log.err("Kubernetes API returned non-OK status: {s}", .{@tagName(ws.req.response.status)});
            return error.HttpRequestFailed;
        }

        return ws;
    }
};
