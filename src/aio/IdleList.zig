const std = @import("std");

const IdleList = @This();

list: std.DoublyLinkedList = .{},
ms: i64 = 30_000,

pub const Node = struct {
    node: std.DoublyLinkedList.Node = .{},
    deadline_ns: i64 = 0,
    linked: bool = false,
};

pub fn append(self: *IdleList, n: *Node, now_ns: i64) void {
    n.deadline_ns = now_ns + self.ms * std.time.ns_per_ms;
    self.list.append(&n.node);
    n.linked = true;
}

pub fn remove(self: *IdleList, n: *Node) void {
    if (!n.linked) return;
    self.list.remove(&n.node);
    n.linked = false;
}

pub fn bump(self: *IdleList, n: *Node, now_ns: i64) void {
    self.remove(n);
    self.append(n, now_ns);
}

pub fn nextDeadlineNs(self: *const IdleList) ?i64 {
    const first = self.list.first orelse return null;
    const n: *const Node = @fieldParentPtr("node", first);
    return n.deadline_ns;
}

pub fn expireOne(self: *IdleList, now_ns: i64) ?*Node {
    const first = self.list.first orelse return null;
    const n: *Node = @fieldParentPtr("node", first);
    if (n.deadline_ns > now_ns) return null;
    self.remove(n);
    return n;
}
