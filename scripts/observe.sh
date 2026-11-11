#!/usr/bin/env bash
# 无 strace 时的替代观察手段：/proc/<pid>/task 下每个子目录就是一个线程。
set -e
cd "$(dirname "$0")/.."

bin=./zig-out/bin/threadpool-lab
if [[ ! -x "$bin" ]]; then
  if ! command -v zig >/dev/null 2>&1; then
    echo "observe.sh: $bin 不存在，且 PATH 中找不到 zig，无法自动构建。" >&2
    echo "请先运行 zig build，或把 zig 加入 PATH 后重试。" >&2
    exit 1
  fi
  echo "observe.sh: $bin 不存在，自动执行 zig build ..." >&2
  zig build
fi

"$bin" >/dev/null 2>&1 &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  # ls 失败（进程恰好退出）时 n 为 0，跳过而不是打印误导性的 "threads alive: 0"
  n=$(ls "/proc/$pid/task" 2>/dev/null | wc -l)
  if [[ "$n" -gt 0 ]]; then
    printf "threads alive: %d\n" "$n"
  fi
  sleep 0.02
done
wait "$pid"
