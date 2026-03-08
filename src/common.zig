pub fn jsonStringifyWithoutNull(self: anytype, jws: *std.json.Stringify) !void {
    try jws.beginObject();
    inline for (@typeInfo(@TypeOf(self)).@"struct".fields) |field| {
        const field_type_name = @typeName(field.type);
        const FieldType = field.type;
        const InnerType = if (@typeInfo(FieldType) == .optional)
            @typeInfo(FieldType).optional.child
        else
            FieldType;

        if (comptime std.mem.containsAtLeast(u8, field_type_name, 1, "hash_map")) blk: {
            var it = if (field_type_name[0] == '?') it_blk: {
                var f = @field(self, field.name) orelse break :blk;
                break :it_blk f.iterator();
            } else @field(self, field.name).iterator();

            try jws.objectField(field.name);
            try jws.beginObject();
            while (it.next()) |kv| {
                try jws.objectField(kv.key_ptr.*);
                const ValueType = @TypeOf(kv.value_ptr.*);
                if (comptime @typeInfo(ValueType) == .@"struct") {
                    try jsonStringifyWithoutNull(kv.value_ptr.*, jws);
                } else {
                    try jws.write(kv.value_ptr.*);
                }
            }
            try jws.endObject();
        } else if (comptime @typeInfo(InnerType) == .pointer and
            @typeInfo(InnerType).pointer.size == .slice and
            @typeInfo(@typeInfo(InnerType).pointer.child) == .@"struct")
        {
            if (@typeInfo(FieldType) == .optional) {
                if (@field(self, field.name)) |slice| {
                    try jws.objectField(field.name);
                    try jws.beginArray();
                    for (slice) |item| {
                        try jsonStringifyWithoutNull(item, jws);
                    }
                    try jws.endArray();
                }
            } else {
                try jws.objectField(field.name);
                try jws.beginArray();
                for (@field(self, field.name)) |item| {
                    try jsonStringifyWithoutNull(item, jws);
                }
                try jws.endArray();
            }
        } else if (comptime @typeInfo(InnerType) == .pointer and
            @typeInfo(@typeInfo(InnerType).pointer.child) == .@"struct")
        {
            if (@typeInfo(FieldType) == .optional) {
                if (@field(self, field.name)) |ptr| {
                    try jws.objectField(field.name);
                    try jsonStringifyWithoutNull(ptr.*, jws);
                }
            } else {
                try jws.objectField(field.name);
                try jsonStringifyWithoutNull(@field(self, field.name).*, jws);
            }
        } else {
            if (@typeInfo(field.type) == .optional) {
                if (@field(self, field.name)) |_| {
                    try jws.objectField(field.name);
                    try jws.write(@field(self, field.name));
                }
            } else {
                try jws.objectField(field.name);
                try jws.write(@field(self, field.name));
            }
        }
    }

    try jws.endObject();
}

const std = @import("std");
const Response = @import("response.zig");
