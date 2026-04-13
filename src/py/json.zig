//! Serialize arbitrary Python values to JSON.

const std = @import("std");
const necro = @import("necro");
const ffi = @import("ffi.zig");
const json_serialize = necro.json;
const row = necro.pg.row;

const PyObject = ffi.PyObject;
const Serializer = json_serialize.Serializer;

const WriteError = ffi.PythonError || error{ BufferTooSmall, UnsupportedType };
const InternalError = WriteError;

fn writeString(s: *Serializer, obj: *PyObject) InternalError!void {
    const utf8 = try ffi.unicodeAsUTF8(obj);
    s.string(std.mem.span(utf8)) catch return error.BufferTooSmall;
}

fn writeInt(s: *Serializer, obj: *PyObject) InternalError!void {
    if (ffi.longAsLongLong(obj)) |signed| {
        s.integer(signed) catch return error.BufferTooSmall;
        return;
    }
    ffi.errClear();

    if (ffi.longAsUnsignedLongLong(obj)) |unsigned| {
        s.unsigned(unsigned) catch return error.BufferTooSmall;
        return;
    }
    return error.ConversionError;
}

fn writeFloat(s: *Serializer, obj: *PyObject) InternalError!void {
    const value = try ffi.floatAsDouble(obj);
    if (!std.math.isFinite(value)) {
        s.null_() catch return error.BufferTooSmall;
        return;
    }
    s.float(value) catch return error.BufferTooSmall;
}

fn writeArrayLike(
    s: *Serializer,
    obj: *PyObject,
    len: isize,
    getItem: *const fn (*PyObject, isize) ?*PyObject,
) InternalError!void {
    s.beginArray() catch return error.BufferTooSmall;
    var i: isize = 0;
    while (i < len) : (i += 1) {
        const item = getItem(obj, i) orelse return error.ConversionError;
        try writeValue(s, item);
    }
    s.endArray() catch return error.BufferTooSmall;
}

fn listGetItem(list: *PyObject, index: isize) ?*PyObject {
    return ffi.listGetItem(list, index);
}

fn tupleGetItem(tuple: *PyObject, index: isize) ?*PyObject {
    return ffi.tupleGetItem(tuple, index);
}

fn writeDict(s: *Serializer, obj: *PyObject) InternalError!void {
    s.beginObject() catch return error.BufferTooSmall;
    var iter = ffi.DictIter{};
    while (iter.next(obj)) {
        const key_obj = iter.key orelse return error.ConversionError;
        if (!ffi.isString(key_obj)) return error.UnsupportedType;
        const key_utf8 = try ffi.unicodeAsUTF8(key_obj);
        s.key(std.mem.span(key_utf8)) catch return error.BufferTooSmall;
        try writeValue(s, iter.value.?);
    }
    s.endObject() catch return error.BufferTooSmall;
}

fn tryWriteRowLike(s: *Serializer, obj: *PyObject) InternalError!bool {
    if (!row.isRow(obj)) return false;
    const start = s.beginValue() catch return error.BufferTooSmall;
    const written = row.serializeOne(obj, s.buf[s.pos..]) catch {
        s.rewind(start);
        return false;
    };
    s.pos += written;
    s.finishValue();
    return true;
}

fn tryWriteModelDump(s: *Serializer, obj: *PyObject) InternalError!bool {
    const callable = try ffi.getAttrOptional(obj, "model_dump");
    if (callable == null) return false;
    defer ffi.decref(callable.?);

    const dumped = try ffi.callNoArgs(callable.?);
    defer ffi.decref(dumped);
    try writeValue(s, dumped);
    return true;
}

fn writeExactValue(s: *Serializer, obj: *PyObject) InternalError!bool {
    if (ffi.isNone(obj)) {
        s.null_() catch return error.BufferTooSmall;
        return true;
    }
    if (ffi.isExactInt(obj)) { try writeInt(s, obj); return true; }
    if (ffi.isExactBool(obj)) { s.boolean(try ffi.objectIsTrue(obj)) catch return error.BufferTooSmall; return true; }
    if (ffi.isExactFloat(obj)) { try writeFloat(s, obj); return true; }
    if (ffi.isExactStr(obj)) { try writeString(s, obj); return true; }
    if (ffi.isExactList(obj)) {
        const len = ffi.listSize(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &listGetItem);
        return true;
    }
    if (ffi.isExactDict(obj)) { try writeDict(s, obj); return true; }
    if (ffi.isExactTuple(obj)) {
        const len = ffi.tupleSize(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &tupleGetItem);
        return true;
    }
    return false;
}

fn writeFallbackValue(s: *Serializer, obj: *PyObject) InternalError!bool {
    if (ffi.isBool(obj)) { s.boolean(try ffi.objectIsTrue(obj)) catch return error.BufferTooSmall; return true; }
    if (ffi.isInt(obj)) { try writeInt(s, obj); return true; }
    if (ffi.isFloat(obj)) { try writeFloat(s, obj); return true; }
    if (ffi.isString(obj)) { try writeString(s, obj); return true; }
    if (ffi.isList(obj)) {
        const len = ffi.listSize(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &listGetItem);
        return true;
    }
    if (ffi.isDict(obj)) { try writeDict(s, obj); return true; }
    if (ffi.isTuple(obj)) {
        const len = ffi.tupleSize(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &tupleGetItem);
        return true;
    }
    return false;
}

fn writeValue(s: *Serializer, obj: *PyObject) InternalError!void {
    if (try writeExactValue(s, obj)) return;
    if (try tryWriteRowLike(s, obj)) return;
    if (try tryWriteModelDump(s, obj)) return;
    if (try writeFallbackValue(s, obj)) return;
    return error.UnsupportedType;
}

pub fn write(obj: *PyObject, buf: []u8, pos: *usize) WriteError!void {
    var serializer = Serializer.init(buf);
    serializer.pos = pos.*;
    try writeValue(&serializer, obj);
    pos.* = serializer.pos;
}
