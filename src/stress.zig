const std = @import("std");
const dyn = @import("dynamic_pool.zig");
const Io = std.Io;

var executed: std.atomic.Value(usize) = .init(0);

fn bump(ctx: *anyopaque) void {
    _ = ctx;
    _ = executed.fetchAdd(1, .monotonic);
}

/// 阶段 1 用的慢任务：睡 50ms 制造积压，迫使池懒创建新 worker。
const SlowJob = struct {
    io: Io,

    fn run(ctx: *anyopaque) void {
        const job: *SlowJob = @ptrCast(@alignCast(ctx));
        Io.sleep(job.io, Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
};

fn sleepMs(io: Io, ms: i64) void {
    Io.sleep(io, Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const pool = try dyn.Pool.init(allocator, io, .{
        .max_workers = 8,
        .idle_timeout = Io.Duration.fromMilliseconds(100),
    });
    // 不用 defer deinit：结尾要先断言再销毁；中途失败直接退出，进程回收资源。

    // ── 阶段 1：懒创建。任务 50ms、每 5ms 投一个，积压迫使 active 涨向 8。
    std.debug.print("== phase 1: lazy spawn (expect active grows 0 -> 8) ==\n", .{});
    var slow: [24]SlowJob = undefined;
    for (&slow, 0..) |*j, i| {
        j.* = .{ .io = io };
        try pool.submit(SlowJob.run, j);
        const s = pool.stats();
        std.debug.print("submitted {d:>2}: active={d} idle={d} queued={d}\n", .{ i + 1, s.active, s.idle, s.queued });
        sleepMs(io, 5);
    }

    // ── 阶段 2：空闲退出。等任务做完并超过 idle_timeout，active 应回落到 0。
    std.debug.print("== phase 2: idle exit (expect active == 0) ==\n", .{});
    sleepMs(io, 600);
    var s = pool.stats();
    std.debug.print("after idle timeout: active={d} idle={d} queued={d}\n", .{ s.active, s.idle, s.queued });
    if (s.active != 0) return error.IdleExitFailed;

    // ── 阶段 3：压测。1000 个任务，原子计数，排空后断言 == 1000。
    std.debug.print("== phase 3: burst 1000 tasks ==\n", .{});
    var dummy: u8 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) try pool.submit(bump, &dummy);

    // 带上限地等排空，避免逻辑出错时无限挂起。
    var waited_ms: i64 = 0;
    while (executed.load(.acquire) < 1000) {
        if (waited_ms >= 10_000) return error.StressTimeout;
        sleepMs(io, 5);
        waited_ms += 5;
    }
    s = pool.stats();
    std.debug.print("burst drained: executed={d} active={d} idle={d} queued={d}\n", .{ executed.load(.acquire), s.active, s.idle, s.queued });

    // 压测后再次验证空闲退出。
    sleepMs(io, 300);
    s = pool.stats();
    std.debug.print("after idle timeout: active={d}\n", .{s.active});
    if (s.active != 0) return error.IdleExitFailed;

    pool.deinit();
    if (executed.load(.acquire) != 1000) return error.TaskCountMismatch;
    std.debug.print("PASS: executed == 1000, active == 0, all handles joined\n", .{});
}
