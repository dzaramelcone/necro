//! Direct-to-buffer JSON serializer - zero allocation.
//! Writes JSON tokens straight into a caller-provided []u8 buffer.

const std = @import("std");
const builtin = @import("builtin");

pub const SerializeError = error{BufferOverflow};

pub const vec_len = std.simd.suggestVectorLength(u8) orelse 0;
const VecU8 = if (vec_len > 0) @Vector(vec_len, u8) else void;

fn repeatByte8(comptime b: u8) u64 {
    return @as(u64, b) *% 0x0101010101010101;
}

const lo7_mask: u64 = repeatByte8(0x7F);
const hi_mask: u64 = repeatByte8(0x80);

/// Comptime escape lookup table.
/// Non-zero entries: 2-byte escape packed into u16 (first byte in low bits).
const escape_lut: [256]u16 = blk: {
    var t: [256]u16 = @splat(0);
    t['"'] = pack2('\\', '"');
    t['\\'] = pack2('\\', '\\');
    t['\n'] = pack2('\\', 'n');
    t['\r'] = pack2('\\', 'r');
    t['\t'] = pack2('\\', 't');
    t[0x08] = pack2('\\', 'b');
    t[0x0c] = pack2('\\', 'f');
    break :blk t;
};

fn pack2(a: u8, b: u8) u16 {
    return @as(u16, a) | (@as(u16, b) << 8);
}

/// Write the escape sequence for byte `c` into `out`.
/// Returns the number of bytes written (2 or 6).
inline fn writeEscapeByte(out: []u8, c: u8) SerializeError!usize {
    const escaped = escape_lut[c];
    if (escaped != 0) {
        if (out.len < 2) return error.BufferOverflow;
        out[0] = @truncate(escaped);
        out[1] = @truncate(escaped >> 8);
        return 2;
    }
    // Control char < 0x20 without a named escape → \u00XX
    if (out.len < 6) return error.BufferOverflow;
    const hex = "0123456789ABCDEF";
    out[0] = '\\';
    out[1] = 'u';
    out[2] = '0';
    out[3] = '0';
    out[4] = hex[c >> 4];
    out[5] = hex[c & 0x0F];
    return 6;
}

/// Find the offset of the first byte in `input[start..]` that needs JSON escaping.
/// Returns input.len if no escapable byte is found.
inline fn findNextEscapable(input: []const u8, start: usize) usize {
    var pos = start;
    const n = input.len;

    // SIMD scan: vec_len bytes at a time
    if (comptime vec_len > 0) {
        const quote_v: VecU8 = @splat('"');
        const bs_v: VecU8 = @splat('\\');
        const ctrl_v: VecU8 = @splat(0x20);

        while (pos + vec_len <= n) {
            const v: VecU8 = input[pos..][0..vec_len].*;
            const needs_escape = (v == quote_v) | (v == bs_v) | (v < ctrl_v);
            if (@reduce(.Or, needs_escape)) {
                // Scan within this chunk for exact position
                for (0..vec_len) |j| {
                    const c = input[pos + j];
                    if (c < 0x20 or c == '"' or c == '\\') return pos + j;
                }
            }
            pos += vec_len;
        }
    }

    // SWAR scan: 8 bytes at a time
    while (pos + 8 <= n) {
        const swar = std.mem.readInt(u64, input[pos..][0..8], .little);
        const lo7 = swar & lo7_mask;
        const quote_s = (lo7 ^ repeatByte8('"')) +% lo7_mask;
        const backslash_s = (lo7 ^ repeatByte8('\\')) +% lo7_mask;
        const less_32 = (swar & repeatByte8(0x60)) +% lo7_mask;
        const combined = ~((quote_s & backslash_s & less_32) | swar) & hi_mask;

        if (combined != 0) {
            return pos + (@ctz(combined) >> 3);
        }
        pos += 8;
    }

    // Scalar tail
    while (pos < n) : (pos += 1) {
        const c = input[pos];
        if (c < 0x20 or c == '"' or c == '\\') return pos;
    }
    return n;
}

/// JSON string content escaper using find-then-memcpy (simdjson pattern).
/// Writes escaped content of `input` into `output` WITHOUT surrounding quotes.
/// Returns the number of bytes written.
pub fn writeJsonEscaped(output: []u8, input: []const u8) SerializeError!usize {
    var src: usize = 0;
    var dst: usize = 0;

    while (src < input.len) {
        // Find next byte that needs escaping
        const esc_pos = findNextEscapable(input, src);

        // Copy clean region
        const clean_len = esc_pos - src;
        if (clean_len > 0) {
            if (dst + clean_len > output.len) return error.BufferOverflow;
            @memcpy(output[dst..][0..clean_len], input[src..][0..clean_len]);
            dst += clean_len;
            src += clean_len;
        }

        // If we reached the end, done
        if (src >= input.len) break;

        // Escape one byte
        const esc_len = try writeEscapeByte(output[dst..], input[src]);
        dst += esc_len;
        src += 1;
    }

    return dst;
}

/// JSON string content escaper using speculative stores.
/// Faster on clean data, slower on dense escapes.
pub fn writeJsonEscapedSpeculative(output: []u8, input: []const u8) SerializeError!usize {
    var src: usize = 0;
    var dst: usize = 0;
    const n = input.len;

    // SIMD path: vec_len bytes at a time with speculative store
    if (comptime vec_len > 0) {
        const quote_v: VecU8 = @splat('"');
        const bs_v: VecU8 = @splat('\\');
        const ctrl_v: VecU8 = @splat(0x20);

        while (src + vec_len <= n) {
            if (dst + vec_len > output.len) return error.BufferOverflow;

            const chunk = input[src..][0..vec_len];
            const v: VecU8 = chunk.*;

            // Speculative store - write before checking
            output[dst..][0..vec_len].* = chunk.*;

            const needs_escape = (v == quote_v) | (v == bs_v) | (v < ctrl_v);

            if (!@reduce(.Or, needs_escape)) {
                dst += vec_len;
                src += vec_len;
                continue;
            }

            // Escape found - scalar scan to locate it.
            while (input[src] >= 0x20 and input[src] != '"' and input[src] != '\\') {
                dst += 1;
                src += 1;
            }
            const esc_len = try writeEscapeByte(output[dst..], input[src]);
            dst += esc_len;
            src += 1;
        }
    }

    // SWAR path: 8 bytes at a time with speculative store
    while (src + 8 <= n) {
        if (dst + 8 > output.len) return error.BufferOverflow;

        @memcpy(output[dst..][0..8], input[src..][0..8]);

        const swar = std.mem.readInt(u64, input[src..][0..8], .little);
        const lo7 = swar & lo7_mask;
        const quote_s = (lo7 ^ repeatByte8('"')) +% lo7_mask;
        const backslash_s = (lo7 ^ repeatByte8('\\')) +% lo7_mask;
        const less_32 = (swar & repeatByte8(0x60)) +% lo7_mask;
        const combined = ~((quote_s & backslash_s & less_32) | swar) & hi_mask;

        if (combined == 0) {
            dst += 8;
            src += 8;
            continue;
        }

        const offset = @ctz(combined) >> 3;
        src += offset;
        dst += offset;

        const esc_len = try writeEscapeByte(output[dst..], input[src]);
        dst += esc_len;
        src += 1;
    }

    // Scalar tail
    while (src < n) : (src += 1) {
        const c = input[src];
        if (c >= 0x20 and c != '"' and c != '\\') {
            if (dst >= output.len) return error.BufferOverflow;
            output[dst] = c;
            dst += 1;
        } else {
            const esc_len = try writeEscapeByte(output[dst..], c);
            dst += esc_len;
        }
    }

    return dst;
}

/// JSON string writer (with surrounding quotes).
/// Returns the number of bytes written including quotes.
pub fn writeJsonString(output: []u8, input: []const u8) SerializeError!usize {
    if (output.len < 2) return error.BufferOverflow;
    output[0] = '"';
    const content_len = try writeJsonEscapedSpeculative(output[1..], input);
    if (1 + content_len >= output.len) return error.BufferOverflow;
    output[1 + content_len] = '"';
    return 2 + content_len;
}

/// Direct-to-buffer JSON writer. Tracks position and emits commas automatically.
pub const Serializer = struct {
    buf: []u8,
    pos: usize = 0,
    depth: u16 = 0,
    /// Bit per nesting level: 0 = first element (no comma), 1 = needs comma.
    needs_comma: u64 = 0,

    pub fn init(buf: []u8) Serializer {
        return .{ .buf = buf };
    }

    pub fn beginObject(self: *Serializer) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeByte('{');
        self.pushLevel();
    }

    pub fn endObject(self: *Serializer) SerializeError!void {
        self.popLevel();
        try self.writeByte('}');
        self.markNotFirst();
    }

    pub fn beginArray(self: *Serializer) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeByte('[');
        self.pushLevel();
    }

    pub fn endArray(self: *Serializer) SerializeError!void {
        self.popLevel();
        try self.writeByte(']');
        self.markNotFirst();
    }

    /// Write an object key (followed by colon). Must be inside beginObject/endObject.
    pub fn key(self: *Serializer, k: []const u8) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(k);
        try self.writeByte(':');
        self.clearCommaFlag(); // value follows key, no comma before it
    }

    pub fn string(self: *Serializer, s: []const u8) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(s);
        self.markNotFirst();
    }

    pub fn integer(self: *Serializer, n: i64) SerializeError!void {
        try self.writeCommaIfNeeded();
        const result = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{n}) catch
            return SerializeError.BufferOverflow;
        self.pos += result.len;
        self.markNotFirst();
    }

    pub fn unsigned(self: *Serializer, n: u64) SerializeError!void {
        try self.writeCommaIfNeeded();
        const result = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{n}) catch
            return SerializeError.BufferOverflow;
        self.pos += result.len;
        self.markNotFirst();
    }

    pub fn float(self: *Serializer, f: f64) SerializeError!void {
        try self.writeCommaIfNeeded();
        const result = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{f}) catch
            return SerializeError.BufferOverflow;
        self.pos += result.len;
        self.markNotFirst();
    }

    pub fn boolean(self: *Serializer, b: bool) SerializeError!void {
        try self.writeCommaIfNeeded();
        const s = if (b) "true" else "false";
        try self.writeSlice(s);
        self.markNotFirst();
    }

    pub fn null_(self: *Serializer) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeSlice("null");
        self.markNotFirst();
    }

    /// Get the written JSON output.
    pub fn output(self: *const Serializer) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn beginValue(self: *Serializer) SerializeError!usize {
        try self.writeCommaIfNeeded();
        return self.pos;
    }

    pub fn finishValue(self: *Serializer) void {
        self.markNotFirst();
    }

    pub fn rewind(self: *Serializer, pos: usize) void {
        self.pos = pos;
    }

    // -- internal helpers --

    fn writeByte(self: *Serializer, b: u8) SerializeError!void {
        if (self.pos >= self.buf.len) return SerializeError.BufferOverflow;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn writeSlice(self: *Serializer, s: []const u8) SerializeError!void {
        if (self.pos + s.len > self.buf.len) return SerializeError.BufferOverflow;
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    fn writeEscapedString(self: *Serializer, s: []const u8) SerializeError!void {
        const written = try writeJsonString(self.buf[self.pos..], s);
        self.pos += written;
    }

    fn writeCommaIfNeeded(self: *Serializer) SerializeError!void {
        if (self.depth > 0 and (self.needs_comma & (@as(u64, 1) << @intCast(self.depth - 1))) != 0) {
            try self.writeByte(',');
        }
    }

    fn pushLevel(self: *Serializer) void {
        self.depth += 1;
        // Clear the bit for this new level (first element, no comma).
        self.needs_comma &= ~(@as(u64, 1) << @intCast(self.depth - 1));
    }

    fn popLevel(self: *Serializer) void {
        self.depth -= 1;
    }

    fn markNotFirst(self: *Serializer) void {
        if (self.depth > 0) {
            self.needs_comma |= @as(u64, 1) << @intCast(self.depth - 1);
        }
    }

    fn clearCommaFlag(self: *Serializer) void {
        if (self.depth > 0) {
            self.needs_comma &= ~(@as(u64, 1) << @intCast(self.depth - 1));
        }
    }
};

test "serialize simple object" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginObject();
    try s.key("name");
    try s.string("necro");
    try s.key("version");
    try s.integer(1);
    try s.endObject();

    try std.testing.expectEqualStrings("{\"name\":\"necro\",\"version\":1}", s.output());
}

test "serialize nested" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginObject();
    try s.key("user");
    try s.beginObject();
    try s.key("id");
    try s.integer(42);
    try s.key("name");
    try s.string("dzara");
    try s.endObject();
    try s.endObject();

    try std.testing.expectEqualStrings("{\"user\":{\"id\":42,\"name\":\"dzara\"}}", s.output());
}

test "serialize array" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginArray();
    try s.integer(1);
    try s.integer(2);
    try s.integer(3);
    try s.endArray();

    try std.testing.expectEqualStrings("[1,2,3]", s.output());
}

test "serialize string escaping" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.string("hello \"world\"\nline\\two");

    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline\\\\two\"", s.output());
}

test "buffer overflow returns error" {
    var buf: [5]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginObject();
    try s.key("a");
    const result = s.string("this is way too long for the buffer");
    try std.testing.expectError(SerializeError.BufferOverflow, result);
}

// ---------------------------------------------------------------------------
// SIMD / SWAR escape writer tests
// ---------------------------------------------------------------------------

test "writeJsonEscaped: clean ASCII" {
    var buf: [256]u8 = undefined;
    const len = try writeJsonEscaped(&buf, "hello world");
    try std.testing.expectEqualStrings("hello world", buf[0..len]);
}

test "writeJsonEscaped: quotes and backslashes" {
    var buf: [256]u8 = undefined;
    const len = try writeJsonEscaped(&buf, "say \"hello\" \\ yes");
    try std.testing.expectEqualStrings("say \\\"hello\\\" \\\\ yes", buf[0..len]);
}

test "writeJsonEscaped: control characters" {
    var buf: [256]u8 = undefined;
    const len = try writeJsonEscaped(&buf, "a\nb\rc\td");
    try std.testing.expectEqualStrings("a\\nb\\rc\\td", buf[0..len]);
}

test "writeJsonEscaped: \\b and \\f" {
    var buf: [256]u8 = undefined;
    const input = "x" ++ [_]u8{0x08} ++ "y" ++ [_]u8{0x0c} ++ "z";
    const len = try writeJsonEscaped(&buf, input);
    try std.testing.expectEqualStrings("x\\by\\fz", buf[0..len]);
}

test "writeJsonEscaped: \\u00XX for other control chars" {
    var buf: [256]u8 = undefined;
    const input = [_]u8{ 0x01, 0x1F };
    const len = try writeJsonEscaped(&buf, &input);
    try std.testing.expectEqualStrings("\\u0001\\u001F", buf[0..len]);
}

test "writeJsonEscaped: long clean string (hits SIMD path)" {
    var buf: [512]u8 = undefined;
    // 64 clean bytes - exercises the SIMD 16-byte loop multiple times
    const clean = "ABCDEFGHIJKLMNOP" ** 4;
    const len = try writeJsonEscaped(&buf, clean);
    try std.testing.expectEqualStrings(clean, buf[0..len]);
}

test "writeJsonEscaped: escape at SIMD boundary" {
    var buf: [512]u8 = undefined;
    // 15 clean bytes + quote at position 15 (within first 16-byte chunk)
    const input = "ABCDEFGHIJKLMNOrest";
    const escaped = "ABCDEFGHIJKLMNOrest";
    const len = try writeJsonEscaped(&buf, input);
    try std.testing.expectEqualStrings(escaped, buf[0..len]);

    // Now with a quote inside a 16-byte chunk
    const input2 = "ABCDEFGHIJ\"LMNOP";
    const len2 = try writeJsonEscaped(&buf, input2);
    try std.testing.expectEqualStrings("ABCDEFGHIJ\\\"LMNOP", buf[0..len2]);
}

test "writeJsonEscaped: escape at SWAR boundary" {
    var buf: [128]u8 = undefined;
    // 7 clean + escape (tests 8-byte SWAR path edge)
    const input = "1234567\"rest";
    const len = try writeJsonEscaped(&buf, input);
    try std.testing.expectEqualStrings("1234567\\\"rest", buf[0..len]);
}

test "writeJsonString: includes quotes" {
    var buf: [256]u8 = undefined;
    const len = try writeJsonString(&buf, "hello");
    try std.testing.expectEqualStrings("\"hello\"", buf[0..len]);
}

test "writeJsonString: escaping with quotes" {
    var buf: [256]u8 = undefined;
    const len = try writeJsonString(&buf, "a\"b");
    try std.testing.expectEqualStrings("\"a\\\"b\"", buf[0..len]);
}

test "writeJsonEscaped: empty input" {
    var buf: [256]u8 = undefined;
    const len = try writeJsonEscaped(&buf, "");
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "writeJsonEscaped: buffer overflow" {
    var buf: [3]u8 = undefined;
    const result = writeJsonEscaped(&buf, "this is way too long");
    try std.testing.expectError(SerializeError.BufferOverflow, result);
}

/// Byte-at-a-time JSON escape writer. No SIMD, no SWAR.
/// Used as ground truth for testing the accelerated version.
pub fn writeJsonEscapedScalar(output: []u8, input: []const u8) SerializeError!usize {
    var dst: usize = 0;
    for (input) |c| {
        if (c >= 0x20 and c != '"' and c != '\\') {
            if (dst >= output.len) return error.BufferOverflow;
            output[dst] = c;
            dst += 1;
        } else {
            const escaped = escape_lut[c];
            if (escaped != 0) {
                if (dst + 2 > output.len) return error.BufferOverflow;
                output[dst] = @truncate(escaped);
                output[dst + 1] = @truncate(escaped >> 8);
                dst += 2;
            } else {
                // Control char → \u00XX
                if (dst + 6 > output.len) return error.BufferOverflow;
                const hex = "0123456789ABCDEF";
                output[dst] = '\\';
                output[dst + 1] = 'u';
                output[dst + 2] = '0';
                output[dst + 3] = '0';
                output[dst + 4] = hex[c >> 4];
                output[dst + 5] = hex[c & 0x0F];
                dst += 6;
            }
        }
    }
    return dst;
}

test "writeJsonEscaped: exhaustive all 256 byte values" {
    // Each byte individually - SIMD vs scalar must agree
    var simd_buf: [8]u8 = undefined;
    var scalar_buf: [8]u8 = undefined;
    for (0..256) |i| {
        const byte = [_]u8{@intCast(i)};
        const simd_len = try writeJsonEscaped(&simd_buf, &byte);
        const scalar_len = try writeJsonEscapedScalar(&scalar_buf, &byte);
        try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
    }
}

test "writeJsonEscaped: multi-byte sequences match scalar" {
    // Pairs of bytes - catches cross-byte SWAR/SIMD interaction bugs
    var simd_buf: [16]u8 = undefined;
    var scalar_buf: [16]u8 = undefined;
    const interesting = [_]u8{ 0x00, 0x01, 0x08, 0x0c, 0x1F, 0x20, '"', '\\', 'A', 0x7F, 0x80, 0xFF };
    for (interesting) |a| {
        for (interesting) |b| {
            const input = [_]u8{ a, b };
            const simd_len = try writeJsonEscaped(&simd_buf, &input);
            const scalar_len = try writeJsonEscapedScalar(&scalar_buf, &input);
            try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
        }
    }
}

test "writeJsonEscaped: 17-byte string with escape at each position" {
    // Forces escape at every offset within a 16-byte SIMD chunk + tail
    var simd_buf: [256]u8 = undefined;
    var scalar_buf: [256]u8 = undefined;
    var input: [17]u8 = undefined;
    @memset(&input, 'X');

    for (0..17) |pos| {
        input[pos] = '"';
        const simd_len = try writeJsonEscaped(&simd_buf, &input);
        const scalar_len = try writeJsonEscapedScalar(&scalar_buf, &input);
        try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
        input[pos] = 'X'; // restore
    }
}

test "writeJsonEscaped: 9-byte string with escape at each position (SWAR)" {
    // Forces escape at every offset within an 8-byte SWAR chunk + tail
    var simd_buf: [128]u8 = undefined;
    var scalar_buf: [128]u8 = undefined;
    var input: [9]u8 = undefined;
    @memset(&input, 'A');

    for (0..9) |pos| {
        input[pos] = '\\';
        const simd_len = try writeJsonEscaped(&simd_buf, &input);
        const scalar_len = try writeJsonEscapedScalar(&scalar_buf, &input);
        try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
        input[pos] = 'A';
    }
}

test "writeJsonEscaped: high bytes (>= 0x80) pass through unchanged" {
    var simd_buf: [256]u8 = undefined;
    var scalar_buf: [256]u8 = undefined;
    // 32 bytes of high-bit-set values - must all pass through
    var input: [32]u8 = undefined;
    for (0..32) |i| input[i] = @intCast(0x80 + i);
    const simd_len = try writeJsonEscaped(&simd_buf, &input);
    const scalar_len = try writeJsonEscapedScalar(&scalar_buf, &input);
    try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
    // Also verify no escaping happened (output == input)
    try std.testing.expectEqualSlices(u8, &input, simd_buf[0..simd_len]);
}

test "writeJsonEscaped: dense escapes (worst case)" {
    var simd_buf: [512]u8 = undefined;
    var scalar_buf: [512]u8 = undefined;
    // Every byte needs escaping
    const input = "\"\\\"\\\"\\\"\\\"\\\"\\\"\\\"\\";
    const simd_len = try writeJsonEscaped(&simd_buf, input);
    const scalar_len = try writeJsonEscapedScalar(&scalar_buf, input);
    try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
}

test "writeJsonEscaped: adjacent control chars" {
    var simd_buf: [512]u8 = undefined;
    var scalar_buf: [512]u8 = undefined;
    // 32 consecutive control chars (0x00..0x1F)
    var input: [32]u8 = undefined;
    for (0..32) |i| input[i] = @intCast(i);
    const simd_len = try writeJsonEscaped(&simd_buf, input[0..32]);
    const scalar_len = try writeJsonEscapedScalar(&scalar_buf, input[0..32]);
    try std.testing.expectEqualStrings(scalar_buf[0..scalar_len], simd_buf[0..simd_len]);
}
