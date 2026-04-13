pub const SerializeStrategy = enum(u8) {
    text_escape,
    numeric,
    bool_convert,
    quoted_raw,
    json_raw,
};

pub fn strategyForOid(oid: u32) SerializeStrategy {
    return switch (oid) {
        16 => .bool_convert,
        20, 21, 23 => .numeric,
        26 => .numeric,
        700, 701 => .numeric,
        1700 => .numeric,
        25, 1042, 1043 => .text_escape,
        18 => .text_escape,
        19 => .text_escape,
        114, 3802 => .json_raw,
        1082, 1083, 1114, 1184 => .quoted_raw,
        1186 => .quoted_raw,
        2950 => .quoted_raw,
        17 => .quoted_raw,
        else => .text_escape,
    };
}
