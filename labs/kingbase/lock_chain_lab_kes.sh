#!/bin/bash
# KingbaseES 锁链实验：同一时刻采齐「日志 + 视图 + 进程表」，并验证结束不同会话后的变化。
#
# 运行：opc 用户（需免密 sudo 读服务器日志、看进程表），ksql 以 system 经 127.0.0.1 连 54322（临时 trust）。
# 只动实验表 locklab_orders：开始前确认不存在，结束时 drop。会话全部以 rollback 结束。
# 只结束 application_name 以 locklab 开头的实验会话。

set -u
B=/opt/Kingbase/ES/V9/KESRealPro/V009R002C014/Server/bin
export LD_LIBRARY_PATH=$B/../lib
PORT=54322; DB=test; U=system
PGDATA_DIR=/home/kingbaseo/data
MAINPID=$(sudo -n head -1 $PGDATA_DIR/kingbase.pid)
LOG=$(sudo -n sh -c "ls -t $PGDATA_DIR/sys_log/*.log" | head -1)
HOLD=${HOLD:-120}
WAIT=${WAIT:-40}          # 造好锁后等多久再采证据（日志在等锁约 30 秒后才写）
RUN=/tmp/locklab-kes.$$; mkdir -p "$RUN"
OUT="$PWD/kes_locklab_$(date +%Y%m%d_%H%M%S).log"
T=locklab_orders

log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT"; }
q()   { $B/ksql -w -h 127.0.0.1 -p $PORT -U $U -d $DB -X -q -c "$1" 2>&1 | tee -a "$OUT"; }
val() { $B/ksql -w -h 127.0.0.1 -p $PORT -U $U -d $DB -X -At -c "$1" 2>/dev/null | tr -d '[:space:]'; }

session() {  # $1=标识 $2=延迟 $3..=语句
  local tag=$1 delay=$2; shift 2
  (
    sleep "$delay"
    echo "set application_name = '$tag';"
    echo "begin;"
    for s in "$@"; do echo "$s"; done
    i=0; while [ ! -f "$RUN/STOP" ] && [ $i -lt "$HOLD" ]; do sleep 1; i=$((i+1)); done
    echo "rollback;"; echo "\\q"
  ) | $B/ksql -w -h 127.0.0.1 -p $PORT -U $U -d $DB -X >>"$RUN/$tag.out" 2>&1 &
}

pid_of() { val "select pid from sys_catalog.sys_stat_activity where application_name = '$1';"; }

evidence() {  # 三类证据
  local since=$1
  log "-- 证据一：主机进程表"
  ps --ppid "$MAINPID" -o pid,etime,args | grep -E "PID|system $DB 127.0.0.1" | grep -v grep | tee -a "$OUT"
  log "-- 证据二：库内视图（lock_evidence.sql）"
  q "select count(*) as waiting_lock_count from sys_catalog.sys_locks where granted = false;"
  q "select a.pid as blocked_pid, a.application_name as blocked_app, left(a.query, 80) as blocked_query,
       b.pid as blocking_pid, b.application_name as blocking_app, left(b.query, 80) as blocking_query
from sys_catalog.sys_locks blocked
join sys_catalog.sys_stat_activity a on a.pid = blocked.pid
join sys_catalog.sys_locks blocker on blocker.locktype = blocked.locktype
  and blocker.database is not distinct from blocked.database
  and blocker.relation is not distinct from blocked.relation
  and blocker.page is not distinct from blocked.page
  and blocker.tuple is not distinct from blocked.tuple
  and blocker.virtualxid is not distinct from blocked.virtualxid
  and blocker.transactionid is not distinct from blocked.transactionid
  and blocker.classid is not distinct from blocked.classid
  and blocker.objid is not distinct from blocked.objid
  and blocker.objsubid is not distinct from blocked.objsubid
  and blocker.pid <> blocked.pid
join sys_catalog.sys_stat_activity b on b.pid = blocker.pid
where not blocked.granted and blocker.granted;"
  q "select pid, application_name, state, now() - xact_start as xact_duration, wait_event_type, wait_event, left(query, 60) as query
from sys_catalog.sys_stat_activity
where backend_type = 'client backend' and xact_start is not null and application_name like 'locklab%'
order by xact_start nulls last;"
  q "select coalesce(state, 'null') as state, count(*) as connections from sys_catalog.sys_stat_activity
where backend_type = 'client backend' group by state order by connections desc;"
  log "-- 证据三：服务器日志（$since 之后的 still waiting / 终止类记录）"
  sudo -n awk -v s="$since" '$1" "$2 >= s' "$LOG" | grep -E "still waiting|Process holding|STATEMENT|CONTEXT|deadlock|lock timeout|terminating connection" \
    | grep -E "\[($(pid_list))\]" | tee -a "$OUT" > "$RUN/lockwait.log"
  cp "$RUN/lockwait.log" "$PWD/kes_lockwait_$(date +%H%M%S).log"
}
pid_list() { val "select string_agg(pid::text, '|') from sys_catalog.sys_stat_activity where application_name like 'locklab%';"; }

blocking_now() {
  log "-- 结束后的阻塞关系（sys_blocking_pids 视角之外，直接看阻塞对）"
  q "select a.application_name as blocked_app, a.pid, a.state, a.wait_event_type, a.wait_event,
       (select string_agg(b.application_name, ',') from sys_catalog.sys_stat_activity b
          join sys_catalog.sys_locks bl on bl.pid = b.pid and bl.granted
          join sys_catalog.sys_locks wl on wl.pid = a.pid and not wl.granted
           and bl.locktype = wl.locktype
           and bl.transactionid is not distinct from wl.transactionid
           and bl.relation is not distinct from wl.relation
           and bl.tuple is not distinct from wl.tuple
           and bl.page is not distinct from wl.page
         where b.pid <> a.pid) as blocked_by
from sys_catalog.sys_stat_activity a
where a.application_name like 'locklab%' order by a.application_name;"
}

kill_tag() {
  local tag=$1 pid; pid=$(pid_of "$tag")
  [ -n "$pid" ] || { log "找不到 $tag"; return; }
  log "-- 结束 $tag（pid=$pid）"
  q "select sys_terminate_backend($pid);"
}

release() { touch "$RUN/STOP"; wait; rm -f "$RUN/STOP"; q "select id, status from $T order by id;"; }

# ---------- 准备 ----------
log "== 环境：$($B/ksql -w -h 127.0.0.1 -p $PORT -U $U -d $DB -X -At -c 'select version()')，主进程 $MAINPID，日志 $LOG"
q "show log_lock_waits;"; q "show deadlock_timeout;"; q "show lock_timeout;"
[ "$(val "select count(*) from sys_catalog.sys_class where relname = '$T';")" = 0 ] || { log "已存在 $T，停止"; exit 1; }
q "create table $T (id int primary key, status varchar(20));"
q "insert into $T values (1, 'new');"
q "insert into $T values (2, 'new');"
log "实验表所在 schema：$(val "select n.nspname from sys_catalog.sys_class c join sys_catalog.sys_namespace n on n.oid = c.relnamespace where c.relname = '$T';")"

# ---------- 场景 1a：同一行排队，采齐证据后结束中间的 B ----------
log "== 场景 1a：同一行排队 A <- B <- C，结束中间的 B"
S=$(date '+%F %T')
session locklab-A 0 "update $T set status = 'A' where id = 1;"
session locklab-B 2 "update $T set status = 'B' where id = 1;"
session locklab-C 4 "update $T set status = 'C' where id = 1;"
sleep "$WAIT"; evidence "$S"
kill_tag locklab-B; sleep 3; blocking_now; release

# ---------- 场景 1b：同一行排队，结束链头 A ----------
log "== 场景 1b：同一行排队，结束链头 A"
session locklab-A 0 "update $T set status = 'A' where id = 1;"
session locklab-B 2 "update $T set status = 'B' where id = 1;"
session locklab-C 4 "update $T set status = 'C' where id = 1;"
sleep 8; blocking_now
kill_tag locklab-A; sleep 3; blocking_now; release

# ---------- 场景 2：不同行串成的链，结束中间的 B ----------
log "== 场景 2：不同行的链 A(行1) <- B(持行2, 等行1) <- C(等行2)，结束中间的 B"
session locklab-A 0 "update $T set status = 'A' where id = 1;"
session locklab-B 2 "update $T set status = 'B' where id = 2;" "update $T set status = 'B' where id = 1;"
session locklab-C 4 "update $T set status = 'C' where id = 2;"
sleep 8; blocking_now
kill_tag locklab-B; sleep 3; blocking_now; release

# ---------- 清理 ----------
log "== 清理"
q "drop table $T;"
cat "$RUN"/*.out >>"$OUT" 2>/dev/null; rm -rf "$RUN"
log "完成：$OUT"
