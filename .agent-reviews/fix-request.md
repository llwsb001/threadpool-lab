# 修复需求（豆包 → Kimi Code）

依据：你上一轮的审查报告 `.agent-reviews/20261111-1607-threadpool-v1/REVIEW.md`。
目标：修复其中 P1/P2/P3，保持 v1 线程池的核心调度逻辑不变。

## 必做项

1. P1 — 观察路径必须可用
   - `scripts/observe.sh` 在项目从未构建过的情况下也要能直接跑通（脚本内先构建，
     或检测到二进制缺失时输出明确错误信息并以非零码退出；禁止打印误导性的
     `threads alive: 0`）。
   - README「运行」小节给出的命令顺序，新人照做必须全程走通，无隐藏前置步骤。

2. P2 — 订正线程创建的教学表述
   - README syscall 对照表与 `src/threadpool.zig` 注释中，线程创建路径改为准确表述：
     未链接 libc 时 `std.Thread.spawn` 经 LinuxThreadImpl 直接发 `clone`；
     链接 libc 时才经 pthread_create。表述需与本项目实际构建配置一致。

3. P3 — 声明 deinit 的接口约束
   - `deinit` docstring 明确：调用返回后 Pool 指针失效，不得再 submit 或 deinit。

## 约束

- 不改 worker 调度/等待/关闭的核心逻辑，只做上述修复与文档订正。
- 改完自检：`zig build` 零告警；`zig build run` 10 任务正常；
  `bash scripts/observe.sh` 在干净状态（无 zig-out）下实测可跑。
- 先落盘后精修：每个文件先 Write 再 Edit，避免长任务中断丢内容。
- 不做新一轮审查，不执行 git push。
