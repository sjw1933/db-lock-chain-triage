#!/bin/bash
# Oracle 锁链实验：造两种三段锁链，跑 dbatool lsblk / lstx，看它们指向谁。
#
# 运行身份：数据库主机上的 oracle 用户（sqlplus / as sysdba，操作系统认证，不用密码）。
# 只动一张实验表 <SCHEMA>.LOCK_LAB_ORDERS：开始前确认不存在，结束时 drop ... purge。
# 实验会话全部以 rollback 结束，不提交任何数据。dbatool lsblk / lstx 只打印 kill 语句，不执行。
#
# 用法：
#   SCHEMA=<测试用户名> DBATOOL=./dbatool-linux-amd64 bash lock_chain_lab.sh
# 可选：ORACLE_SID（默认取当前环境）、HOLD（每个场景最长持锁秒数，默认 120）

set -u
SCHEMA=$(echo "${SCHEMA:?请用 SCHEMA=<测试用户名> 指定实验表所在的用户}" | tr '[:lower:]' '[:upper:]')
DBATOOL=${DBATOOL:-}
HOLD=${HOLD:-120}
T="${SCHEMA}.LOCK_LAB_ORDERS"
RUN=/tmp/locklab.$$
OUT="locklab_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$RUN"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT"; }
sql() { sqlplus -s / as sysdba <<EOF 2>&1 | tee -a "$OUT"
set linesize 220 pagesize 100 feedback off trimspool on
col client_identifier for a12
col wait_event_text for a32
col event for a32
col state for a18
$1
exit;
EOF
}

[ "$(whoami)" = oracle ] || { echo "请切到 oracle 用户运行"; exit 1; }
[ -n "${ORACLE_SID:-}" ] || { echo "ORACLE_SID 未设置"; exit 1; }
command -v sqlplus >/dev/null || { echo "找不到 sqlplus"; exit 1; }

log "== 环境"
sql "select banner from v\$version where rownum = 1;
select instance_name, host_name, version, status from v\$instance;
select name, open_mode, database_role from v\$database;
select username from dba_users where username = '$SCHEMA';"

EXISTS=$(sqlplus -s / as sysdba <<EOF
set heading off feedback off pagesize 0
select count(*) from dba_tables where owner = '$SCHEMA' and table_name = 'LOCK_LAB_ORDERS';
exit;
EOF
)
[ "$(echo $EXISTS | tr -d ' ')" = 0 ] || { log "已存在 $T，停止，不覆盖"; exit 1; }

log "== 建实验表 $T"
sql "create table $T (id number primary key, status varchar2(20));
insert into $T values (1, 'new');
insert into $T values (2, 'new');
commit;"

# 一个实验会话：设置标识 -> 依次执行语句 -> 等到 STOP 文件出现或超时 -> rollback
session() {  # $1=标识 $2=开始前延迟秒数 $3...=语句
  local tag=$1 delay=$2; shift 2
  (
    sleep "$delay"
    echo "exec dbms_session.set_identifier('$tag')"
    for s in "$@"; do echo "$s"; done
    i=0; while [ ! -f "$RUN/STOP" ] && [ $i -lt "$HOLD" ]; do sleep 1; i=$((i+1)); done
    echo "rollback;"; echo "exit"
  ) | sqlplus -s / as sysdba >>"$RUN/$tag.out" 2>&1 &
}

snapshot() {  # 当前实验会话状态 + dbatool 两个命令
  log "-- gv\$session（实验会话）"
  sql "select client_identifier, inst_id, sid, serial#, status, state, event,
       blocking_instance, blocking_session, final_blocking_instance, final_blocking_session, seconds_in_wait
from gv\$session where client_identifier like 'locklab%' order by client_identifier;"
  log "-- v\$wait_chains"
  sql "select instance, sid, sess_serial#, blocker_instance, blocker_sid, blocker_is_valid, num_waiters, wait_event_text, in_wait_secs
from v\$wait_chains order by blocker_is_valid, sid;"
  if [ -n "$DBATOOL" ]; then
    log "-- dbatool lsblk"; "$DBATOOL" lsblk 2>&1 | tee -a "$OUT"
    log "-- dbatool lstx";  "$DBATOOL" lstx  2>&1 | tee -a "$OUT"
  fi
}

release() {
  touch "$RUN/STOP"; wait; rm -f "$RUN/STOP"
  log "-- 会话已全部 rollback 退出"
  sql "select id, status from $T order by id;"
}

log "== 场景一：不同行串成的链  A(行1) <- B(持行2, 等行1) <- C(等行2)"
session locklab-A 0 "update $T set status = 'A' where id = 1;"
session locklab-B 2 "update $T set status = 'B' where id = 2;" "update $T set status = 'B' where id = 1;"
session locklab-C 4 "update $T set status = 'C' where id = 2;"
sleep 12; snapshot; release

log "== 场景二：同一行排队  A(行1) <- B(等行1) <- C(等行1)"
session locklab-A 0 "update $T set status = 'A' where id = 1;"
session locklab-B 2 "update $T set status = 'B' where id = 1;"
session locklab-C 4 "update $T set status = 'C' where id = 1;"
sleep 12; snapshot; release

log "== 清理"
sql "drop table $T purge;"
cat "$RUN"/*.out >>"$OUT" 2>/dev/null; rm -rf "$RUN"
log "完成，完整输出在 $OUT"
