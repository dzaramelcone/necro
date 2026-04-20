const std = @import("std");

pub const MAX_PARAMS = 8;
pub const MAX_HEADERS = 32;
pub const MAX_REQUEST_LEN = 64 * 1024;
const MAX_METHOD_LEN = 7;

pub const Error = error{
    Incomplete,
    BadMethod,
    BadUri,
    BadVersion,
    BadHeader,
    TooLong,
    TooManyHeaders,
    NoRoute,
};

pub const Param = struct {
    off: u16 = 0,
    len: u16 = 0,
};

pub const Header = struct {
    name_off: u16 = 0,
    name_len: u16 = 0,
    value_off: u16 = 0,
    value_len: u16 = 0,
};

pub const ParamNameSpan = struct {
    off: u16 = 0,
    len: u8 = 0,
};

pub const NO_HANDLER: u32 = std.math.maxInt(u32);

pub const Meta = struct {
    handler: u32 = NO_HANDLER,
    version_minor: u8 = 0,
    num_params: u8 = 0,
    num_headers: u8 = 0,
    keepalive: bool = true,
    uri_end: u16 = 0,
    query_off: u16 = 0,
    query_len: u16 = 0,
    content_length: i32 = -1,
    phase: Phase = .route,
    body_off: u16 = 0,

    params: [MAX_PARAMS]Param = undefined,
    headers: [MAX_HEADERS]Header = undefined,

    pub const Phase = enum(u8) { route, headers, done };

    pub inline fn pushParam(self: *Meta, off: u16, len: u16) void {
        if (self.num_params < MAX_PARAMS) {
            self.params[self.num_params] = .{ .off = off, .len = len };
            self.num_params += 1;
        }
    }

    pub inline fn pushHeader(self: *Meta, name_off: u16, name_len: u16, value_off: u16, value_len: u16) void {
        if (self.num_headers < MAX_HEADERS) {
            self.headers[self.num_headers] = .{ .name_off = name_off, .name_len = name_len, .value_off = value_off, .value_len = value_len };
            self.num_headers += 1;
        }
    }
};

const Node = struct {
    prefix_tag: u64 = 0,
    first_edge: u16 = 0,
    param_child: u16 = 0xFFFF,
    prefix_off: u16 = 0,
    prefix_len: u8 = 0,
    child_count: u8 = 0,
};

const Edge = struct {
    byte: u8 = 0,
    child: u16 = 0,
    _pad: u8 = 0,
};

pub const Router = struct {
    const MAX_ROUTES = 128;

    nodes: [512]Node = undefined,
    handlers: [512]u32 = @splat(NO_HANDLER),
    edges: [1024]Edge = undefined,
    prefix_buf: [4096]u8 = undefined,
    param_names: [128]ParamNameSpan = undefined,
    handler_param_start: [128]u16 = @splat(0),
    handler_param_count: [128]u8 = @splat(0),
    handler_method_len: [128]u8 = @splat(0),
    node_count: u16 = 0,
    edge_count: u16 = 0,
    prefix_len: u16 = 0,
    param_name_count: u16 = 0,
    route_buf: [MAX_ROUTES * 272]u8 = undefined,
    route_buf_len: u16 = 0,
    routes: [MAX_ROUTES]RouteEntry = undefined,
    route_count: u16 = 0,

    pub const RouteEntry = struct {
        path: []const u8,
        handler: u32,
    };

    pub fn addRoute(self: *Router, method: []const u8, path: []const u8, handler: u32) void {
        const off = self.route_buf_len;
        const total = method.len + 1 + path.len;
        @memcpy(self.route_buf[off..][0..method.len], method);
        self.route_buf[off + method.len] = ' ';
        @memcpy(self.route_buf[off + method.len + 1 ..][0..path.len], path);
        self.route_buf_len += @intCast(total);
        self.routes[self.route_count] = .{
            .path = self.route_buf[off..][0..total],
            .handler = handler,
        };
        self.route_count += 1;

        const hidx: usize = @intCast(handler);
        const pn_start = self.param_name_count;
        var count: u8 = 0;
        var i: usize = 0;
        while (i < path.len and count < MAX_PARAMS) {
            if (path[i] == '{') {
                const name_start = i + 1;
                i = name_start;
                while (i < path.len and path[i] != '}') : (i += 1) {}
                const pn_off = self.prefix_len;
                const pn_len: u8 = @intCast(i - name_start);
                @memcpy(self.prefix_buf[pn_off..][0..pn_len], path[name_start..i]);
                self.prefix_len += pn_len;
                self.param_names[self.param_name_count] = .{ .off = pn_off, .len = pn_len };
                self.param_name_count += 1;
                count += 1;
                if (i < path.len) i += 1;
            } else {
                i += 1;
            }
        }
        self.handler_param_start[hidx] = pn_start;
        self.handler_param_count[hidx] = count;
        self.handler_method_len[hidx] = @intCast(method.len);
    }

    pub fn compile(self: *Router) void {
        const entries = self.routes[0..self.route_count];
        var sorted: [512]usize = undefined;
        for (0..entries.len) |i| sorted[i] = i;
        const ctx = SortCtx{ .routes = entries };
        std.mem.sort(usize, sorted[0..entries.len], ctx, SortCtx.lessThan);
        _ = self.buildNode(entries, sorted[0..entries.len], 0);
    }

    pub fn fromEntries(entries: []const RouteEntry) Router {
        var self = Router{};
        for (entries) |e| {
            const sp = std.mem.indexOfScalar(u8, e.path, ' ') orelse continue;
            self.addRoute(e.path[0..sp], e.path[sp + 1 ..], e.handler);
        }
        self.compile();
        return self;
    }

    const SortCtx = struct {
        routes: []const RouteEntry,
        fn lessThan(self: SortCtx, a: usize, b: usize) bool {
            return std.mem.order(u8, self.routes[a].path, self.routes[b].path) == .lt;
        }
    };

    fn sharedPrefix(a: []const u8, b: []const u8) usize {
        const mx = @min(a.len, b.len);
        var i: usize = 0;
        while (i < mx and a[i] == b[i]) : (i += 1) {}
        return i;
    }

    fn buildNode(self: *Router, routes: []const RouteEntry, indices: []const usize, depth: usize) u16 {
        if (indices.len == 0) return 0xFFFF;

        const first_path = routes[indices[0]].path;

        var prefix_end = first_path.len;
        for (indices[1..]) |idx| {
            const s = sharedPrefix(first_path[depth..], routes[idx].path[depth..]);
            prefix_end = @min(prefix_end, depth + s);
        }

        if (prefix_end > first_path.len) prefix_end = first_path.len;

        var param_start: ?usize = null;
        if (std.mem.indexOfScalar(u8, first_path[depth..prefix_end], '{')) |ps| {
            param_start = depth + ps;
        }

        var actual_prefix_end = prefix_end;
        if (param_start) |ps| actual_prefix_end = ps;

        const prefix = first_path[depth..actual_prefix_end];

        var handler: u32 = NO_HANDLER;

        var child_groups: [128]struct { byte: u8, start: usize, end: usize } = undefined;
        var num_groups: usize = 0;
        var param_group_start: usize = 0;
        var param_group_end: usize = 0;
        var has_param_group = false;

        for (indices, 0..) |idx, ii| {
            const path = routes[idx].path;
            if (path.len == actual_prefix_end) {
                handler = routes[idx].handler;
                continue;
            }
            if (actual_prefix_end < path.len and path[actual_prefix_end] == '{') {
                if (!has_param_group) {
                    param_group_start = ii;
                    has_param_group = true;
                }
                param_group_end = ii + 1;
                continue;
            }
            const next_byte = path[actual_prefix_end];
            if (num_groups > 0 and child_groups[num_groups - 1].byte == next_byte) {
                child_groups[num_groups - 1].end = ii + 1;
            } else {
                child_groups[num_groups] = .{ .byte = next_byte, .start = ii, .end = ii + 1 };
                num_groups += 1;
            }
        }

        const node_idx = self.node_count;
        self.node_count += 1;
        self.nodes[node_idx] = .{
            .child_count = @intCast(num_groups),
        };
        self.handlers[node_idx] = handler;

        if (prefix.len >= 1 and prefix.len <= 8) {
            var pword_bytes: [8]u8 = .{0} ** 8;
            @memcpy(pword_bytes[0..prefix.len], prefix);
            self.nodes[node_idx].prefix_tag = @bitCast(pword_bytes);
            self.nodes[node_idx].prefix_len = @intCast(prefix.len);
        } else if (prefix.len > 8) {
            const off = self.prefix_len;
            @memcpy(self.prefix_buf[off..][0..prefix.len], prefix);
            self.prefix_len += @intCast(prefix.len);
            self.nodes[node_idx].prefix_off = off;
            self.nodes[node_idx].prefix_len = @intCast(prefix.len);
        }

        const first_edge = self.edge_count;
        self.nodes[node_idx].first_edge = first_edge;
        self.edge_count += @intCast(num_groups);
        for (0..num_groups) |g| {
            self.edges[first_edge + g] = .{ .byte = child_groups[g].byte };
        }

        for (0..num_groups) |g| {
            const group = child_groups[g];
            const child_idx = self.buildNode(routes, indices[group.start..group.end], actual_prefix_end);
            self.edges[first_edge + g].child = child_idx;
        }

        if (has_param_group) {
            const param_indices = indices[param_group_start..param_group_end];
            var skip_depth = actual_prefix_end;
            if (param_indices.len > 0) {
                const p = routes[param_indices[0]].path;
                if (skip_depth < p.len and p[skip_depth] == '{') {
                    const close = std.mem.indexOfScalar(u8, p[skip_depth..], '}');
                    if (close) |c| skip_depth += c + 1;
                }
            }

            var param_handler: u32 = NO_HANDLER;
            for (param_indices) |idx| {
                if (routes[idx].path.len == skip_depth) {
                    param_handler = routes[idx].handler;
                }
            }

            var param_child_groups: [64]struct { byte: u8, start: usize, end: usize } = undefined;
            var param_num_groups: usize = 0;
            for (param_indices, 0..) |idx, ii| {
                const path = routes[idx].path;
                if (path.len <= skip_depth) continue;
                const nb = path[skip_depth];
                if (param_num_groups > 0 and param_child_groups[param_num_groups - 1].byte == nb) {
                    param_child_groups[param_num_groups - 1].end = ii + 1;
                } else {
                    param_child_groups[param_num_groups] = .{ .byte = nb, .start = ii, .end = ii + 1 };
                    param_num_groups += 1;
                }
            }

            const param_node_idx = self.node_count;
            self.node_count += 1;
            self.nodes[param_node_idx] = .{
                .child_count = @intCast(param_num_groups),
            };
            self.handlers[param_node_idx] = param_handler;

            const param_first_edge = self.edge_count;
            self.nodes[param_node_idx].first_edge = param_first_edge;
            self.edge_count += @intCast(param_num_groups);
            for (0..param_num_groups) |g| {
                self.edges[param_first_edge + g] = .{ .byte = param_child_groups[g].byte };
            }

            for (0..param_num_groups) |g| {
                const group = param_child_groups[g];
                const child_idx = self.buildNode(routes, param_indices[group.start..group.end], skip_depth);
                self.edges[param_first_edge + g].child = child_idx;
            }

            self.nodes[node_idx].param_child = param_node_idx;
        }

        return node_idx;
    }

    inline fn isValidByte(c: u8) bool {
        return c -% 0x21 <= 0x5D;
    }

    fn scanQuery(buf: []const u8, start: usize) Error!usize {
        var i = start;
        while (i < buf.len and buf[i] != ' ') {
            if (!isValidByte(buf[i])) return error.BadUri;
            i += 1;
        }
        if (i >= buf.len) return error.Incomplete;
        return i;
    }

    pub fn parse(self: *const Router, buf: []const u8, meta: *Meta) Error!void {
        if (buf.len > MAX_REQUEST_LEN) return error.TooLong;

        if (meta.phase == .route) {
            const ue = try self.trieWalk(buf, meta);
            meta.uri_end = @intCast(ue);
            const pos: usize = ue + 1;
            if (pos + 10 > buf.len) return error.Incomplete;
            if (buf[pos] != 'H' or buf[pos + 1] != 'T' or buf[pos + 2] != 'T' or buf[pos + 3] != 'P' or
                buf[pos + 4] != '/' or buf[pos + 5] != '1' or buf[pos + 6] != '.') return error.BadVersion;
            if (buf[pos + 7] != '0' and buf[pos + 7] != '1') return error.BadVersion;
            meta.version_minor = buf[pos + 7] - '0';
            if (buf[pos + 8] != '\r' or buf[pos + 9] != '\n') return error.BadVersion;
            meta.keepalive = meta.version_minor >= 1;
            meta.phase = .headers;
            meta.body_off = @intCast(pos + 10);
        }

        if (meta.phase == .headers) {
            var pos: usize = meta.body_off;
            parseHeaders(buf, &pos, meta) catch |err| {
                meta.body_off = @intCast(pos);
                return err;
            };
            meta.phase = .done;
            meta.body_off = @intCast(pos);
        }
    }

    fn prefixMatch(self: *const Router, buf: []const u8, pos: usize, nd: Node) bool {
        const plen = nd.prefix_len;
        if (plen == 0) return true;
        if (pos + plen > buf.len) return false;
        if (plen <= 8) {
            const p = buf[pos..];
            const word: u64 = switch (plen) {
                1 => p[0],
                2 => @as(u16, @bitCast(p[0..2].*)),
                3 => @as(u16, @bitCast(p[0..2].*)) | (@as(u64, p[2]) << 16),
                4 => @as(u32, @bitCast(p[0..4].*)),
                5 => @as(u32, @bitCast(p[0..4].*)) | (@as(u64, p[4]) << 32),
                6 => @as(u32, @bitCast(p[0..4].*)) | (@as(u64, @as(u16, @bitCast(p[4..6].*))) << 32),
                7 => @as(u32, @bitCast(p[0..4].*)) | (@as(u64, @as(u16, @bitCast(p[4..6].*))) << 32) | (@as(u64, p[6]) << 48),
                8 => @bitCast(p[0..8].*),
                else => unreachable,
            };
            return word == nd.prefix_tag;
        }
        const prefix = self.prefix_buf[nd.prefix_off..][0..plen];
        for (0..plen) |k| {
            if (buf[pos + k] != prefix[k]) return false;
        }
        return true;
    }

    const NO_NODE: u16 = 0xFFFF;

    fn resolveHandler(self: *const Router, node: u16, meta: *Meta, pos: usize) Error!usize {
        if (self.handlers[node] != NO_HANDLER) {
            meta.handler = self.handlers[node];
            return pos;
        }
        return error.NoRoute;
    }

    fn trieWalk(self: *const Router, buf: []const u8, meta: *Meta) Error!usize {
        meta.num_params = 0;
        meta.query_off = 0;
        meta.query_len = 0;
        var node_idx: u16 = 0;
        var i: usize = 0;
        var fallback_param: u16 = NO_NODE;

        while (true) {
            if (i >= buf.len) {
                return error.Incomplete;
            }
            const nd = self.nodes[node_idx];

            if (nd.prefix_len > 0) {
                if (i + nd.prefix_len > buf.len) {
                    return error.Incomplete;
                }
                if (!self.prefixMatch(buf, i, nd)) {
                    if (fallback_param != NO_NODE) {
                        const fb = fallback_param;
                        const ps = i;
                        while (i < buf.len) {
                            const pc = buf[i];
                            if (pc == '/' or pc == ' ' or pc == '?') break;
                            if (!isValidByte(pc)) return error.BadUri;
                            i += 1;
                        }
                        if (i >= buf.len) {
                            return error.Incomplete;
                        }
                        meta.pushParam(@intCast(ps), @intCast(i - ps));
                        const fb_nd = self.nodes[fb];
                        if (buf[i] == ' ') return self.resolveHandler(fb, meta, i);
                        if (buf[i] == '?') {
                            meta.query_off = @intCast(i + 1);
                            i += 1;
                            i = scanQuery(buf, i) catch |err| {
                                return err;
                            };
                            meta.query_len = @intCast(i - meta.query_off);
                            return self.resolveHandler(fb, meta, i);
                        }
                        if (buf[i] == '/' and (fb_nd.child_count > 0 or fb_nd.param_child != NO_NODE)) {
                            node_idx = fb;
                            continue;
                        }
                        return error.NoRoute;
                    }
                    return error.NoRoute;
                }
                i += nd.prefix_len;
                if (i >= buf.len) return error.Incomplete;
            }
            fallback_param = NO_NODE;

            const c = buf[i];

            var found_child: u16 = NO_NODE;
            for (0..nd.child_count) |j| {
                const edge = self.edges[nd.first_edge + j];
                if (edge.byte == c) {
                    found_child = edge.child;
                    break;
                }
            }

            if (found_child != NO_NODE) {
                fallback_param = nd.param_child;
                node_idx = found_child;
                continue;
            }

            if (nd.param_child != NO_NODE) {
                const child_idx = nd.param_child;
                const ps = i;
                while (i < buf.len) {
                    const pc = buf[i];
                    if (pc == '/' or pc == ' ' or pc == '?') break;
                    if (!isValidByte(pc)) return error.BadUri;
                    i += 1;
                }
                if (i >= buf.len) {
                    return error.Incomplete;
                }
                meta.pushParam(@intCast(ps), @intCast(i - ps));
                if (buf[i] == ' ') return self.resolveHandler(child_idx, meta, i);
                if (buf[i] == '?') {
                    meta.query_off = @intCast(i + 1);
                    i += 1;
                    i = scanQuery(buf, i) catch |err| {
                        return err;
                    };
                    meta.query_len = @intCast(i - meta.query_off);
                    return self.resolveHandler(child_idx, meta, i);
                }
                node_idx = child_idx;
                continue;
            }

            if (c == ' ') return self.resolveHandler(node_idx, meta, i);
            if (c == '?') {
                meta.query_off = @intCast(i + 1);
                i += 1;
                i = scanQuery(buf, i) catch |err| {
                    return err;
                };
                meta.query_len = @intCast(i - meta.query_off);
                return self.resolveHandler(node_idx, meta, i);
            }

            if (!isValidByte(c)) {
                return if (i <= MAX_METHOD_LEN) error.BadMethod else error.BadUri;
            }
            return error.NoRoute;
        }
    }

    const vec_len: comptime_int = std.simd.suggestVectorLength(u8) orelse 0;
    const V = if (vec_len > 0) @Vector(vec_len, u8) else void;
    const BV = if (vec_len > 0) @Vector(vec_len, bool) else void;

    fn scanHeaderName(buf: []const u8, start: usize) Error!usize {
        var i = start;
        while (i < buf.len) {
            const c = buf[i];
            if (c == ':') return i;
            if (!isValidByte(c)) return error.BadHeader;
            i += 1;
        }
        return error.Incomplete;
    }

    fn scanHeaderValue(buf: []const u8, start: usize) Error!usize {
        var i = start;
        if (comptime vec_len > 0) {
            while (i + vec_len <= buf.len) {
                const chunk: V = buf[i..][0..vec_len].*;
                const printable: BV = @as(V, chunk -% @as(V, @splat(0x20))) < @as(V, @splat(0x5F));
                if (@reduce(.And, printable)) {
                    i += vec_len;
                    continue;
                }
                const idx = std.simd.firstTrue(~printable).?;
                i += idx;
                break;
            }
        }
        while (i < buf.len) {
            const c = buf[i];
            if (c == '\r') return i;
            if (c >= 0x20 and c < 0x7F) {
                i += 1;
                continue;
            }
            if (c == '\t') {
                i += 1;
                continue;
            }
            return error.BadHeader;
        }
        return error.Incomplete;
    }

    fn eqlLower(a: []const u8, comptime expected: []const u8) bool {
        if (a.len != expected.len) return false;
        inline for (0..expected.len) |i| {
            if ((a[i] | 0x20) != (expected[i] | 0x20)) return false;
        }
        return true;
    }

    fn parseHeaders(buf: []const u8, pos: *usize, meta: *Meta) Error!void {
        while (true) {
            if (pos.* >= buf.len) return error.Incomplete;
            if (buf[pos.*] == '\r') {
                if (pos.* + 1 >= buf.len) return error.Incomplete;
                if (buf[pos.* + 1] == '\n') {
                    pos.* += 2;
                    break;
                }
                return error.BadHeader;
            }
            if (meta.num_headers >= MAX_HEADERS) return error.TooManyHeaders;

            const name_start = pos.*;

            const colon_pos = scanHeaderName(buf, pos.*) catch |err| {
                if (err == error.Incomplete) pos.* = name_start;
                return err;
            };
            if (colon_pos == name_start) return error.BadHeader;

            var val_start = colon_pos + 1;
            if (val_start < buf.len and buf[val_start] == ' ') val_start += 1;

            const cr_pos = scanHeaderValue(buf, val_start) catch |err| {
                if (err == error.Incomplete) pos.* = name_start;
                return err;
            };

            if (cr_pos + 1 >= buf.len) {
                pos.* = name_start;
                return error.Incomplete;
            }
            if (buf[cr_pos + 1] != '\n') return error.BadHeader;

            if (cr_pos + 2 < buf.len and (buf[cr_pos + 2] == ' ' or buf[cr_pos + 2] == '\t'))
                return error.BadHeader;

            var value_end = cr_pos;
            while (value_end > val_start and (buf[value_end - 1] == ' ' or buf[value_end - 1] == '\t')) : (value_end -= 1) {}

            const name_len: u16 = @intCast(colon_pos - name_start);
            const value_len: u16 = @intCast(value_end - val_start);

            meta.pushHeader(@intCast(name_start), name_len, @intCast(val_start), value_len);

            const name = buf[name_start..colon_pos];
            const value = buf[val_start..value_end];
            if (name_len == 14 and eqlLower(name, "content-length")) {
                if (meta.content_length >= 0) return error.BadHeader;
                meta.content_length = std.fmt.parseInt(i32, value, 10) catch return error.BadHeader;
            } else if (name_len == 10 and eqlLower(name, "connection")) {
                if (eqlLower(value, "close")) {
                    meta.keepalive = false;
                } else if (eqlLower(value, "keep-alive")) {
                    meta.keepalive = true;
                }
            }

            pos.* = cr_pos + 2;
        }
    }
};

test "route simple GET" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /health", .handler = 0 },
    });
    var out = Meta{};
    out = .{};
    try r.parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
}

test "route with param" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /users/{id}", .handler = 0 },
    });
    const buf = "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("42", buf[out.params[0].off..][0..out.params[0].len]);
}

test "route with query string" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /search", .handler = 0 },
    });
    const buf = "GET /search?q=hello&page=1 HTTP/1.1\r\nHost: x\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    try std.testing.expectEqualStrings("q=hello&page=1", buf[out.query_off..][0..out.query_len]);
}

test "route with param and query" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /users/{id}", .handler = 0 },
    });
    var out = Meta{};
    out = .{};
    try r.parse("GET /users/42?fields=name HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expect(out.query_len > 0);
}

test "multiple routes disambiguate" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /users", .handler = 0 },
        .{ .path = "POST /users", .handler = 1 },
        .{ .path = "GET /users/{id}", .handler = 2 },
        .{ .path = "DELETE /users/{id}", .handler = 3 },
    });

    var out = Meta{};
    out = .{};
    try r.parse("GET /users HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);

    out = .{};
    try r.parse("POST /users HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);

    out = .{};
    try r.parse("GET /users/99 HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);

    out = .{};
    try r.parse("DELETE /users/99 HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 3), out.handler);
}

test "two params" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /posts/{id}/comments/{cid}", .handler = 0 },
    });
    const buf = "GET /posts/42/comments/7 HTTP/1.1\r\nHost: x\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u8, 2), out.num_params);
    try std.testing.expectEqualStrings("42", buf[out.params[0].off..][0..out.params[0].len]);
    try std.testing.expectEqualStrings("7", buf[out.params[1].off..][0..out.params[1].len]);
}

test "static child mismatch falls back to param child" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /posts/new", .handler = 1 },
        .{ .path = "GET /posts/{id}", .handler = 2 },
    });

    var out = Meta{};
    out = .{};
    try r.parse("GET /posts/nope HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);

    out = .{};
    try r.parse("GET /posts/new HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);

    out = .{};
    try r.parse("GET /posts/42 HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);
}

test "static descendant mismatch falls back into param subtree" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /posts/new/comments", .handler = 1 },
        .{ .path = "GET /posts/{id}/comments", .handler = 2 },
    });

    const buf = "GET /posts/42/comments HTTP/1.1\r\nHost: x\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("42", buf[out.params[0].off..][0..out.params[0].len]);

    out = .{};
    try r.parse("GET /posts/new/comments HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);
    try std.testing.expectEqual(@as(u8, 0), out.num_params);
}

test "nested fallback still captures later param" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /teams/{team}/members/bob", .handler = 1 },
        .{ .path = "GET /teams/{team}/members/{member}", .handler = 2 },
    });

    const buf = "GET /teams/alpha/members/bill HTTP/1.1\r\nHost: x\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);
    try std.testing.expectEqual(@as(u8, 2), out.num_params);
    try std.testing.expectEqualStrings("alpha", buf[out.params[0].off..][0..out.params[0].len]);
    try std.testing.expectEqualStrings("bill", buf[out.params[1].off..][0..out.params[1].len]);

    const static_buf = "GET /teams/alpha/members/bob HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(static_buf, &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("alpha", static_buf[out.params[0].off..][0..out.params[0].len]);
}

test "fallback param route preserves query string" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /posts/new/comments", .handler = 1 },
        .{ .path = "GET /posts/{id}/comments", .handler = 2 },
    });

    const buf = "GET /posts/42/comments?sort=asc&limit=10 HTTP/1.1\r\nHost: x\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("42", buf[out.params[0].off..][0..out.params[0].len]);
    try std.testing.expectEqualStrings("sort=asc&limit=10", buf[out.query_off..][0..out.query_len]);
}

test "nonterminal param route does not match shorter request" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /posts/{id}/comments", .handler = 0 },
    });

    var out = Meta{};
    try std.testing.expectError(error.NoRoute, r.parse("GET /posts/42 HTTP/1.1\r\nHost: x\r\n\r\n", &out));
}

test "compile order does not change matches" {
    const routes_a = [_]Router.RouteEntry{
        .{ .path = "GET /users/{id}", .handler = 0 },
        .{ .path = "GET /users/new", .handler = 1 },
        .{ .path = "GET /users/{id}/posts", .handler = 2 },
        .{ .path = "POST /users", .handler = 3 },
        .{ .path = "GET /health", .handler = 4 },
    };
    const routes_b = [_]Router.RouteEntry{
        .{ .path = "GET /health", .handler = 4 },
        .{ .path = "POST /users", .handler = 3 },
        .{ .path = "GET /users/{id}/posts", .handler = 2 },
        .{ .path = "GET /users/new", .handler = 1 },
        .{ .path = "GET /users/{id}", .handler = 0 },
    };

    const r1 = Router.fromEntries(&routes_a);
    const r2 = Router.fromEntries(&routes_b);
    try std.testing.expectEqual(r1.node_count, r2.node_count);
    try std.testing.expectEqual(r1.edge_count, r2.edge_count);

    var out1 = Meta{};
    var out2 = Meta{};

    const req_new = "GET /users/new HTTP/1.1\r\nHost: x\r\n\r\n";
    out1 = .{};
    try r1.parse(req_new, &out1);
    out2 = .{};
    try r2.parse(req_new, &out2);
    try std.testing.expectEqual(@as(u32, 1), out1.handler);
    try std.testing.expectEqual(out1.handler, out2.handler);
    try std.testing.expectEqual(out1.num_params, out2.num_params);

    const req_posts = "GET /users/42/posts HTTP/1.1\r\nHost: x\r\n\r\n";
    out1 = .{};
    try r1.parse(req_posts, &out1);
    out2 = .{};
    try r2.parse(req_posts, &out2);
    try std.testing.expectEqual(@as(u32, 2), out1.handler);
    try std.testing.expectEqual(out1.handler, out2.handler);
    try std.testing.expectEqual(@as(u8, 1), out1.num_params);
    try std.testing.expectEqual(out1.num_params, out2.num_params);
    try std.testing.expectEqualStrings("42", req_posts[out1.params[0].off..][0..out1.params[0].len]);
    try std.testing.expectEqualStrings("42", req_posts[out2.params[0].off..][0..out2.params[0].len]);

    const req_health = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n";
    out1 = .{};
    try r1.parse(req_health, &out1);
    out2 = .{};
    try r2.parse(req_health, &out2);
    try std.testing.expectEqual(out1.handler, out2.handler);
}

test "fromEntries preserves input indexes as handler ids" {
    const r = Router.fromEntries(&.{
        .{ .path = "POST /z", .handler = 0 },
        .{ .path = "GET /a/{id}", .handler = 1 },
        .{ .path = "GET /health", .handler = 2 },
        .{ .path = "DELETE /b/{id}/force", .handler = 3 },
    });

    var out = Meta{};
    out = .{};
    try r.parse("POST /z HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);

    const buf_a = "GET /a/99 HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(buf_a, &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);
    try std.testing.expectEqualStrings("99", buf_a[out.params[0].off..][0..out.params[0].len]);

    out = .{};
    try r.parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);

    const buf_b = "DELETE /b/7/force HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(buf_b, &out);
    try std.testing.expectEqual(@as(u32, 3), out.handler);
    try std.testing.expectEqualStrings("7", buf_b[out.params[0].off..][0..out.params[0].len]);
}

test "shared prefix exact routes remain distinct" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /post", .handler = 0 },
        .{ .path = "GET /posts", .handler = 1 },
        .{ .path = "GET /posts/{id}", .handler = 2 },
    });

    var out = Meta{};
    out = .{};
    try r.parse("GET /post HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    out = .{};
    try r.parse("GET /posts HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);

    const buf = "GET /posts/42 HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 2), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("42", buf[out.params[0].off..][0..out.params[0].len]);
}

test "static route beats param sibling at root" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /{slug}", .handler = 0 },
        .{ .path = "GET /health", .handler = 1 },
    });

    var out = Meta{};
    out = .{};
    try r.parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);
    try std.testing.expectEqual(@as(u8, 0), out.num_params);

    const buf = "GET /status HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("status", buf[out.params[0].off..][0..out.params[0].len]);
}

test "duplicate static route definitions with same handler are harmless" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /health", .handler = 0 },
        .{ .path = "GET /health", .handler = 0 },
        .{ .path = "POST /health", .handler = 1 },
    });

    var out = Meta{};
    out = .{};
    try r.parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    out = .{};
    try r.parse("POST /health HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);
}

test "duplicate param route definitions with same handler are harmless" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /users/{id}", .handler = 0 },
        .{ .path = "GET /users/{id}", .handler = 0 },
        .{ .path = "GET /users/{id}/posts", .handler = 1 },
    });

    var out = Meta{};
    const buf_user = "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(buf_user, &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("42", buf_user[out.params[0].off..][0..out.params[0].len]);

    const buf_posts = "GET /users/42/posts HTTP/1.1\r\nHost: x\r\n\r\n";
    out = .{};
    try r.parse(buf_posts, &out);
    try std.testing.expectEqual(@as(u32, 1), out.handler);
    try std.testing.expectEqual(@as(u8, 1), out.num_params);
    try std.testing.expectEqualStrings("42", buf_posts[out.params[0].off..][0..out.params[0].len]);
}

test "no matching route" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /health", .handler = 0 },
    });
    var out = Meta{};
    try std.testing.expectError(error.NoRoute, r.parse("GET /nonexistent HTTP/1.1\r\nHost: x\r\n\r\n", &out));
}

test "version HTTP/1.1" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    out = .{};
    try r.parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u8, 1), out.version_minor);
}

test "version HTTP/1.0" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    out = .{};
    try r.parse("GET /health HTTP/1.0\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u8, 0), out.version_minor);
}

test "bad version" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadVersion, r.parse("GET /health HTTP/2.0\r\nHost: x\r\n\r\n", &out));
}

test "parse headers" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    const buf = "GET /health HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u8, 2), out.num_headers);
    try std.testing.expectEqualStrings("Host", buf[out.headers[0].name_off..][0..out.headers[0].name_len]);
    try std.testing.expectEqualStrings("example.com", buf[out.headers[0].value_off..][0..out.headers[0].value_len]);
}

test "incremental parse completes when full head arrives" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    const buf = "GET /health?q=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";

    var out = Meta{};
    for (1..buf.len) |len| {
        if (r.parse(buf[0..len], &out)) |_| {
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expectEqual(error.Incomplete, err);
        }
    }

    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u32, 0), out.handler);
    try std.testing.expectEqualStrings("q=1", buf[out.query_off..][0..out.query_len]);
    try std.testing.expectEqual(@as(u8, 2), out.num_headers);
}

test "header without space after colon parses value" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    const buf = "GET /health HTTP/1.1\r\na:b\r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u8, 1), out.num_headers);
    try std.testing.expectEqualStrings("a", buf[out.headers[0].name_off..][0..out.headers[0].name_len]);
    try std.testing.expectEqualStrings("b", buf[out.headers[0].value_off..][0..out.headers[0].value_len]);
}

test "header whitespace-only value trims to empty" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    const buf = "GET /health HTTP/1.1\r\nc:  \r\n\r\n";
    var out = Meta{};
    out = .{};
    try r.parse(buf, &out);
    try std.testing.expectEqual(@as(u8, 1), out.num_headers);
    try std.testing.expectEqualStrings("c", buf[out.headers[0].name_off..][0..out.headers[0].name_len]);
    try std.testing.expectEqualStrings("", buf[out.headers[0].value_off..][0..out.headers[0].value_len]);
}

test "reject empty header name" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\n: ss\r\n\r\n", &out));
}

test "reject obs-fold with tab" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHost: x\r\n\tcontinued\r\n\r\n", &out));
}

test "too many headers" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const prefix = "GET /health HTTP/1.1\r\n";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    for (0..MAX_HEADERS + 1) |i| {
        const hdr = std.fmt.bufPrint(buf[pos..], "X-Hdr-{d}: val\r\n", .{i}) catch break;
        pos += hdr.len;
    }
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    var out = Meta{};
    try std.testing.expectError(error.TooManyHeaders, r.parse(buf[0..pos], &out));
}

test "reject null byte in URI" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expect(std.meta.isError(r.parse("GET /hea\x00lth HTTP/1.1\r\nHost: x\r\n\r\n", &out)));
}

test "reject control char in URI" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expect(std.meta.isError(r.parse("GET /hea\x01lth HTTP/1.1\r\nHost: x\r\n\r\n", &out)));
}

test "reject null byte in header" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHost: exam\x00ple\r\n\r\n", &out));
}

test "reject control char in header name" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHo\x01st: x\r\n\r\n", &out));
}

test "reject missing colon in header" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHostx\r\n\r\n", &out));
}

test "incomplete headers" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.Incomplete, r.parse("GET /health HTTP/1.1\r\nHost: x\r\n", &out));
}

test "fuzz: overlong fields" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var buf: [16384]u8 = undefined;
    @memcpy(buf[0..4], "GET ");
    @memset(buf[4..8196], '/');
    const suffix = " HTTP/1.1\r\n\r\n";
    @memcpy(buf[8196..][0..suffix.len], suffix);
    var out = Meta{};
    if (r.parse(buf[0 .. 8196 + suffix.len], &out)) {
        try std.testing.expectEqual(NO_HANDLER, out.handler);
    } else |_| {}
}

test "reject obs-fold" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHost: x\r\n val\r\n\r\n", &out));
}

test "incomplete request" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var out = Meta{};
    try std.testing.expectError(error.Incomplete, r.parse("GET /health HTT", &out));
}

test "request too long" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    var buf: [MAX_REQUEST_LEN + 100]u8 = undefined;
    @memset(&buf, 'A');
    var out = Meta{};
    try std.testing.expectError(error.TooLong, r.parse(&buf, &out));
}

test "fuzz: random garbage" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /health", .handler = 0 },
        .{ .path = "POST /api/v1/users", .handler = 1 },
        .{ .path = "GET /api/v1/users/{id}", .handler = 2 },
    });
    var rng = std.Random.DefaultPrng.init(0xDEADBEEF);
    var buf: [512]u8 = undefined;
    for (0..10000) |_| {
        const len = rng.random().intRangeAtMost(usize, 1, buf.len);
        rng.random().bytes(buf[0..len]);
        var out = Meta{};
        r.parse(buf[0..len], &out) catch {};
    }
}

test "fuzz: null at every position" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});
    const base = "GET /health HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";
    var buf: [128]u8 = undefined;
    var out = Meta{};
    for (0..base.len) |i| {
        @memcpy(buf[0..base.len], base);
        buf[i] = 0;
        r.parse(buf[0..base.len], &out) catch {};
    }
}

test "fuzz: bit flip mutations" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /health", .handler = 0 },
        .{ .path = "POST /api/v1/users/{id}", .handler = 1 },
    });
    const base = "GET /health HTTP/1.1\r\nHost: example.com\r\nContent-Type: text/plain\r\n\r\n";
    var buf: [128]u8 = undefined;
    for (0..base.len) |i| {
        for (0..8) |bit| {
            @memcpy(buf[0..base.len], base);
            buf[i] ^= @as(u8, 1) << @intCast(bit);
            var out = Meta{};
            r.parse(buf[0..base.len], &out) catch {};
        }
    }
}

test "fuzz: smuggling vectors" {
    const r = Router.fromEntries(&.{.{ .path = "GET /health", .handler = 0 }});

    var out = Meta{};
    out = .{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHost: x\rContent-Length: 0\r\n\r\n", &out));
    out = .{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", &out));
    out = .{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHo st: x\r\n\r\n", &out));
    out = .{};
    try std.testing.expectError(error.BadHeader, r.parse("GET /health HTTP/1.1\r\nHo\x7Fst: x\r\n\r\n", &out));
}

test "buffer size" {
    const r = Router.fromEntries(&.{
        .{ .path = "GET /health", .handler = 0 },
        .{ .path = "GET /api/v1/users", .handler = 1 },
        .{ .path = "GET /api/v1/users/{id}", .handler = 2 },
        .{ .path = "POST /api/v1/users", .handler = 3 },
        .{ .path = "DELETE /api/v1/users/{id}", .handler = 4 },
    });
    const req = "GET /api/v1/users/42 HTTP/1.1\r\nHost: x\r\n\r\n";
    const iterations: usize = switch (@import("builtin").mode) {
        .Debug => 10_000,
        .ReleaseSafe => 100_000,
        .ReleaseFast, .ReleaseSmall => 1_000_000,
    };
    var sink: usize = 0;
    var out = Meta{};
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        out = .{};
        try r.parse(req, &out);
        sink +%= out.handler;
    }
    std.mem.doNotOptimizeAway(sink);
    const ns = timer.lap();
    const ns_per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations));

    const total_bytes = @as(usize, r.node_count) * @sizeOf(Node) + @as(usize, r.edge_count) * @sizeOf(Edge);
    std.debug.print("\n5 routes compiled to {d} nodes, {d} edges ({d}B) ({d:.1}ns avg over {d} parses)\n", .{ r.node_count, r.edge_count, total_bytes, ns_per, iterations });
    try std.testing.expect(r.node_count < 50);
}
const route_defs = [_]Router.RouteEntry{
    .{ .path = "GET /api/v1/health", .handler = 0 },
    .{ .path = "GET /api/v1/ready", .handler = 1 },
    .{ .path = "GET /api/v1/metrics", .handler = 2 },
    .{ .path = "POST /api/v1/auth/login", .handler = 3 },
    .{ .path = "POST /api/v1/auth/logout", .handler = 4 },
    .{ .path = "POST /api/v1/auth/refresh", .handler = 5 },
    .{ .path = "GET /api/v1/auth/me", .handler = 6 },
    .{ .path = "GET /api/v1/users", .handler = 7 },
    .{ .path = "POST /api/v1/users", .handler = 8 },
    .{ .path = "GET /api/v1/users/{id}", .handler = 9 },
    .{ .path = "PUT /api/v1/users/{id}", .handler = 10 },
    .{ .path = "PATCH /api/v1/users/{id}", .handler = 11 },
    .{ .path = "DELETE /api/v1/users/{id}", .handler = 12 },
    .{ .path = "GET /api/v1/users/{id}/profile", .handler = 13 },
    .{ .path = "PUT /api/v1/users/{id}/profile", .handler = 14 },
    .{ .path = "GET /api/v1/users/{id}/posts", .handler = 15 },
    .{ .path = "GET /api/v1/users/{id}/comments", .handler = 16 },
    .{ .path = "GET /api/v1/users/{id}/followers", .handler = 17 },
    .{ .path = "GET /api/v1/users/{id}/following", .handler = 18 },
    .{ .path = "POST /api/v1/users/{id}/follow", .handler = 19 },
    .{ .path = "DELETE /api/v1/users/{id}/follow", .handler = 20 },
    .{ .path = "GET /api/v1/posts", .handler = 21 },
    .{ .path = "POST /api/v1/posts", .handler = 22 },
    .{ .path = "GET /api/v1/posts/{id}", .handler = 23 },
    .{ .path = "PUT /api/v1/posts/{id}", .handler = 24 },
    .{ .path = "PATCH /api/v1/posts/{id}", .handler = 25 },
    .{ .path = "DELETE /api/v1/posts/{id}", .handler = 26 },
    .{ .path = "POST /api/v1/posts/{id}/publish", .handler = 27 },
    .{ .path = "POST /api/v1/posts/{id}/unpublish", .handler = 28 },
    .{ .path = "GET /api/v1/posts/{id}/comments", .handler = 29 },
    .{ .path = "POST /api/v1/posts/{id}/comments", .handler = 30 },
    .{ .path = "GET /api/v1/posts/{id}/comments/{cid}", .handler = 31 },
    .{ .path = "PUT /api/v1/posts/{id}/comments/{cid}", .handler = 32 },
    .{ .path = "DELETE /api/v1/posts/{id}/comments/{cid}", .handler = 33 },
    .{ .path = "GET /api/v1/posts/{id}/likes", .handler = 34 },
    .{ .path = "POST /api/v1/posts/{id}/like", .handler = 35 },
    .{ .path = "DELETE /api/v1/posts/{id}/like", .handler = 36 },
    .{ .path = "POST /api/v1/posts/{id}/bookmark", .handler = 37 },
    .{ .path = "DELETE /api/v1/posts/{id}/bookmark", .handler = 38 },
    .{ .path = "GET /api/v1/tags", .handler = 39 },
    .{ .path = "GET /api/v1/tags/{slug}", .handler = 40 },
    .{ .path = "GET /api/v1/tags/{slug}/posts", .handler = 41 },
    .{ .path = "POST /api/v1/tags", .handler = 42 },
    .{ .path = "DELETE /api/v1/tags/{slug}", .handler = 43 },
    .{ .path = "GET /api/v1/categories", .handler = 44 },
    .{ .path = "POST /api/v1/categories", .handler = 45 },
    .{ .path = "GET /api/v1/categories/{id}", .handler = 46 },
    .{ .path = "PUT /api/v1/categories/{id}", .handler = 47 },
    .{ .path = "DELETE /api/v1/categories/{id}", .handler = 48 },
    .{ .path = "GET /api/v1/search", .handler = 49 },
    .{ .path = "GET /api/v1/search/users", .handler = 50 },
    .{ .path = "GET /api/v1/search/posts", .handler = 51 },
    .{ .path = "GET /api/v1/feed", .handler = 52 },
    .{ .path = "GET /api/v1/feed/trending", .handler = 53 },
    .{ .path = "GET /api/v1/feed/following", .handler = 54 },
    .{ .path = "GET /api/v1/feed/{id}", .handler = 55 },
    .{ .path = "GET /api/v1/notifications", .handler = 56 },
    .{ .path = "GET /api/v1/notifications/{id}", .handler = 57 },
    .{ .path = "PUT /api/v1/notifications/{id}/read", .handler = 58 },
    .{ .path = "POST /api/v1/notifications/read-all", .handler = 59 },
    .{ .path = "GET /api/v1/notifications/unread-count", .handler = 60 },
    .{ .path = "POST /api/v1/media/upload", .handler = 61 },
    .{ .path = "GET /api/v1/media/{id}", .handler = 62 },
    .{ .path = "DELETE /api/v1/media/{id}", .handler = 63 },
    .{ .path = "GET /api/v1/media/{id}/thumbnail", .handler = 64 },
    .{ .path = "GET /api/v1/admin/dashboard", .handler = 65 },
    .{ .path = "GET /api/v1/admin/users", .handler = 66 },
    .{ .path = "GET /api/v1/admin/users/{id}", .handler = 67 },
    .{ .path = "PUT /api/v1/admin/users/{id}/ban", .handler = 68 },
    .{ .path = "PUT /api/v1/admin/users/{id}/unban", .handler = 69 },
    .{ .path = "GET /api/v1/admin/posts", .handler = 70 },
    .{ .path = "DELETE /api/v1/admin/posts/{id}", .handler = 71 },
    .{ .path = "GET /api/v1/admin/reports", .handler = 72 },
    .{ .path = "GET /api/v1/admin/reports/{id}", .handler = 73 },
    .{ .path = "PUT /api/v1/admin/reports/{id}/resolve", .handler = 74 },
    .{ .path = "GET /api/v1/settings", .handler = 75 },
    .{ .path = "PUT /api/v1/settings", .handler = 76 },
    .{ .path = "GET /api/v1/settings/notifications", .handler = 77 },
    .{ .path = "PUT /api/v1/settings/notifications", .handler = 78 },
    .{ .path = "GET /api/v1/settings/privacy", .handler = 79 },
    .{ .path = "PUT /api/v1/settings/privacy", .handler = 80 },
    .{ .path = "GET /api/v1/webhooks", .handler = 81 },
    .{ .path = "POST /api/v1/webhooks", .handler = 82 },
    .{ .path = "GET /api/v1/webhooks/{id}", .handler = 83 },
    .{ .path = "PUT /api/v1/webhooks/{id}", .handler = 84 },
    .{ .path = "DELETE /api/v1/webhooks/{id}", .handler = 85 },
    .{ .path = "GET /api/v1/keys", .handler = 86 },
    .{ .path = "POST /api/v1/keys", .handler = 87 },
    .{ .path = "GET /api/v1/keys/{id}", .handler = 88 },
    .{ .path = "DELETE /api/v1/keys/{id}", .handler = 89 },
    .{ .path = "POST /api/v1/keys/{id}/rotate", .handler = 90 },
    .{ .path = "GET /api/v1/stats", .handler = 91 },
    .{ .path = "GET /api/v1/stats/daily", .handler = 92 },
    .{ .path = "GET /api/v1/stats/monthly", .handler = 93 },
    .{ .path = "GET /api/v1/export", .handler = 94 },
};

test "95 routes compile and match" {
    const r = Router.fromEntries(&route_defs);
    std.debug.print("\n95 routes compiled to {d} nodes, {d} edges\n", .{ r.node_count, r.edge_count });

    var buf: [512]u8 = undefined;
    for (route_defs, 0..) |route, expected| {
        var pos: usize = 0;
        var ri: usize = 0;
        while (ri < route.path.len) {
            if (route.path[ri] == '{') {
                const end = std.mem.indexOfScalar(u8, route.path[ri..], '}') orelse break;
                const param_name = route.path[ri + 1 .. ri + end];
                const val = if (std.mem.eql(u8, param_name, "cid")) "7" else if (std.mem.eql(u8, param_name, "slug")) "test" else "42";
                @memcpy(buf[pos..][0..val.len], val);
                pos += val.len;
                ri += end + 1;
            } else {
                buf[pos] = route.path[ri];
                pos += 1;
                ri += 1;
            }
        }
        const suffix = " HTTP/1.1\r\nHost: x\r\n\r\n";
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;

        var out = Meta{};
        r.parse(buf[0..pos], &out) catch |err| {
            std.debug.print("FAIL route {d}: '{s}' -> err={s}\n", .{ expected, route.path, @errorName(err) });
            return err;
        };
        try std.testing.expectEqual(@as(u32, @intCast(expected)), out.handler);
    }
}

test "parse+route bench (95 routes, 256 requests)" {
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;

    const pvals = [_][]const u8{ "1", "42", "99", "1337", "abc", "x7q", "usr01" };
    const qstrs = [_][]const u8{ "", "?page=1&limit=20", "?q=hello&sort=desc", "?fields=id,name" };

    const r = Router.fromEntries(&route_defs);

    const BATCH = 256;
    var reqs: [BATCH][512]u8 = undefined;
    var lens: [BATCH]usize = undefined;
    var rng = std.Random.DefaultPrng.init(12345);

    for (0..BATCH) |b| {
        const route_idx = rng.random().intRangeLessThan(usize, 0, route_defs.len);
        const route = route_defs[route_idx];
        var pos: usize = 0;
        var ri: usize = 0;
        while (ri < route.path.len) {
            if (route.path[ri] == '{') {
                const end = std.mem.indexOfScalar(u8, route.path[ri..], '}') orelse break;
                const val = pvals[rng.random().intRangeLessThan(usize, 0, pvals.len)];
                @memcpy(reqs[b][pos..][0..val.len], val);
                pos += val.len;
                ri += end + 1;
            } else {
                reqs[b][pos] = route.path[ri];
                pos += 1;
                ri += 1;
            }
        }
        const qs = qstrs[rng.random().intRangeLessThan(usize, 0, qstrs.len)];
        @memcpy(reqs[b][pos..][0..qs.len], qs);
        pos += qs.len;
        const ver = " HTTP/1.1\r\n";
        @memcpy(reqs[b][pos..][0..ver.len], ver);
        pos += ver.len;
        const host = "Host: api.example.com\r\n";
        @memcpy(reqs[b][pos..][0..host.len], host);
        pos += host.len;
        if (rng.random().intRangeLessThan(u32, 0, 3) != 0) {
            const auth = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3\r\n";
            @memcpy(reqs[b][pos..][0..auth.len], auth);
            pos += auth.len;
        }
        const accept = "Accept: application/json\r\n";
        @memcpy(reqs[b][pos..][0..accept.len], accept);
        pos += accept.len;
        if (rng.random().intRangeLessThan(u32, 0, 2) == 0) {
            const xreq = "X-Request-ID: req-550e8400-e29b\r\n";
            @memcpy(reqs[b][pos..][0..xreq.len], xreq);
            pos += xreq.len;
        }
        const enc = "Accept-Encoding: gzip, deflate\r\n";
        @memcpy(reqs[b][pos..][0..enc.len], enc);
        pos += enc.len;
        @memcpy(reqs[b][pos..][0..2], "\r\n");
        pos += 2;
        lens[b] = pos;
    }

    const N: usize = 1_000_000;
    var timer = try std.time.Timer.start();
    var sink: usize = 0;

    for (0..N) |_| {
        for (0..BATCH) |b| {
            var out = Meta{};
            r.parse(reqs[b][0..lens[b]], &out) catch continue;
            sink +%= out.handler +% out.num_headers +% out.num_params;
        }
    }
    std.mem.doNotOptimizeAway(sink);
    const ns = timer.lap();

    const total_reqs: f64 = @floatFromInt(N * BATCH);
    const ns_per: f64 = @as(f64, @floatFromInt(ns)) / total_reqs;
    const ghz: f64 = 3.5;

    var avg_len: f64 = 0;
    for (lens) |l| avg_len += @floatFromInt(l);
    avg_len /= BATCH;

    var avg_hdrs: f64 = 0;
    for (0..BATCH) |b| {
        var hdr_out = Meta{};
        r.parse(reqs[b][0..lens[b]], &hdr_out) catch continue;
        avg_hdrs += @floatFromInt(hdr_out.num_headers);
    }
    avg_hdrs /= BATCH;

    std.debug.print("\npacked buffer bench (95 routes, {d} reqs, avg {d:.0} bytes, {d:.1} hdrs, nodes={d} edges={d}):\n", .{
        BATCH, avg_len, avg_hdrs, r.node_count, r.edge_count,
    });
    std.debug.print("  {d:.1}ns  ~{d:.0} cy @{d:.1}GHz  {d:.0}M req/s\n", .{ ns_per, ns_per * ghz, ghz, 1_000.0 / ns_per });
}

test "parse+route bench zipfian (95 routes, 256 requests)" {
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;

    const pvals = [_][]const u8{ "1", "42", "99", "1337", "abc", "x7q", "usr01" };
    const qstrs = [_][]const u8{ "", "?page=1&limit=20", "?q=hello&sort=desc", "?fields=id,name" };

    const r = Router.fromEntries(&route_defs);

    const BATCH = 256;
    var reqs: [BATCH][512]u8 = undefined;
    var lens: [BATCH]usize = undefined;
    var rng = std.Random.DefaultPrng.init(77777);

    var zipf_weights: [route_defs.len]f64 = undefined;
    var total_weight: f64 = 0;
    for (0..route_defs.len) |i| {
        zipf_weights[i] = 1.0 / @as(f64, @floatFromInt(i + 1));
        total_weight += zipf_weights[i];
    }

    for (0..BATCH) |b| {
        var pick = rng.random().float(f64) * total_weight;
        var route_idx: usize = 0;
        for (0..route_defs.len) |i| {
            pick -= zipf_weights[i];
            if (pick <= 0) {
                route_idx = i;
                break;
            }
        }
        const route = route_defs[route_idx];
        var pos: usize = 0;
        var ri: usize = 0;
        while (ri < route.path.len) {
            if (route.path[ri] == '{') {
                const end = std.mem.indexOfScalar(u8, route.path[ri..], '}') orelse break;
                const val = pvals[rng.random().intRangeLessThan(usize, 0, pvals.len)];
                @memcpy(reqs[b][pos..][0..val.len], val);
                pos += val.len;
                ri += end + 1;
            } else {
                reqs[b][pos] = route.path[ri];
                pos += 1;
                ri += 1;
            }
        }
        const qs = qstrs[rng.random().intRangeLessThan(usize, 0, qstrs.len)];
        @memcpy(reqs[b][pos..][0..qs.len], qs);
        pos += qs.len;
        const ver = " HTTP/1.1\r\n";
        @memcpy(reqs[b][pos..][0..ver.len], ver);
        pos += ver.len;
        const host = "Host: api.example.com\r\n";
        @memcpy(reqs[b][pos..][0..host.len], host);
        pos += host.len;
        if (rng.random().intRangeLessThan(u32, 0, 3) != 0) {
            const auth = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3\r\n";
            @memcpy(reqs[b][pos..][0..auth.len], auth);
            pos += auth.len;
        }
        const accept = "Accept: application/json\r\n";
        @memcpy(reqs[b][pos..][0..accept.len], accept);
        pos += accept.len;
        if (rng.random().intRangeLessThan(u32, 0, 2) == 0) {
            const xreq = "X-Request-ID: req-550e8400-e29b\r\n";
            @memcpy(reqs[b][pos..][0..xreq.len], xreq);
            pos += xreq.len;
        }
        const enc = "Accept-Encoding: gzip, deflate\r\n";
        @memcpy(reqs[b][pos..][0..enc.len], enc);
        pos += enc.len;
        @memcpy(reqs[b][pos..][0..2], "\r\n");
        pos += 2;
        lens[b] = pos;
    }

    const N: usize = 1_000_000;
    var timer = try std.time.Timer.start();
    var sink: usize = 0;

    for (0..N) |_| {
        for (0..BATCH) |b| {
            var out = Meta{};
            r.parse(reqs[b][0..lens[b]], &out) catch continue;
            sink +%= out.handler +% out.num_headers +% out.num_params;
        }
    }
    std.mem.doNotOptimizeAway(sink);
    const ns = timer.lap();

    const total_reqs: f64 = @floatFromInt(N * BATCH);
    const ns_per: f64 = @as(f64, @floatFromInt(ns)) / total_reqs;
    const ghz: f64 = 3.5;

    var avg_len: f64 = 0;
    for (lens) |l| avg_len += @floatFromInt(l);
    avg_len /= BATCH;

    var avg_hdrs: f64 = 0;
    for (0..BATCH) |b| {
        var hdr_out = Meta{};
        r.parse(reqs[b][0..lens[b]], &hdr_out) catch continue;
        avg_hdrs += @floatFromInt(hdr_out.num_headers);
    }
    avg_hdrs /= BATCH;

    std.debug.print("\nzipfian bench (95 routes, {d} reqs, avg {d:.0} bytes, {d:.1} hdrs, nodes={d} edges={d}):\n", .{
        BATCH, avg_len, avg_hdrs, r.node_count, r.edge_count,
    });
    std.debug.print("  {d:.1}ns  ~{d:.0} cy @{d:.1}GHz  {d:.0}M req/s\n", .{ ns_per, ns_per * ghz, ghz, 1_000.0 / ns_per });
}
