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
};

const log = std.log.scoped(.openapi_zenerator);

pub fn generate(allocator: std.mem.Allocator, comptime endpoint_data: anytype, options: GenerateOptions) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const wrapped_data = if (@typeInfo(@TypeOf(endpoint_data)) == .@"struct" and @typeInfo(@TypeOf(endpoint_data)).@"struct".is_tuple)
        endpoint_data
    else
        .{endpoint_data};

    var path_map = std.StringHashMap(Path).init(alloc);

    inline for (wrapped_data) |endpoints| {
        inline for (endpoints) |endpoint| {
            const formatted_path = try transformPath(alloc, endpoint.path);

            var parameters = std.ArrayList(Path.Operation.Parameter).empty;

            var schema_map = std.StringHashMap(Schema).init(alloc);

            var request_body: ?Path.Operation.RequestBody = null;

            var required = std.ArrayList([]const u8).empty;

            if (@typeInfo(endpoint.Request.Body) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Body).@"struct";
                inline for (@"struct".fields) |field| {
                    if (@typeInfo(field.type) != .optional) try required.append(alloc, field.name);
                    try schema_map.put(field.name, Schema.init(field.type, alloc));
                }
            }
            if (schema_map.count() != 0) {
                request_body = .{
                    .required = true,
                    .content = .{
                        .@"application/json" = .{
                            .schema = .{
                                .type = .object,
                                .required = if (required.items.len != 0) try required.toOwnedSlice(alloc) else null,
                                .properties = schema_map,
                            },
                        },
                    },
                };
            }

            if (@typeInfo(endpoint.Request.Params) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Params).@"struct";

                inline for (@"struct".fields) |field| {
                    try parameters.append(alloc, .{
                        .name = field.name,
                        .in = .path,
                        .required = true,
                        .schema = Schema.init(field.type, alloc),
                    });
                }
            }
            if (@typeInfo(endpoint.Request.Query) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Query).@"struct";

                inline for (@"struct".fields) |field| {
                    try parameters.append(alloc, .{
                        .name = field.name,
                        .in = .query,
                        .required = true,
                        .schema = Schema.init(field.type, alloc),
                    });
                }
            }

            const method_str = @tagName(endpoint.method);

            const method = std.meta.stringToEnum(Method, method_str) orelse {
                log.err("Method \"{s}\" was not found in the defined method enum.", .{method_str});
                return error.IncorrectMethod;
            };

            try insertParameter(.{
                .path = formatted_path,
                .method = method,
                .params = try parameters.toOwnedSlice(alloc),
                .request_body = request_body,
            }, endpoint.Response, alloc, &path_map);
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

    var output_buffer = std.Io.Writer.Allocating.init(alloc);
    const fmt = std.json.fmt(document, .{});
    try fmt.format(&output_buffer.writer);
    try output_buffer.writer.flush();
    try file.writeAll(output_buffer.written());
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

fn insertParameter(route_info: struct {
    path: []const u8,
    method: Method,
    params: ?[]Path.Operation.Parameter = null,
    request_body: ?Path.Operation.RequestBody = null,
}, ResponseT: type, allocator: std.mem.Allocator, map: *std.StringHashMap(Path)) !void {
    var responses = std.StringHashMap(Response).init(allocator);

    var schema_map = std.StringHashMap(Schema).init(allocator);

    switch (@typeInfo(ResponseT)) {
        .@"struct" => |@"struct"| {
            inline for (@"struct".fields) |field| {
                try schema_map.put(field.name, Schema.init(field.type, allocator));
            }
        },
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) break :blk;
            inline for (@typeInfo(ptr.child).@"struct".fields) |field| {
                try schema_map.put(field.name, Schema.init(field.type, allocator));
            }
        },
        else => {},
    }

    const schema: Schema = switch (@typeInfo(ResponseT)) {
        .@"struct" => Schema{ .properties = schema_map },
        .pointer => blk: {
            const items = try allocator.create(Schema);
            items.* = Schema{
                .type = .object,
                .properties = schema_map,
            };

            break :blk Schema{ .type = .array, .items = items };
        },
        else => .{},
    };

    try responses.put("200", Response{
        .description = "Success",
        .content = .{
            .@"application/json" = .{
                .schema = schema,
            },
        },
    });

    const last_slash_index = std.mem.lastIndexOf(u8, route_info.path, "/") orelse {
        log.err("{s} is not a correctly formatted path!", .{route_info.path});
        return error.IncorrectPath;
    };
    const route_name = route_info.path[last_slash_index..];
    const some_path = try allocator.dupe(u8, route_name);

    const tags = try allocator.alloc([]u8, 1);
    tags[0] = some_path;
    const operation = Path.Operation{
        .parameters = if (route_info.params) |p| p else null,
        .requestBody = if (route_info.request_body) |rb| rb else null,
        .responses = responses,
        .tags = tags,
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
