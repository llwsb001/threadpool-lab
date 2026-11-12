const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;

/// 与 v1 相同：函数指针 + 不透明上下文；提交方负责保证 ctx 活到任务执行结束。
pub const Task = struct {
    func: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

/// v2 动态池：初始零 worker，任务先入队，不够才 spawn；空闲超时自动退出。
pub const Pool = struct {
    allocator: Allocator,
    io: Io,
    tasks: std.ArrayList(Task),
    /// 句柄回收方案：保留所有 spawn 过的句柄，deinit 统一 join（已退出的线程
    /// join 立即返回）。备选是 detach，但 detach 后 deinit 无法确认线程真正
    /// 退出，「无线程残留」就失去证据，所以选保留句柄。
    threads: std.ArrayList(Thread),
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    shutdown: bool = false,
    /// 存活 worker 数与空闲（正睡在 cond 上）worker 数；只能在持锁时修改。
    active: usize = 0,
    idle: usize = 0,
    max_workers: usize,
    idle_timeout: Io.Duration,

    pub const Config = struct {
        max_workers: usize,
        idle_timeout: Io.Duration,
    };

    /// 创建空池：一个 worker 都不启动，等第一个 submit 再懒创建。
    pub fn init(allocator: Allocator, io: Io, config: Config) !*Pool {
        if (config.max_workers == 0) return error.InvalidWorkerCount;

        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .tasks = .empty,
            .threads = .empty,
            .max_workers = config.max_workers,
            .idle_timeout = config.idle_timeout,
        };
        return self;
    }

    /// 入队一个任务。决策全部在锁内完成：
    /// 有空闲 worker → signal 复用；无空闲且未达上限 → spawn 新线程；
    /// 已达上限 → 任务排队，等忙碌的 worker 做完手头任务回来取。
    pub fn submit(
        self: *Pool,
        func: *const fn (ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.shutdown) return error.PoolShutdown;
        try self.tasks.append(self.allocator, .{ .func = func, .ctx = ctx });

        if (self.idle > 0) {
            // 有 worker 正睡在 cond 上，叫醒一个。
            // idle += 1 与 waitTimeout 的 epoch 读取都在 worker 持锁时发生，
            // 而 signal 也必须持锁，因此不存在「submit 判完无空闲、worker 才
            // 入睡」的信号丢失缝隙：signal 要么在 worker 入睡前被入队任务挡住
            // （worker 醒来先查队列），要么改变 epoch 使 futex 立即返回。
            self.cond.signal(self.io);
        } else if (self.active < self.max_workers) {
            // 先扩容量再 spawn：若 spawn 成功而 append 失败，线程已在跑而句柄
            // 丢失，deinit 就 join 不到它了。
            try self.threads.ensureUnusedCapacity(self.allocator, 1);
            const t = try Thread.spawn(.{}, workerLoop, .{self});
            self.threads.appendAssumeCapacity(t);
            self.active += 1;
        } else {
            // 已达上限：任务留在队列里等 worker 释放。此刻没有睡眠者，
            // signal 是无害的空操作。
            self.cond.signal(self.io);
        }
    }

    /// 优雅关闭：标记 shutdown、广播唤醒所有睡眠 worker、join 全部句柄。
    /// 语义是排空队列——worker 会把 shutdown 前入队的任务做完。
    /// 调用返回后 Pool 指针已失效：不得再 submit，也不得再次 deinit。
    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);

        // 已因空闲超时退出的线程 join 立即返回；仍在运行的会排空队列后退出。
        for (self.threads.items) |t| t.join();

        self.threads.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 观测用快照（持锁读取），供压测/演示打印证据。
    pub const Stats = struct { active: usize, idle: usize, queued: usize };

    pub fn stats(self: *Pool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .active = self.active,
            .idle = self.idle,
            .queued = self.tasks.items.len,
        };
    }

    fn workerLoop(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        // defer 逆序执行：先 active -= 1（仍在持锁状态，满足「计数只能在
        // 持锁时修改」），再放锁。
        defer self.mutex.unlock(self.io);
        defer self.active -= 1;

        while (true) {
            if (self.tasks.items.len > 0) {
                const task = self.tasks.orderedRemove(0);
                self.mutex.unlock(self.io);
                // 任务在锁外执行：否则一个长任务会堵住所有 submit 和其他 worker。
                task.func(task.ctx);
                self.mutex.lockUncancelable(self.io);
                continue;
            }
            // 先判 shutdown 再入睡：shutdown 与超时退出竞态时以 shutdown 为准，
            // 保证「排空已入队任务」的语义不被超时退出截断。
            if (self.shutdown) return;

            self.idle += 1;
            const woken = self.cond.waitTimeout(self.io, &self.mutex, .{
                .duration = .{ .raw = self.idle_timeout, .clock = .awake },
            });
            self.idle -= 1;

            woken catch |err| switch (err) {
                // std.Io 的 waitTimeout 保证信号优先于超时（见 Io.zig 中
                // waitTimeout 实现注释），走到这里说明没有待消费的 signal。
                // 再确认队列仍空才退出，避免与 submit 竞态丢任务。
                error.Timeout => if (self.tasks.items.len == 0) return,
                // 本池没有取消协议，不会发生；按虚假唤醒处理，回循环复查条件。
                error.Canceled => {},
            };
        }
    }
};
