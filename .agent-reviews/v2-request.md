# v2 需求：动态线程池（豆包 → Kimi Code）

目标：在保留 v1（src/threadpool.zig 原样不动）的前提下，实现 Go 运行时式
「任务先入队，线程不够才 clone；空闲线程自动退出」的动态池，并附压力冒烟。

## 功能要求

1. 初始零 worker。submit 决策（全部在锁内）：
   - 有空闲 worker → `cond.signal` 复用；
   - 无空闲且存活线程数 < 上限 → 新 `Thread.spawn`，计数 +1；
   - 已达上限 → 任务排队，等待 worker 释放。
2. worker 空闲等待使用 `Condition.waitTimeout`：超时且队列仍空 → 线程退出，
   计数 -1；信号优先于超时（std.Io 的 waitTimeout 已实现此规则，直接利用）。
3. shutdown 语义与 v1 一致：标记后排空已入队任务，所有 worker 退出，无线程残留、
   无句柄泄漏（detach 或保存句柄 join，方案自选但要在代码注释说明取舍）。
4. Task 接口与 v1 保持一致（`fn(*anyopaque) void` + 上下文指针），
   空闲超时与线程上限做成可配置参数。

## 竞态硬要求

- 存活/空闲计数只能在持锁时修改；任务在锁外执行。
- 想清楚两个缝隙：submit 判「无空闲」与 worker 进入等待之间；
  shutdown 与 worker 超时退出之间。不得出现信号丢失、死锁、计数漂移。

## 交付与自检

- 新建独立文件（如 src/dynamic_pool.zig）+ 可运行的压测入口；
  build.zig 增加对应产物，v1 的文件与 demo 保持可用。
- 压测：线程上限 8、提交 1000 个任务，原子计数执行数，断言 == 1000。
- 行为实测：低速提交时线程数按需增长（懒创建）；提交停止后等过超时，
  线程数回落到零（空闲退出），用 /proc 或日志给出证据。
- 先落盘后精修；`zig build` 零告警；不做 git 操作，不做自审。
