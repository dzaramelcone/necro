pub const SmallSlab = struct {
    pub const SIZE: usize = 4096;
    data: [SIZE]u8 = undefined,
};

pub const BigSlab = struct {
    pub const SIZE: usize = 65536;
    data: [SIZE]u8 = undefined,
};
