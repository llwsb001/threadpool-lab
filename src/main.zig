const std = @import("std");
const pool_mod = @import("threadpool.zig");
const Io = std.Io;

const Job = struct {
    id: usize,
    io: Io,

    /// 签名必须匹配池要求的 fn(*anyopaque) void。
    fn run(ctx: *anyopaque) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        std.debug.print("task {d:>2} start (tid {d})\n", .{ job.id, std.Thread.getCurrentId() });

        // 对应 Go 的 time.Sleep：经 Io 后端等待。
        // .awake 是单调时钟（对应 CLOCK_MONOTONIC），不受系统时间跳变影响。
        Io.sleep(job.io, Io.Duration.fromMilliseconds(20), .awake) catch {};

        std.debug.print("task {d:>2} done\n", .{job.id});
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 4 个 worker 处理 10 个任务。
    var pool = try pool_mod.Pool.init(allocator, io, 4);
    defer pool.deinit();

    // jobs 在栈上；deinit 会 join 所有 worker，
    // 保证最后一个任务结束前 jobs 数组始终有效。
    var jobs: [10]Job = undefined;
    for (&jobs, 0..) |*j, i| {
        j.* = .{ .id = i, .io = io };
        try pool.submit(Job.run, j);
    }
}
