#!/usr/bin/env python3
"""从 KingbaseES 服务器日志里还原锁等待链，找出链头。

只读：只解析日志文本，不连数据库。
输入：一个或多个日志文件（sys_log/kingbase-*.log 的片段即可）。
输出：每条链的链头、等待者、等待对象、最长已等待时长、最后一次记录时间。

识别的日志格式（实例记录锁等待时写出的三行一组）：
  ... [PID] LOG:  process PID still waiting for <锁> after <毫秒> ms
  ... [PID] DETAIL:  Process holding the lock: A, B. Wait queue: X, Y.
  ... [PID] STATEMENT:  <语句>
"""
import re
import sys
from collections import defaultdict

TS = r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?"
WAIT = re.compile(TS + r".*?\[(\d+)\] LOG:\s+process \d+ still waiting for (.+?) after ([\d.]+) ms")
HOLD = re.compile(r"\[(\d+)\] DETAIL:\s+Process holding the lock: ([\d, ]+)\.")
STMT = re.compile(r"\[(\d+)\] STATEMENT:\s+(.+)")
SIGNALS = ("deadlock detected", "lock timeout", "canceling statement", "terminating connection")


def parse(paths):
    waiter = {}            # pid -> {lock, wait_ms, last_ts, count}
    holders = defaultdict(set)
    stmt = {}
    signals = defaultdict(int)
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                for s in SIGNALS:
                    if s in line:
                        signals[s] += 1
                m = WAIT.search(line)
                if m:
                    ts, pid, lock, ms = m.group(1), m.group(2), m.group(3), float(m.group(4))
                    w = waiter.setdefault(pid, {"lock": lock, "wait_ms": 0.0, "last_ts": ts, "count": 0})
                    w["count"] += 1
                    if ms >= w["wait_ms"]:
                        w.update(lock=lock, wait_ms=ms, last_ts=ts)
                    continue
                m = HOLD.search(line)
                if m:
                    holders[m.group(1)].update(p.strip() for p in m.group(2).split(",") if p.strip())
                    continue
                m = STMT.search(line)
                if m:
                    stmt[m.group(1)] = m.group(2).strip()
    return waiter, holders, stmt, signals


def chain_head(pid, holders, seen=None):
    """沿“等谁”一路往上走，走到不再等别人的进程就是链头；成环则返回 None。"""
    seen = seen or set()
    if pid in seen:
        return None
    seen.add(pid)
    ups = holders.get(pid)
    if not ups:
        return pid
    heads = {chain_head(u, holders, set(seen)) for u in ups}
    heads.discard(None)
    return sorted(heads)[0] if heads else None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    waiter, holders, stmt, signals = parse(sys.argv[1:])
    if not waiter:
        print("日志中没有 still waiting for 记录。注意：没有记录不等于没有锁等待，"
              "可能是实例没有记录锁等待日志，或等待时长没超过阈值。")
        return
    chains = defaultdict(list)
    loops = []
    for pid in waiter:
        head = chain_head(pid, holders)
        if head is None:
            loops.append(pid)
        else:
            chains[head].append(pid)
    for head, members in sorted(chains.items()):
        print(f"== 链头 {head}" + ("（日志里没有它的等待记录，是持锁方）" if head not in waiter else ""))
        for pid in sorted(members, key=lambda p: -waiter[p]["wait_ms"]):
            w = waiter[pid]
            up = ",".join(sorted(holders.get(pid, []))) or "?"
            print(f"   {pid} 等 {up} | {w['lock']} | 最长已等 {w['wait_ms']/1000:.1f}s"
                  f" | 记录 {w['count']} 条，最后 {w['last_ts']}")
            if pid in stmt:
                print(f"      语句: {stmt[pid]}")
    if loops:
        print("== 成环（疑似死锁）进程: " + ", ".join(sorted(loops)))
    print("== 同时段终止类信号: " + (", ".join(f"{k}×{v}" for k, v in signals.items()) or "无"))


if __name__ == "__main__":
    main()
