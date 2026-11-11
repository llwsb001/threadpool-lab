const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;

/// 类型擦除后的任务：函数指针 + 不透明上下文。
/// 提交方负责保证 ctx 指向的内存活到任务执行结束（池不替你管理它）。
pub const Task = struct {
    func: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const Pool = struct {
    allocator: Allocator,
    io: Io,
    tasks: std.ArrayList(Task),
    workers: []Thread,
    // 0.17 起同步原语归 std.Io 管：Mutex/Condition 内部的 futex 操作
    // 都通过 Io 实例发出，换 Io 后端即换底层等待机制。
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    shutdown: bool = false,

    /// 创建池并立即启动 worker_count 个 OS 线程。
    /// 线程诞生路径：std.Thread.spawn → pthread_create → clone。
    pub fn init(allocator: Allocator, io: Io, worker_count: usize) !*Pool {
        if (worker_count == 0) return error.InvalidWorkerCount;

        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .tasks = .empty,
            .workers = try allocator.alloc(Thread, worker_count),
        };
        errdefer self.tasks.deinit(allocator);

        for (self.workers, 0..) |*slot, i| {
            slot.* = Thread.spawn(.{}, workerLoop, .{self}) catch |err| {
                // 部分线程已启动：通知已启动的 worker 退出并 join，再抛错
                self.mutex.lockUncancelable(self.io);
                self.shutdown = true;
                self.cond.broadcast(self.io);
                self.mutex.unlock(self.io);
                for (self.workers[0..i]) |t| t.join();
                self.allocator.free(self.workers);
                return err;
            };
        }
        return self;
    }

    /// 入队一个任务并唤醒一个空闲 worker。
    pub fn submit(
        self: *Pool,
        func: *const fn (ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) !void {
        // 用 Uncancelable 版本：本池没有外部取消协议，worker 也不会被 cancel。
        // 对应的可取消版 lock(io) 会在任务被 cancel 时返回 error.Canceled。
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.shutdown) return error.PoolShutdown;
        try self.tasks.append(self.allocator, .{ .func = func, .ctx = ctx });
        self.cond.signal(self.io); // 队列从空变非空，叫醒一个 worker
    }

    /// 优雅关闭：标记 shutdown、广播唤醒所有 worker、join 到全部退出。
    /// 语义是排空队列——worker 会把 shutdown 前入队的任务做完。
    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.cond.broadcast(self.io); // 所有睡在 cond 上的 worker 都要醒来看 shutdown
        self.mutex.unlock(self.io);

        for (self.workers) |t| t.join();

        self.allocator.free(self.workers);
        self.tasks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// worker 线程的主循环。
    fn workerLoop(self: *Pool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);

            // 必须 while 而非 if：
            // 1) 条件变量允许「虚假唤醒」，醒来时条件可能已不成立；
            // 2) broadcast 或多个 signal 会让多个 worker 同时醒来，
            //    但队列里可能只有一个任务，抢不到的必须回去继续睡。
            while (self.tasks.items.len == 0 and !self.shutdown) {
                // waitUncancelable 原子地完成「释放 mutex → 睡眠」；
                // 被 signal 唤醒后又会先重新拿回 mutex 才返回。
                self.cond.waitUncancelable(self.io, &self.mutex);
            }

            if (self.shutdown and self.tasks.items.len == 0) {
                self.mutex.unlock(self.io);
                return;
            }

            const task = self.tasks.orderedRemove(0);
            self.mutex.unlock(self.io);

            // 任务在锁外执行：否则一个长任务会堵住所有 submit 和其他 worker。
            task.func(task.ctx);
        }
    }
};
