# 任务交接说明（HANDOFF）

> 给独立审查者 Kimi Code。只描述事实与路径，不下结论、不自评。

- run-id：20261111-1607-threadpool-v1
- 项目根目录：/home/user/Doubao/chats/38453156752940802/threadpool-lab
- 执行者：豆包（主执行 Agent）
- 时间：2026-11-11
- 任务类型：软件工程（教学项目）

## 1. 原始任务

用户为学习系统编程，要用 Zig 0.17 手写一个线程池，体验底层机制。前置对话是核对
Go 语言构造（`go f()`、`fmt.Println`、`os.ReadFile`、`net.Conn.Read`、`time.Sleep`、
`sync.Mutex`、`make([]byte, 大)`、`http.ListenAndServe`）各自对应的 syscall，
用户随后选择「自己做个线程池」作为练习。本次交付的是 v1 固定 worker 数版本，
v2 动态懒创建版作为用户自己的练习。

## 2. 验收标准

- [ ] 代码在 Zig 0.17.0 下可编译、可运行（本机编译器 /home/user/tools/zig-0.17.0/zig）
- [ ] 实现固定数量 worker 的线程池：任务入队、worker 复用、优雅关闭并 join
- [ ] 教学文档讲清 syscall 映射与同步机制（虚假唤醒、wait 原子性、锁外执行、ctx 生命周期）
- [ ] 无内存泄漏/重复释放（DebugAllocator 退出检查）
- [ ] 提供受限沙箱内可用的行为观察手段

## 3. 实际交付

| 文件 | 动作（新建/修改） | 作用 |
|---|---|---|
| src/threadpool.zig | 新建 | Pool 实现：ArrayList 任务队列、Io.Mutex/Condition、worker 循环、init/deinit |
| src/main.zig | 新建 | demo：4 worker 处理 10 个 Job，打印 tid，Io.sleep 模拟工作 |
| build.zig | 新建 | 构建脚本，含 run step |
| scripts/observe.sh | 新建 | 经 /proc/<pid>/task 采样线程数 |
| README.md | 新建 | 教学讲义：syscall 对照表、机制讲解、v2 练习提示、扩展方向 |

## 4. 关键决策

1. 使用 `std.Io.Mutex` / `std.Io.Condition`：Zig 0.17 中同步原语已从 `std.Thread`
   移至 `std.Io`，锁与条件变量的操作均需显式传 Io 实例。
2. 池内统一用 `lockUncancelable` / `waitUncancelable`：池自身没有取消协议，
   避免处理 error.Canceled；可取消版本的存在在注释中说明。
3. Task 采用函数指针 + `*anyopaque` 的类型擦除，而非 comptime 泛型闭包，
   把学习焦点放在线程同步上；泛型闭包列为 README 扩展项。
4. deinit 采用 graceful 语义：shutdown 后 worker 排空队列再退出。
5. 沙箱 apt 源无 strace 候选，观察手段改为 /proc 采样 + `Thread.getCurrentId()` 打印；
   strace/dtruss 命令写在 README 供其他环境使用。

## 5. 验证情况

| 检查 | 命令/方式 | 结果 |
|---|---|---|
| 编译 | zig build | 无错误无警告 |
| 功能实跑 | zig build run | 10 个任务全部 start/done；输出显示 4 个不同 tid 复用（同一 tid 完成一任务后接新任务） |
| 线程数观察 | bash scripts/observe.sh | 采样到 threads alive：1 → 5（主线程+4 worker）→ 3（收尾退出） |
| 干净重建 | rm -rf .zig-cache zig-out && zig build run | 通过；DebugAllocator 未输出泄漏/重复释放报告 |

## 6. 未解决事项

- 已知问题：未实现任务 panic 隔离，worker 内 panic 会按 Zig 默认行为终止进程。
- 未做并发压力测试（仅单次 demo 实跑），锁与条件变量的竞态路径未被高负载实测覆盖。
- 沙箱无法安装 strace，futex 调用仅在标准库源码层确认（Io.zig 中 Mutex/Condition
  经 io.futexWait/futexWake），未做 syscall 级现场观察。
- 假设与前提：ctx 指向内存的存活由提交方保证，demo 靠 deinit 的 join 保证栈数组有效。
- 存疑位置：请审查者重点核对 workerLoop 的等待/退出条件、init 部分 spawn 失败的
  清理路径、shutdown 与条件等待之间是否存在信号丢失或死锁可能。

## 7. 相关路径

- 交付物：
  - /home/user/Doubao/chats/38453156752940802/threadpool-lab/src/threadpool.zig
  - /home/user/Doubao/chats/38453156752940802/threadpool-lab/src/main.zig
  - /home/user/Doubao/chats/38453156752940802/threadpool-lab/build.zig
  - /home/user/Doubao/chats/38453156752940802/threadpool-lab/scripts/observe.sh
  - /home/user/Doubao/chats/38453156752940802/threadpool-lab/README.md
- 参考依据（本机标准库）：
  - /home/user/tools/zig-0.17.0/lib/std/Io.zig（Mutex 1716 行起、Condition 1782 行起、sleep 2597 行）
  - /home/user/tools/zig-0.17.0/lib/std/Thread.zig（spawn 344 行、getCurrentId 279 行）
