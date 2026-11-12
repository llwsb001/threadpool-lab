# threadpool-lab：手写线程池（Zig 0.17）

学习目标：不用任何运行时魔法，自己拼出「任务队列 + worker 线程 + 阻塞唤醒」，
并对照每个操作在 Linux 上对应的 syscall。

## 运行

```bash
zig build run                  # 编译并运行 demo
bash scripts/observe.sh        # 用 /proc 采样观察线程数变化（二进制缺失时自动 zig build）
```

## 结构

```
threadpool-lab/
├── build.zig
├── scripts/observe.sh         # /proc 线程数采样
└── src/
    ├── threadpool.zig         # 池实现：v1 固定 worker 数
    ├── main.zig               # demo：4 worker 处理 10 任务
    ├── dynamic_pool.zig       # 池实现：v2 懒创建 + 空闲超时退出
    └── stress.zig             # v2 压测与行为演示（zig build stress）
```

## 架构

```
submit()                ┌─────────────────────────────┐
  锁内入队 ArrayList ──▶│ tasks: ArrayList(Task)      │
  cond.signal()         └──────────────┬──────────────┘
                                       │  mutex 保护
  worker 1 ─ cond.wait ───────┐        │
  worker 2 ─ cond.wait ───────┤ 醒来取队首，锁外执行 task.func
  worker N ─ cond.wait ───────┘
```

## syscall 对照

| 代码 | 0.17 设施 | Linux 底层 |
|---|---|---|
| `std.Thread.spawn` | 线程创建 | 本项目未链接 libc：`LinuxThreadImpl` 直接发 `clone`；链接 libc 的构建才经 pthread_create → `clone` |
| `mutex.lock/unlock` | `std.Io.Mutex` | 快路径 CAS（无 syscall）；争用后 `futex` |
| `cond.wait/signal` | `std.Io.Condition` | `futex(FUTEX_WAIT/WAKE)` |
| `Io.sleep` | 定时器 | `clock_nanosleep`（经 Io 后端） |
| 任务缓冲 | `ArrayList` | 堆内存；大块经分配器走 `mmap` |

注意 0.17 的设计：**同步原语全部归 `std.Io` 管**，`Mutex.lock(io)`、`Condition.wait(io, ...)`
都要显式传 Io 实例。本池用 `lockUncancelable` / `waitUncancelable`，因为池自身没有
取消协议；可取消版本在任务被 `cancel` 时返回 `error.Canceled`。

## 必须理解的四个机制

1. **wait 的 while 循环**：条件变量允许虚假唤醒；且多个 worker 被同时唤醒时只有一个能
   抢到任务，其余必须回去继续睡。用 `if` 而非 `while` 会在空队列上取越界。
2. **wait 的原子性**：`wait` 原子地「释放 mutex → 睡眠」，被唤醒后先重新拿锁才返回。
   否则 signal 可能发生在「解锁后、睡眠前」的缝隙里，信号永久丢失。
3. **锁外执行任务**：拿着锁跑 task.func，一个长任务会堵住所有 submit 和其他 worker。
4. **ctx 生命周期**：池只存 `*anyopaque`，不管理上下文内存。demo 里靠 `deinit` 的
   `join` 保证栈上 jobs 数组存活到最后一个任务结束。提前释放就是 use-after-free。

## 观察手段

```bash
# 当前沙箱装不了 strace（apt 源无候选），用 /proc 采样：
bash scripts/observe.sh
# 预期：threads alive 从 1（主线程）变 5（+4 worker），收尾时回落

# 在有 strace 的机器上（Linux）：
strace -f -e trace=futex,clone,clone3,clock_nanosleep ./zig-out/bin/threadpool-lab
# macOS 对应：sudo dtruss -f ./zig-out/bin/threadpool-lab
```

## 练习 v2：动态线程池（懒创建 + 空闲退出）

> 本仓库已含参考实现 `src/dynamic_pool.zig`，压测与行为演示跑 `zig build stress`。
> 建议先自己写一遍再对照。

目标：复刻 Go 运行时「任务先入队，线程不够才 clone；空闲太久的线程自动退出」。

设计提示：

- 新增字段：`active`（存活 worker 数）、`idle`（等待中的 worker 数）、
  `max_workers`、空闲超时 `std.Io.Timeout`。
- `submit` 决策（全部在锁内）：
  - `idle > 0` → `cond.signal`，复用现有 worker；
  - `idle == 0 且 active < max_workers` → 新 `Thread.spawn`，`active += 1`；
  - 已达上限 → 任务排队，仍 signal 等 worker 释放。
- worker 等待改用 `cond.waitTimeout(io, &mutex, timeout)`：
  - 返回 `error.Timeout` 且队列仍空 → 线程退出，`active -= 1`；
  - 信号优先于超时（读 `Io.zig` 中 `waitTimeout` 源码可见这条规则）。
- 线程句柄回收：退出的线程要么 `detach`，要么保留句柄在 shutdown 时统一 join，
  先想清楚两种方案下 shutdown 怎么枚举存活线程。
- 所有计数只能在持锁时修改；shutdown 与超时退出存在竞态，先判 shutdown。

## 更多扩展方向

1. 泛型 `submit`：用 comptime 闭包结构替代 `*anyopaque`（参考旧版 `std.Thread.Pool`
   的 RunNode 类型擦除模式）。
2. WaitGroup：提交方等待一批任务全部完成。
3. 工作窃取：每个 worker 自己的双端队列，空闲时偷别人的任务（`std.Io.Evented` 的思路）。
4. 再往下走：用 `std.posix` 直接写 `epoll` 版 echo server，把网络 I/O 也接进池。
