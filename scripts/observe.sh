#!/usr/bin/env bash
# 无 strace 时的替代观察手段：/proc/<pid>/task 下每个子目录就是一个线程。
set -e
cd "$(dirname "$0")/.."

./zig-out/bin/threadpool-lab >/dev/null 2>&1 &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  printf "threads alive: %d\n" "$(ls /proc/$pid/task 2>/dev/null | wc -l | tr -d ' ')"
  sleep 0.02
done
wait "$pid"
