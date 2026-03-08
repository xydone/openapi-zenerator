//! Fork of https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

var current_test: ?[]const u8 = null;
var is_fail_first_triggered = false;
var is_fail_leak_triggered = false;

const Config = struct {
    verbose: bool,
    fail_first: bool,
    fail_leak: bool,
    filter: ?[]const u8,
    // allocation failure tests are tests which go through a function to see if errdefers are added properly
    // by default they will not be executed as they take a long time
    run_allocation_failure_tests: bool,

    pub fn init() Config {
        return Config{
            .verbose = false,
            .fail_first = false,
            .fail_leak = false,
            .filter = null,
            .run_allocation_failure_tests = false,
        };
    }
};

const TestStats = struct {
    pass: u64,
    fail: u64,
    skip: u64,
    leak: u64,
    setup_teardown: u64,

    pub fn init() TestStats {
        return TestStats{
            .pass = 0,
            .fail = 0,
            .skip = 0,
            .leak = 0,
            .setup_teardown = 0,
        };
    }
};

const TestList = struct {
    test_functions: *std.ArrayList(std.builtin.TestFn),
    callback: *const fn (CallbackParams) anyerror!void,

    pub const CallbackType = enum { basic, @"test" };
    pub const CallbackParams = struct { t: std.builtin.TestFn, config: Config, printer: Printer, test_stats: *TestStats };

    pub fn init(allocator: std.mem.Allocator, callback_type: CallbackType) TestList {
        const list = allocator.create(std.ArrayList(std.builtin.TestFn)) catch @panic("cannot allocate arraylist");
        list.* = std.ArrayList(std.builtin.TestFn).empty;
        return TestList{
            .test_functions = list,
            .callback = switch (callback_type) {
                .basic => basic_callback,
                .@"test" => test_callback,
            },
        };
    }

    pub fn deinit(self: TestList, allocator: std.mem.Allocator) void {
        self.test_functions.deinit(allocator);
        allocator.destroy(self.test_functions);
    }

    pub fn basic_callback(params: CallbackParams) !void {
        params.t.func() catch |err| {
            return err;
        };
    }
    pub fn test_callback(params: CallbackParams) !void {
        const is_unnamed_test = isUnnamed(params.t);
        const name = makeNameFriendly(params.t.name);
        if (params.config.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, params.t.name, f) == null) {
                // continue;
                return;
            }
        }

        std.testing.allocator_instance = .{};
        const result = params.t.func();

        if (std.testing.allocator_instance.deinit() == .leak) {
            params.test_stats.leak += 1;
            if (params.config.fail_first) is_fail_leak_triggered = true;
        }

        if (result) |_| {
            params.test_stats.pass += 1;
            printPass(params.printer, name);
        } else |err| switch (err) {
            error.SkipZigTest => {
                params.test_stats.skip += 1;
            },
            else => {
                //TODO: jank!
                if (params.config.fail_first) is_fail_first_triggered = true;
                params.test_stats.fail += 1;
                printFail(params.printer, name, err);
                if (@errorReturnTrace()) |trace| {
                    params.printer.status(.fail, "{s}\n", .{BORDER});
                    params.printer.status(.fail, "TRACE:\n", .{});
                    std.debug.dumpStackTrace(trace.*);
                    params.printer.status(.fail, "{s}\n", .{BORDER});
                }
            },
        }
    }
};
pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const printer = Printer.init(allocator);

    var config = Config.init();
    {
        var args_it = try std.process.argsWithAllocator(allocator);
        defer args_it.deinit();
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--verbose")) config.verbose = true;
            if (std.mem.eql(u8, arg, "--fail-first")) config.fail_first = true;
            if (std.mem.eql(u8, arg, "--fail-leak")) config.fail_first = true;
            if (std.mem.startsWith(u8, arg, "--filter")) {
                var tokens = std.mem.tokenizeSequence(u8, arg, "=");
                //skip "--filter"
                _ = tokens.next();
                const filter = tokens.next() orelse return;
                config.filter = filter;
            }
            if (std.mem.eql(u8, arg, "--allocation-failures")) config.run_allocation_failure_tests = true;
        }
    }

    var test_stats = TestStats.init();
    var timer = std.time.Timer.start() catch @panic("Timer not supported.");

    const setup_queue = TestList.init(allocator, .basic);
    defer setup_queue.deinit(allocator);
    const teardown_queue = TestList.init(allocator, .basic);
    defer teardown_queue.deinit(allocator);
    const integration_queue = TestList.init(allocator, .@"test");
    defer integration_queue.deinit(allocator);
    const unit_queue = TestList.init(allocator, .@"test");
    defer unit_queue.deinit(allocator);

    for (builtin.test_functions) |t| {
        const name = makeNameFriendly(t.name);
        if (isIntegration(name)) {
            try integration_queue.test_functions.append(allocator, t);
            continue;
        }
        if (isUnit(name)) {
            try unit_queue.test_functions.append(allocator, t);
            continue;
        }
        if (isSetup(name)) {
            try setup_queue.test_functions.append(allocator, t);
            test_stats.setup_teardown += 1;
            continue;
        }
        if (isTeardown(name)) {
            try teardown_queue.test_functions.append(allocator, t);
            test_stats.setup_teardown += 1;
            continue;
        }
    }

    const test_run_order = [_]TestList{ setup_queue, unit_queue, integration_queue, teardown_queue };
    for (test_run_order) |list| outer: {
        for (list.test_functions.items) |t| {
            if (is_fail_first_triggered or is_fail_leak_triggered) break :outer;
            current_test = makeNameFriendly(t.name);
            const name = current_test.?;
            const is_setup_teardown = isSetup(name) or isTeardown(name);
            const is_alloc_test = isAllocationFailure(name);

            if (!is_setup_teardown) {
                if (config.run_allocation_failure_tests != is_alloc_test) {
                    continue;
                }
            }

            const params = TestList.CallbackParams{
                .config = config,
                .printer = printer,
                .test_stats = &test_stats,
                .t = t,
            };
            try list.callback(params);
        }
    }

    printer.fmt("{s}\n", .{BORDER});
    const total_tests = builtin.test_functions.len - test_stats.setup_teardown;
    const total_tests_executed = test_stats.pass + test_stats.fail;
    const not_executed = total_tests - total_tests_executed;
    const has_leaked = test_stats.leak != 0;
    const total_time: f64 = @as(f64, @floatFromInt(timer.lap())) / 1_000_000.0;
    printer.status(.text, "{s: <15}: {d:.3}ms\n", .{ "TOTAL TIME", total_time });
    printer.status(.text, "{s: <15}: {d}\n", .{ "TOTAL EXECUTED", total_tests_executed });
    printer.status(.pass, "{s: <15}: {d}\n", .{ "PASS", test_stats.pass });
    printer.status(.fail, "{s: <15}: {d}\n", .{ "FAILED", test_stats.fail });
    if (not_executed > 0) printer.status(.fail, "{s: <15}: {d}\n", .{ "NOT EXECUTED", not_executed });
    if (has_leaked) printer.status(.fail, "{s: <15}: {d}\n", .{ "LEAKED", test_stats.leak });

    std.posix.exit(if (test_stats.fail == 0) 0 else 1);
}

fn printPass(printer: Printer, name: []const u8) void {
    printer.status(.pass, "{s}\n", .{name});
}

fn printFail(printer: Printer, name: []const u8, err: anyerror) void {
    printer.status(.fail, "\"{s}\" - {s}\n", .{ name, @errorName(err) });
}

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn makeNameFriendly(name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |value| {
        if (std.mem.eql(u8, value, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }
    return name;
}

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isNotTimed(test_name: []const u8) bool {
    return std.mem.endsWith(u8, test_name, "tests:noTime");
}

fn isUnit(test_name: []const u8) bool {
    return std.mem.startsWith(u8, test_name, "Unit |");
}

fn isIntegration(test_name: []const u8) bool {
    return std.mem.startsWith(u8, test_name, "Integration |");
}

fn isSetup(test_name: []const u8) bool {
    return std.mem.endsWith(u8, test_name, "tests:beforeAll");
}

fn isTeardown(test_name: []const u8) bool {
    return std.mem.endsWith(u8, test_name, "tests:afterAll");
}

fn isAllocationFailure(test_name: []const u8) bool {
    return std.mem.containsAtLeast(
        u8,
        test_name,
        1,
        "Allocation Failure",
    );
}

pub const Printer = struct {
    out: *std.fs.File.Writer,

    pub fn init(allocator: Allocator) Printer {
        const writer = allocator.create(std.fs.File.Writer) catch @panic("OOM");
        writer.* = std.fs.File.stderr().writer(&.{});
        return .{
            .out = writer,
        };
    }

    pub fn fmt(self: Printer, comptime format: []const u8, args: anytype) void {
        self.out.interface.print(format, args) catch unreachable;
    }

    pub fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) void {
        const color = switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        };

        self.out.interface.writeAll(color) catch @panic("writeAll failed?!");
        self.fmt(format, args);
        self.fmt("\x1b[0m", .{});
    }
};
pub const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const std = @import("std");
const builtin = @import("builtin");
