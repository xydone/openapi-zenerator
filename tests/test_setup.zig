pub var test_env: TestEnv = undefined;

const log = std.log.scoped(.test_setup);

pub const TestEnv = struct {
    /// long lived alloc
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    _root_dir: std.fs.Dir,
    _tmp_dir: ?std.testing.TmpDir,
    should_save: bool,

    pub fn init(allocator: std.mem.Allocator) !TestEnv {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        var should_save = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--save")) {
                should_save = true;
                log.info("saving schema files!", .{});
                break;
            }
        }

        var tmp_dir: ?std.testing.TmpDir = null;
        var root_dir = if (should_save) std.fs.cwd().openDir(".", .{}) catch unreachable else cwd: {
            tmp_dir = testing.tmpDir(.{});
            break :cwd tmp_dir.?.dir.openDir(".", .{}) catch unreachable;
        };

        root_dir.makeDir("schemas") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const schema_dir = try root_dir.openDir("schemas", .{});

        return TestEnv{
            .allocator = allocator,
            .dir = schema_dir,
            ._root_dir = root_dir,
            ._tmp_dir = tmp_dir,
            .should_save = should_save,
        };
    }

    pub fn getOutPath(self: *TestEnv, filename: []const u8) ![]u8 {
        const schema_path = try self.dir.realpathAlloc(self.allocator, ".");
        defer self.allocator.free(schema_path);

        return std.fs.path.join(self.allocator, &.{ schema_path, filename });
    }

    pub fn deinit(self: *TestEnv) void {
        self.dir.close();
        self._root_dir.close();
        if (self._tmp_dir) |*t| {
            t.cleanup();
        }
    }
};

const testing = std.testing;
const std = @import("std");
