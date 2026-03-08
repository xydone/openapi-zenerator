test "tests:beforeAll" {
    const allocator = std.heap.smp_allocator;
    TestSetup.test_env = try TestSetup.TestEnv.init(allocator);
}

test "tests:afterAll" {
    TestSetup.test_env.deinit();
}

test "Integration | schema" {
    const allocator = testing.allocator;

    var test_env = TestSetup.test_env;

    const test_name = "basic_schema";

    const out_filename = test_name ++ ".json";
    const full_path = try test_env.getOutPath(out_filename);

    const opts = zenerator.GenerateOptions{
        .title = test_name,
        .version = "0.0.1",
        .out_file_path = full_path,
    };

    try zenerator.generate(allocator, Schema.API.routes, opts);

    _ = try test_env.dir.statFile(out_filename);

    const file = try test_env.dir.openFile(out_filename, .{});
    defer file.close();

    const size = (try file.stat()).size;
    const buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);
    _ = try file.readAll(buffer);

    try testing.expect(std.mem.indexOf(u8, buffer, test_name) != null);
}

const Schema = @import("basic_schema.zig");
const TestSetup = @import("test_setup.zig");

const zenerator = @import("openapi_zenerator");
const testing = std.testing;
const std = @import("std");
