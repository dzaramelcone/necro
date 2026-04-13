const ffi = @import("../ffi.zig");
const futures = @import("futures.zig");

const type_flags: c_ulong = ffi.flags.DEFAULT | ffi.flags.BASETYPE;
const gc_type_flags: c_ulong = type_flags | ffi.flags.HAVE_GC;

const slot = ffi.typeSlot;
const methodDef = ffi.methodDef;

const future_methods = ffi.table(ffi.MethodDef, .{
    methodDef("cancel", futures.futureCancelMethod, .varargs_kwargs),
    methodDef("cancelled", futures.futureCancelledMethod, .no_args),
    methodDef("done", futures.futureDoneMethod, .no_args),
    methodDef("result", futures.futureResultMethod, .no_args),
    methodDef("exception", futures.futureExceptionMethod, .no_args),
    methodDef("set_result", futures.futureSetResultMethod, .one),
    methodDef("set_exception", futures.futureSetExceptionMethod, .one),
});

const task_methods = ffi.table(ffi.MethodDef, .{
    methodDef("get_coro", futures.taskGetCoroMethod, .no_args),
    methodDef("get_context", futures.taskGetContextMethod, .no_args),
    methodDef("get_name", futures.taskGetNameMethod, .no_args),
    methodDef("set_name", futures.taskSetNameMethod, .one),
    methodDef("cancel", futures.taskCancelMethod, .varargs_kwargs),
    methodDef("cancelling", futures.taskCancellingMethod, .no_args),
    methodDef("uncancel", futures.taskUncancelMethod, .no_args),
});

const future_type_slots = ffi.table(ffi.TypeSlot, .{
    slot(ffi.Slot.dealloc, futures.futureDealloc),
    slot(ffi.Slot.traverse, futures.futureTraverse),
    slot(ffi.Slot.clear, futures.futureClear),
    slot(ffi.Slot.repr, futures.futureRepr),
    slot(ffi.Slot.methods, &future_methods),
    slot(ffi.Slot.new, futures.futureTypeNew),
    slot(ffi.Slot.init, futures.futureTypeInit),
    slot(ffi.Slot.@"await", futures.futureAwait),
    slot(ffi.Slot.iter, futures.futureAwait),
    slot(ffi.Slot.doc, "native necro future"),
});

const task_type_slots = ffi.table(ffi.TypeSlot, .{
    slot(ffi.Slot.dealloc, futures.taskDealloc),
    slot(ffi.Slot.traverse, futures.taskTraverse),
    slot(ffi.Slot.clear, futures.taskClear),
    slot(ffi.Slot.repr, futures.taskRepr),
    slot(ffi.Slot.methods, &task_methods),
    slot(ffi.Slot.new, futures.taskTypeNew),
    slot(ffi.Slot.init, futures.taskTypeInit),
    slot(ffi.Slot.doc, "native necro task"),
});

const future_iter_type_slots = ffi.table(ffi.TypeSlot, .{
    slot(ffi.Slot.dealloc, futures.futureIterDealloc),
    slot(ffi.Slot.iter, futures.futureIterSelf),
    slot(ffi.Slot.iternext, futures.futureIterNext),
    slot(ffi.Slot.doc, "native necro future iterator"),
});

pub const future_type_spec = ffi.TypeSpec{
    .name = "necro.core.Future",
    .basicsize = @sizeOf(futures.FutureObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = @ptrCast(@constCast(&future_type_slots)),
};

pub const task_type_spec = ffi.TypeSpec{
    .name = "necro.core.Task",
    .basicsize = @sizeOf(futures.TaskObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = @ptrCast(@constCast(&task_type_slots)),
};

pub const future_iter_type_spec = ffi.TypeSpec{
    .name = "necro.core._FutureIter",
    .basicsize = @sizeOf(futures.FutureIterObject),
    .itemsize = 0,
    .flags = ffi.flags.DEFAULT,
    .slots = @ptrCast(@constCast(&future_iter_type_slots)),
};
