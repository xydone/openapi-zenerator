pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
    CONNECT,
    OTHER,
};

pub const GenerateOptions = struct {
    title: []const u8,
    version: []const u8,
    out_file_path: []const u8,
    default_tag_name: []const u8 = "default",
};

const log = std.log.scoped(.openapi_zenerator);

pub fn generate(alloc: std.mem.Allocator, comptime endpoint_data: anytype, options: GenerateOptions) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    const wrapped_data = if (@typeInfo(@TypeOf(endpoint_data)) == .@"struct" and @typeInfo(@TypeOf(endpoint_data)).@"struct".is_tuple)
        endpoint_data
    else
        .{endpoint_data};

    var path_map = std.StringHashMap(Path).init(allocator);

    inline for (wrapped_data) |endpoints| {
        inline for (endpoints) |endpoint| {
            const formatted_path = try transformPath(allocator, endpoint.path);

            var parameters = std.ArrayList(Path.Operation.Parameter).empty;
            var schema_map = std.StringHashMap(Schema).init(allocator);
            var request_body: ?Path.Operation.RequestBody = null;
            var required = std.ArrayList([]const u8).empty;

            const body_type_info = @typeInfo(endpoint.Request.Body);
            const is_body_map = body_type_info == .@"struct" and @hasDecl(endpoint.Request.Body, "KV") and @hasDecl(endpoint.Request.Body, "GetOrPutResult");

            if (is_body_map) {
                request_body = .{
                    .required = true,
                    .content = .{
                        .@"application/json" = .{
                            .schema = Schema.init(endpoint.Request.Body, allocator),
                        },
                    },
                };
            } else if (body_type_info == .@"struct") {
                const @"struct" = body_type_info.@"struct";
                inline for (@"struct".fields) |field| {
                    if (@typeInfo(field.type) != .optional) try required.append(allocator, field.name);
                    try schema_map.put(field.name, Schema.init(field.type, allocator));
                }
                if (schema_map.count() != 0) {
                    request_body = .{
                        .required = true,
                        .content = .{
                            .@"application/json" = .{
                                .schema = .{
                                    .type = .object,
                                    .required = if (required.items.len != 0) try required.toOwnedSlice(allocator) else null,
                                    .properties = schema_map,
                                },
                            },
                        },
                    };
                }
            }

            if (@typeInfo(endpoint.Request.Params) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Params).@"struct";
                inline for (@"struct".fields) |field| {
                    try parameters.append(allocator, .{
                        .name = field.name,
                        .in = .path,
                        .required = true,
                        .schema = Schema.init(field.type, allocator),
                    });
                }
            }
            if (@typeInfo(endpoint.Request.Query) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Query).@"struct";
                inline for (@"struct".fields) |field| {
                    try parameters.append(allocator, .{
                        .name = field.name,
                        .in = .query,
                        .required = true,
                        .schema = Schema.init(field.type, allocator),
                    });
                }
            }

            const method_str = @tagName(endpoint.method);
            const method = std.meta.stringToEnum(Method, method_str) orelse {
                log.err("Method \"{s}\" was not found in the defined method enum.", .{method_str});
                return error.IncorrectMethod;
            };

            var tag_list = std.ArrayList([]const u8).empty;
            const is_type = @TypeOf(endpoint) == type;
            const has_tags = comptime if (is_type)
                @hasDecl(endpoint, "tags")
            else
                @hasField(@TypeOf(endpoint), "tags");

            if (has_tags) {
                const tags_val = if (is_type) endpoint.tags else endpoint.tags;

                switch (@typeInfo(@TypeOf(tags_val))) {
                    .pointer => |ptr| {
                        if (ptr.size == .slice and ptr.child == u8) {
                            try tag_list.append(tags_val);
                        } else if (ptr.size == .slice and ptr.child == []const u8) {
                            for (tags_val) |t| {
                                try tag_list.append(allocator, t);
                            }
                        }
                    },
                    .@"struct" => |s| {
                        if (s.is_tuple) {
                            inline for (tags_val) |t| {
                                try tag_list.append(allocator, t);
                            }
                        }
                    },
                    .array => |arr| {
                        if (arr.child == u8) {
                            try tag_list.append(&tags_val);
                        } else if (arr.child == []const u8) {
                            for (tags_val) |t| {
                                try tag_list.append(allocator, t);
                            }
                        }
                    },
                    else => {},
                }
            }

            if (tag_list.items.len == 0) {
                try tag_list.append(allocator, "default");
            }

            const summary = comptime blk: {
                if (is_type) {
                    if (@hasDecl(endpoint, "summary")) break :blk endpoint.summary;
                } else {
                    if (@hasField(@TypeOf(endpoint), "summary")) break :blk endpoint.summary;
                }
                break :blk null;
            };

            const description = comptime blk: {
                if (is_type) {
                    if (@hasDecl(endpoint, "description")) break :blk endpoint.description;
                } else {
                    if (@hasField(@TypeOf(endpoint), "description")) break :blk endpoint.description;
                }
                break :blk null;
            };

            try insertParameter(.{
                .path = formatted_path,
                .method = method,
                .params = try parameters.toOwnedSlice(allocator),
                .request_body = request_body,
                .tags = try tag_list.toOwnedSlice(allocator),
                .summary = summary,
                .description = description,
            }, endpoint.Response, allocator, &path_map);
        }
    }

    if (std.fs.path.dirname(options.out_file_path)) |dirname| {
        std.fs.cwd().makePath(dirname) catch {};
    }

    const file = try std.fs.cwd().createFile(options.out_file_path, .{});
    defer file.close();

    const document: OpenAPI = .{
        .openapi = "3.1.0",
        .info = .{
            .title = options.title,
            .version = options.version,
        },
        .paths = path_map,
    };

    var output_buffer = std.Io.Writer.Allocating.init(allocator);
    const fmt = std.json.fmt(document, .{});
    try fmt.format(&output_buffer.writer);
    try output_buffer.writer.flush();
    try file.writeAll(output_buffer.written());
}

fn insertParameter(
    route_info: struct {
        path: []const u8,
        method: Method,
        params: ?[]Path.Operation.Parameter = null,
        request_body: ?Path.Operation.RequestBody = null,
        tags: []const []const u8,
        summary: ?[]const u8,
        description: ?[]const u8,
    },
    ResponseT: type,
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(Path),
) !void {
    var responses = std.StringHashMap(Response).init(allocator);

    const is_response_map = @typeInfo(ResponseT) == .@"struct" and @hasDecl(ResponseT, "KV") and @hasDecl(ResponseT, "GetOrPutResult");

    const schema: Schema = if (is_response_map) blk: {
        break :blk Schema.init(ResponseT, allocator);
    } else blk: {
        var schema_map = std.StringHashMap(Schema).init(allocator);

        switch (@typeInfo(ResponseT)) {
            .@"struct" => |@"struct"| {
                inline for (@"struct".fields) |field| {
                    try schema_map.put(field.name, Schema.init(field.type, allocator));
                }
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    inline for (@typeInfo(ptr.child).@"struct".fields) |field| {
                        try schema_map.put(field.name, Schema.init(field.type, allocator));
                    }
                }
            },
            else => {},
        }

        break :blk switch (@typeInfo(ResponseT)) {
            .@"struct" => Schema{ .type = .object, .properties = schema_map },
            .pointer => items_blk: {
                const items = try allocator.create(Schema);
                items.* = Schema{
                    .type = .object,
                    .properties = schema_map,
                };
                break :items_blk Schema{ .type = .array, .items = items };
            },
            else => .{},
        };
    };

    try responses.put("200", Response{
        .description = "Success",
        .content = .{
            .@"application/json" = .{
                .schema = schema,
            },
        },
    });

    const tags = try allocator.alloc([]u8, route_info.tags.len);
    for (route_info.tags, 0..) |t, i| {
        tags[i] = try allocator.dupe(u8, t);
    }

    const operation = Path.Operation{
        .parameters = if (route_info.params) |p| p else null,
        .requestBody = if (route_info.request_body) |rb| rb else null,
        .responses = responses,
        .tags = tags,
        .summary = route_info.summary,
        .description = route_info.description,
    };

    const gop = try map.getOrPut(route_info.path);
    if (gop.found_existing == true) {
        var op = getOperation(route_info.method, gop.value_ptr) orelse Path.Operation{
            .responses = responses,
        };
        op.parameters = if (route_info.params) |p| p else null;
        op.requestBody = if (route_info.request_body) |rb| rb else null;
        setOperation(route_info.method, gop.value_ptr, operation);
    } else {
        gop.value_ptr.* = Path{};
        setOperation(route_info.method, gop.value_ptr, operation);
    }
}

fn transformPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var new_path_builder = std.Io.Writer.Allocating.init(allocator);

    var it = std.mem.splitScalar(u8, path, '/');

    var is_first_segment = true;

    while (it.next()) |segment| {
        if (!is_first_segment) {
            try new_path_builder.writer.writeAll("/");
        }
        is_first_segment = false;

        if (segment.len > 1 and segment[0] == ':') {
            try new_path_builder.writer.print("{{{s}}}", .{segment[1..]});
        } else {
            try new_path_builder.writer.writeSliceSwap(u8, segment);
        }
    }

    try new_path_builder.writer.flush();

    return new_path_builder.toOwnedSlice();
}

fn getOperation(method: Method, value_ptr: *Path) ?Path.Operation {
    return switch (method) {
        .GET => value_ptr.*.get,
        .HEAD => value_ptr.*.head,
        .POST => value_ptr.*.post,
        .PUT => value_ptr.*.put,
        .PATCH => value_ptr.*.patch,
        .DELETE => value_ptr.*.delete,
        .OPTIONS => value_ptr.*.options,
        .CONNECT => value_ptr.*.connect,
        .OTHER => unreachable,
    };
}

fn setOperation(method: Method, value_ptr: *Path, operation: Path.Operation) void {
    switch (method) {
        .GET => value_ptr.*.get = operation,
        .HEAD => value_ptr.*.head = operation,
        .POST => value_ptr.*.post = operation,
        .PUT => value_ptr.*.put = operation,
        .PATCH => value_ptr.*.patch = operation,
        .DELETE => value_ptr.*.delete = operation,
        .OPTIONS => value_ptr.*.options = operation,
        .CONNECT => value_ptr.*.connect = operation,
        .OTHER => unreachable,
    }
}

const Path = @import("path.zig");
const Schema = @import("schema.zig");
const Response = @import("response.zig");
const OpenAPI = @import("openapi.zig");

const std = @import("std");
