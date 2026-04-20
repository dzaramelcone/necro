pub const SerializeStrategy = enum(u8) {
    text_escape,
    json_raw,
    bin_bool,
    bin_int,
    bin_float,
    bin_numeric,
    bin_date,
    bin_time,
    bin_timestamp,
    bin_timestamptz,
    bin_uuid,
    bin_jsonb,
    bin_bytea,
};

pub fn strategyForOid(oid: u32) SerializeStrategy {
    return switch (oid) {
        16 => .bin_bool,
        17 => .bin_bytea,
        20, 21, 23, 26 => .bin_int,
        25, 18, 19, 705, 1042, 1043 => .text_escape,
        114 => .json_raw,
        700, 701 => .bin_float,
        1082 => .bin_date,
        1083 => .bin_time,
        1114 => .bin_timestamp,
        1184 => .bin_timestamptz,
        1700 => .bin_numeric,
        2950 => .bin_uuid,
        3802 => .bin_jsonb,
        else => .text_escape,
    };
}
