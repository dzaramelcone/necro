//! Compiled radix trie router with per-method dispatch trees.
//! Immutable after compilation.
//!
//! Zero-copy path param extraction via slices into the original URL.
//! Static segments take priority over parameters.
//! Route conflict detection at addRoute time.
//! HEAD auto-generated from GET.
//!
//! 405 MethodNotAllowed with allowed methods when path matches but method doesn't.

const std = @import("std");
const testing = std.testing;

pub const Method = std.http.Method;

pub const PathParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const MatchResult = union(enum) {
    found: struct {
        handler_id: u32,
        params: [8]PathParam,
        param_count: u8,
    },
    not_found: void,
    method_not_allowed: struct {
        allowed: [9]bool,
    },
};

const Node = struct {
    prefix: []const u8,
    handler_id: ?u32,
    children: std.ArrayListUnmanaged(*Node),
    param_child: ?*Node,
    param_name: ?[]const u8,
    catchall_child: ?*Node,
    catchall_name: ?[]const u8,

    fn create(allocator: std.mem.Allocator, prefix: []const u8) !*Node {
        const owned_prefix = try allocator.dupe(u8, prefix);
        const node = try allocator.create(Node);
        node.* = .{
            .prefix = owned_prefix,
            .handler_id = null,
            .children = .{},
            .param_child = null,
            .param_name = null,
            .catchall_child = null,
            .catchall_name = null,
        };
        return node;
    }

    fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.destroy(allocator);
        }
        self.children.deinit(allocator);
        if (self.param_child) |pc| pc.destroy(allocator);
        if (self.catchall_child) |cc| cc.destroy(allocator);
        allocator.free(self.prefix);
        if (self.param_name) |n| allocator.free(n);
        if (self.catchall_name) |n| allocator.free(n);
        allocator.destroy(self);
    }
};

/// Segment from parsing a route pattern.
const Segment = struct {
    kind: enum { static, param, catchall },
    text: []const u8, // static text, or param name
};

/// Split a route pattern like "/users/{id}/posts/{rest:path}" into segments.
/// Returns segments on the stack (max 16).
fn parseSegments(path: []const u8) ![16]Segment {
    var segs: [16]Segment = undefined;
    var count: usize = 0;
    var i: usize = 0;

    if (path.len == 0 or path[0] != '/') return error.InvalidPath;

    while (i < path.len) {
        if (path[i] == '{') {
            // Find closing brace
            const start = i + 1;
            const end = std.mem.indexOfScalarPos(u8, path, start, '}') orelse return error.InvalidPath;
            const inside = path[start..end];

            // Check for catch-all ":path" suffix
            if (std.mem.indexOfScalar(u8, inside, ':')) |colon| {
                if (count >= 16) return error.TooManySegments;
                segs[count] = .{ .kind = .catchall, .text = inside[0..colon] };
                count += 1;
            } else {
                if (count >= 16) return error.TooManySegments;
                segs[count] = .{ .kind = .param, .text = inside };
                count += 1;
            }
            i = end + 1;
        } else {
            // Static segment: consume up to next '{' or end
            const start = i;
            while (i < path.len and path[i] != '{') : (i += 1) {}
            if (count >= 16) return error.TooManySegments;
            segs[count] = .{ .kind = .static, .text = path[start..i] };
            count += 1;
        }
    }

    // Fill rest with empty static segments as sentinel
    for (count..16) |j| {
        segs[j] = .{ .kind = .static, .text = "" };
    }

    return segs;
}

/// Count non-empty segments.
fn segmentCount(segs: [16]Segment) usize {
    for (segs, 0..) |s, i| {
        if (s.text.len == 0 and s.kind == .static) return i;
    }
    return 16;
}

pub const Router = struct {
    allocator: std.mem.Allocator,
    trees: [9]?*Node,
    route_count: usize,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .trees = .{null} ** 9,
            .route_count = 0,
        };
    }

    pub fn deinit(self: *Router) void {
        for (&self.trees) |*tree| {
            if (tree.*) |root| {
                root.destroy(self.allocator);
                tree.* = null;
            }
        }
    }

    pub fn addRoute(self: *Router, method: Method, path: []const u8, handler_id: u32) !void {
        const idx = @intFromEnum(method);
        if (self.trees[idx] == null) {
            self.trees[idx] = try Node.create(self.allocator, "");
        }
        const root = self.trees[idx].?;
        const segs = try parseSegments(path);
        const count = segmentCount(segs);
        try self.insertSegments(root, segs[0..count], handler_id);
        self.route_count += 1;
    }

    fn insertSegments(self: *Router, node: *Node, segments: []const Segment, handler_id: u32) !void {
        if (segments.len == 0) {
            if (node.handler_id != null) return error.RouteConflict;
            node.handler_id = handler_id;
            return;
        }

        const seg = segments[0];
        const rest = segments[1..];

        switch (seg.kind) {
            .static => {
                // Try to find an existing child with matching prefix
                const text = seg.text;
                for (node.children.items) |child| {
                    const common = commonPrefixLen(child.prefix, text);
                    if (common == 0) continue;

                    if (common == child.prefix.len and common == text.len) {
                        // Exact match - descend
                        return self.insertSegments(child, rest, handler_id);
                    }

                    if (common == child.prefix.len) {
                        // child.prefix is a prefix of text - create continuation
                        const suffix = text[common..];
                        // Insert remaining text as a segment
                        var new_segs: [16]Segment = undefined;
                        new_segs[0] = .{ .kind = .static, .text = suffix };
                        const rest_len = rest.len;
                        for (rest, 0..) |r, i| {
                            new_segs[1 + i] = r;
                        }
                        return self.insertSegments(child, new_segs[0 .. 1 + rest_len], handler_id);
                    }

                    if (common < child.prefix.len) {
                        // Split the existing node
                        const new_child = try Node.create(self.allocator, child.prefix[common..]);
                        new_child.handler_id = child.handler_id;
                        new_child.children = child.children;
                        new_child.param_child = child.param_child;
                        new_child.param_name = child.param_name;
                        new_child.catchall_child = child.catchall_child;
                        new_child.catchall_name = child.catchall_name;

                        // Replace prefix with owned copy of the common part
                        const old_prefix = child.prefix;
                        child.prefix = try self.allocator.dupe(u8, old_prefix[0..common]);
                        self.allocator.free(old_prefix);
                        child.handler_id = null;
                        child.children = .{};
                        child.param_child = null;
                        child.param_name = null;
                        child.catchall_child = null;
                        child.catchall_name = null;
                        try child.children.append(self.allocator, new_child);

                        if (common == text.len) {
                            return self.insertSegments(child, rest, handler_id);
                        } else {
                            const leaf = try Node.create(self.allocator, text[common..]);
                            try child.children.append(self.allocator, leaf);
                            return self.insertSegments(leaf, rest, handler_id);
                        }
                    }
                }
                // No matching child - create new
                const child = try Node.create(self.allocator, text);
                try node.children.append(self.allocator, child);
                return self.insertSegments(child, rest, handler_id);
            },
            .param => {
                if (node.param_child) |pc| {
                    // Check for name conflict
                    if (node.param_name) |existing| {
                        if (!std.mem.eql(u8, existing, seg.text)) return error.RouteConflict;
                    }
                    return self.insertSegments(pc, rest, handler_id);
                }
                const child = try Node.create(self.allocator, "");
                node.param_child = child;
                node.param_name = try self.allocator.dupe(u8, seg.text);
                return self.insertSegments(child, rest, handler_id);
            },
            .catchall => {
                if (node.catchall_child != null) return error.RouteConflict;
                const child = try Node.create(self.allocator, "");
                child.handler_id = handler_id;
                node.catchall_child = child;
                node.catchall_name = try self.allocator.dupe(u8, seg.text);
                // Catch-all must be terminal - ignore rest
                return;
            },
        }
    }

    pub fn match(self: *const Router, method: Method, path: []const u8) MatchResult {
        const idx = @intFromEnum(method);

        // Try exact method tree
        if (self.trees[idx]) |root| {
            var params: [8]PathParam = undefined;
            var param_count: u8 = 0;
            if (self.matchNode(root, path, &params, &param_count)) |hid| {
                return .{ .found = .{
                    .handler_id = hid,
                    .params = params,
                    .param_count = param_count,
                } };
            }
        }

        // HEAD falls back to GET
        if (method == .HEAD) {
            if (self.trees[@intFromEnum(Method.GET)]) |root| {
                var params: [8]PathParam = undefined;
                var param_count: u8 = 0;
                if (self.matchNode(root, path, &params, &param_count)) |hid| {
                    return .{ .found = .{
                        .handler_id = hid,
                        .params = params,
                        .param_count = param_count,
                    } };
                }
            }
        }

        // Check if any other method matches this path (405 vs 404)
        var allowed: [9]bool = .{false} ** 9;
        var any_match = false;
        for (0..9) |mi| {
            if (self.trees[mi]) |root| {
                var dummy_params: [8]PathParam = undefined;
                var dummy_count: u8 = 0;
                if (self.matchNode(root, path, &dummy_params, &dummy_count) != null) {
                    allowed[mi] = true;
                    any_match = true;
                }
            }
            // HEAD inherits GET
            if (mi == @intFromEnum(Method.HEAD)) {
                if (self.trees[@intFromEnum(Method.GET)]) |root| {
                    var dummy_params: [8]PathParam = undefined;
                    var dummy_count: u8 = 0;
                    if (self.matchNode(root, path, &dummy_params, &dummy_count) != null) {
                        allowed[mi] = true;
                        any_match = true;
                    }
                }
            }
        }

        if (any_match) {
            return .{ .method_not_allowed = .{ .allowed = allowed } };
        }

        return .not_found;
    }

    fn matchNode(_: *const Router, node: *const Node, path: []const u8, params: *[8]PathParam, param_count: *u8) ?u32 {
        return doMatchNode(node, path, params, param_count);
    }
};

fn doMatchNode(node: *const Node, path: []const u8, params: *[8]PathParam, param_count: *u8) ?u32 {
    var current = path;

    // Match this node's prefix
    if (node.prefix.len > 0) {
        if (current.len < node.prefix.len) return null;
        if (!std.mem.eql(u8, current[0..node.prefix.len], node.prefix)) return null;
        current = current[node.prefix.len..];
    }

    // If we've consumed the entire path, check for handler
    if (current.len == 0) {
        return node.handler_id;
    }

    // Try static children first (priority over params)
    for (node.children.items) |child| {
        if (child.prefix.len > 0 and current[0] == child.prefix[0]) {
            if (doMatchNode(child, current, params, param_count)) |hid| {
                return hid;
            }
        }
    }

    // Try param child - captures one segment (up to next '/')
    if (node.param_child) |pc| {
        const seg_end = std.mem.indexOfScalar(u8, current, '/') orelse current.len;
        if (seg_end > 0) {
            const value = current[0..seg_end];
            const remaining = current[seg_end..];
            if (param_count.* < 8) {
                params[param_count.*] = .{
                    .name = node.param_name.?,
                    .value = value,
                };
                param_count.* += 1;
                if (doMatchNode(pc, remaining, params, param_count)) |hid| {
                    return hid;
                }
                param_count.* -= 1; // backtrack
            }
        }
    }

    // Try catch-all; captures everything remaining
    if (node.catchall_child) |cc| {
        if (current.len > 0) {
            if (param_count.* < 8) {
                params[param_count.*] = .{
                    .name = node.catchall_name.?,
                    .value = current,
                };
                param_count.* += 1;
                return cc.handler_id;
            }
        }
    }

    return null;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    for (0..limit) |i| {
        if (a[i] != b[i]) return i;
    }
    return limit;
}

test "static route match" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users", 1);

    const result = router.match(.GET, "/users");
    switch (result) {
        .found => |f| {
            try testing.expectEqual(@as(u32, 1), f.handler_id);
            try testing.expectEqual(@as(u8, 0), f.param_count);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "param route match" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users/{id}", 2);

    const result = router.match(.GET, "/users/42");
    switch (result) {
        .found => |f| {
            try testing.expectEqual(@as(u32, 2), f.handler_id);
            try testing.expectEqual(@as(u8, 1), f.param_count);
            try testing.expectEqualStrings("id", f.params[0].name);
            try testing.expectEqualStrings("42", f.params[0].value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "catch-all route" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/files/{rest:path}", 3);

    const result = router.match(.GET, "/files/a/b/c");
    switch (result) {
        .found => |f| {
            try testing.expectEqual(@as(u32, 3), f.handler_id);
            try testing.expectEqual(@as(u8, 1), f.param_count);
            try testing.expectEqualStrings("rest", f.params[0].name);
            try testing.expectEqualStrings("a/b/c", f.params[0].value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "static priority over param" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users/{id}", 10);
    try router.addRoute(.GET, "/users/me", 11);

    // Static "/users/me" must win over param "/users/{id}"
    const result = router.match(.GET, "/users/me");
    switch (result) {
        .found => |f| try testing.expectEqual(@as(u32, 11), f.handler_id),
        else => return error.TestUnexpectedResult,
    }

    // Param still works for other values
    const result2 = router.match(.GET, "/users/42");
    switch (result2) {
        .found => |f| {
            try testing.expectEqual(@as(u32, 10), f.handler_id);
            try testing.expectEqualStrings("42", f.params[0].value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "not found" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users", 1);

    const result = router.match(.GET, "/nope");
    switch (result) {
        .not_found => {},
        else => return error.TestUnexpectedResult,
    }
}

test "method not allowed" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users", 1);

    const result = router.match(.POST, "/users");
    switch (result) {
        .method_not_allowed => |m| {
            try testing.expect(m.allowed[@intFromEnum(Method.GET)]);
            try testing.expect(!m.allowed[@intFromEnum(Method.POST)]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "HEAD auto-generated from GET" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users", 1);

    const result = router.match(.HEAD, "/users");
    switch (result) {
        .found => |f| try testing.expectEqual(@as(u32, 1), f.handler_id),
        else => return error.TestUnexpectedResult,
    }
}

test "multiple methods same path" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users", 1);
    try router.addRoute(.POST, "/users", 2);

    const get_result = router.match(.GET, "/users");
    switch (get_result) {
        .found => |f| try testing.expectEqual(@as(u32, 1), f.handler_id),
        else => return error.TestUnexpectedResult,
    }

    const post_result = router.match(.POST, "/users");
    switch (post_result) {
        .found => |f| try testing.expectEqual(@as(u32, 2), f.handler_id),
        else => return error.TestUnexpectedResult,
    }
}

test "param extraction is zero-copy" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users/{id}", 2);

    const url = "/users/42";
    const result = router.match(.GET, url);
    switch (result) {
        .found => |f| {
            // Value must point into the original url slice - zero copy
            try testing.expect(f.params[0].value.ptr == url.ptr + 7);
            try testing.expectEqual(@as(usize, 2), f.params[0].value.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "route conflict detection" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/users", 1);

    // Adding duplicate route should return error
    const result = router.addRoute(.GET, "/users", 2);
    try testing.expectError(error.RouteConflict, result);
}

test "three routes: /, /health, /greet/{name}" {
    var router = Router.init(testing.allocator);
    defer router.deinit();

    try router.addRoute(.GET, "/", 0);
    try router.addRoute(.GET, "/health", 1);
    try router.addRoute(.GET, "/greet/{name}", 2);

    // Match /
    switch (router.match(.GET, "/")) {
        .found => |f| try testing.expectEqual(@as(u32, 0), f.handler_id),
        else => return error.TestUnexpectedResult,
    }

    // Match /health
    switch (router.match(.GET, "/health")) {
        .found => |f| try testing.expectEqual(@as(u32, 1), f.handler_id),
        else => return error.TestUnexpectedResult,
    }

    // Match /greet/Dzara
    switch (router.match(.GET, "/greet/Dzara")) {
        .found => |f| {
            try testing.expectEqual(@as(u32, 2), f.handler_id);
            try testing.expectEqual(@as(u8, 1), f.param_count);
            try testing.expectEqualStrings("name", f.params[0].name);
            try testing.expectEqualStrings("Dzara", f.params[0].value);
        },
        else => return error.TestUnexpectedResult,
    }
}
// ---------------------------------------------------------------------------
// Known edge cases — these tests currently FAIL and document desired behavior.
// Each corresponds to a bug or design hole found during review.
// ---------------------------------------------------------------------------

// Currently: addRoute silently accepts an empty param name.
// Desired: reject at parse time with a clear error.
test "empty param name {} is rejected" {
    var router = Router.init(testing.allocator);
    defer router.deinit();
    try testing.expectError(error.EmptyParamName, router.addRoute(.GET, "/users/{}", 1));
}

// Currently: nested braces are parsed weirdly — the inner '{' is captured
// into the param name, and the dangling '}' becomes part of a static segment.
// Desired: reject at parse time.
test "nested braces in route pattern are rejected" {
    var router = Router.init(testing.allocator);
    defer router.deinit();
    try testing.expectError(error.InvalidPath, router.addRoute(.GET, "/files/{a{b}c}", 1));
}

// Currently: the route is accepted but is unreachable. The param captures
// greedily up to the next '/', so a trailing static segment on the same URL
// segment can never match. `/users/42suffix` fails to match `/users/{id}suffix`.
// Desired: either support it at match time with lookahead, or reject at parse
// time so the user knows their route is dead.
test "param followed by static on same segment is rejected" {
    var router = Router.init(testing.allocator);
    defer router.deinit();
    try testing.expectError(error.InvalidPath, router.addRoute(.GET, "/users/{id}suffix", 1));
}

// Currently: addRoute accepts routes with more than MAX_PARAMS (8) param
// placeholders. At match time the 9th+ param is silently dropped, producing a
// handler call with incomplete params. Desired: reject at addRoute time —
// the param count is fully determined by the static pattern, so it's
// computable without running any requests.
//
// Note: MAX_PARAMS (8) is distinct from the 16-segment parseSegments limit.
// A pattern with 9 params and short inter-param text stays under the segment
// limit but still exceeds the param limit, so the two checks must be separate.
test "too many params is rejected at addRoute" {
    var router = Router.init(testing.allocator);
    defer router.deinit();
    // 1 static + 9 params = 10 segments (under the 16-segment limit) but 9
    // params exceeds the 8-param MatchResult capacity.
    const pattern = "/{a}{b}{c}{d}{e}{f}{g}{h}{i}";
    try testing.expectError(error.TooManyParams, router.addRoute(.GET, pattern, 1));
}

// Currently: null bytes pass through unchallenged. `indexOfScalar(u8, path,
// '/')` does not stop on \0, so a param value can contain null bytes. If any
// downstream code treats this as a C string, \0 truncates it — classic CVE
// shape. Desired: match() rejects paths containing null bytes and returns
// not_found (or we add an explicit .invalid_path variant).
test "null byte in path does not produce a match" {
    var router = Router.init(testing.allocator);
    defer router.deinit();
    try router.addRoute(.GET, "/users/{id}", 1);
    const result = router.match(.GET, "/users/42\x00admin");
    switch (result) {
        .not_found => {},
        else => return error.TestUnexpectedResult,
    }
}

// TODO: Fuzzing
