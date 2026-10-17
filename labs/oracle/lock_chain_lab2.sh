#!/bin/bash
# 锁链实验第二轮：验证"结束中间环节 / 结束链头"之后下游的实际变化，
# 并用本实例 v$ 视图跑 lstx 同款 SQL（第一轮 gv$ 写法在本 RAC 报 ORA-12850）。
#
# 只结束 client_identifier 以 locklab 开头的实验会话；其余会话一律不碰。
# 用法：SCHEMA=<测试用户名> bash lock_chain_lab2.sh   （oracle 用户）

set -u
SCHEMA=$(echo "${SCHEMA:?请指定 SCHEMA}" | tr '[:lower:]' '[:upper:]')
HOLD=${HOLD:-90}
T="${SCHEMA}.LOCK_LAB_ORDERS"
RUN=/tmp/locklab2.$$
OUT="locklab2_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$RUN"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT"; }
sql() { sqlplus -s / as sysdba <<EOF 2>&1 | tee -a "$OUT"
set linesize 220 pagesize 100 feedback off trimspool on
col client_identifier for a12
col event for a32
col wait_user for a10
col block_user for a10
col object_name for a16
col kill for a60
$1
exit;
EOF
}
val() { sqlplus -s / as sysdba <<EOF | tr -d '[:space:]'
set heading off feedback off pagesize 0
$1
exit;
EOF
}

[ "$(whoami)" = oracle ] || { echo "请切到 oracle 用户运行"; exit 1; }
[ "$(val "select count(*) from dba_tables where owner='$SCHEMA' and table_name='LOCK_LAB_ORDERS';")" = 0 ] \
  || { log "已存在 $T，停止"; exit 1; }

sql "create table $T (id number primary key, status varchar2(20));
insert into $T values (1, 'new');
insert into $T values (2, 'new');
commit;"

session() {
  local tag=$1 delay=$2; shift 2
  (
    sleep "$delay"
    echo "exec dbms_session.set_identifier('$tag')"
    for s in "$@"; do echo "$s"; done
    i=0; while [ ! -f "$RUN/STOP" ] && [ $i -lt "$HOLD" ]; do sleep 1; i=$((i+1)); done
    echo "rollback;"; echo "exit"
  ) | sqlplus -s / as sysdba >>"$RUN/$tag.out" 2>&1 &
}

state() {
  sql "select client_identifier, sid, serial#, status, event, blocking_session, seconds_in_wait
from v\$session where client_identifier like 'locklab%' order by client_identifier;"
}

kill_tag() {  # 只结束指定标识的实验会话
  local tag=$1 sid ser
  sid=$(val "select sid from v\$session where client_identifier = '$tag';")
  ser=$(val "select serial# from v\$session where client_identifier = '$tag';")
  [ -n "$sid" ] || { log "找不到 $tag"; return; }
  log "-- 结束 $tag（sid=$sid serial#=$ser）"
  sql "alter system kill session '$sid,$ser' immediate;"
}

lstx_local() {
  log "-- lstx 同款 SQL（gv\$ 改为本实例 v\$）"
  sql "SELECT w.sid wait_sid, w.username wait_user,
       (select object_name from dba_objects where object_id = w.row_wait_obj#) object_name,
       b.sid block_sid, b.username block_user,
       'XID=' || t.xidusn || '.' || t.xidslot || '.' || t.xidsqn xid
FROM v\$session w
JOIN v\$transaction t ON (TRUNC(w.p2 / POWER(2,16)) = t.xidusn
  AND BITAND(w.p2, TO_NUMBER('FFFF','XXXX')) = t.xidslot AND w.p3 = t.xidsqn)
JOIN v\$session b ON b.taddr = t.addr
WHERE w.event LIKE 'enq: TX%';
SELECT distinct 'alter system kill session '''||b.sid||','||b.serial#||''' immediate;' kill
FROM v\$session w
JOIN v\$transaction t ON (TRUNC(w.p2 / POWER(2,16)) = t.xidusn
  AND BITAND(w.p2, TO_NUMBER('FFFF','XXXX')) = t.xidslot AND w.p3 = t.xidsqn)
JOIN v\$session b ON b.taddr = t.addr
WHERE w.event LIKE 'enq: TX%';"
}

release() { touch "$RUN/STOP"; wait; rm -f "$RUN/STOP"; sql "select id, status from $T order by id;"; }

chain() {  # 不同行串成的链
  session locklab-A 0 "update $T set status = 'A' where id = 1;"
  session locklab-B 2 "update $T set status = 'B' where id = 2;" "update $T set status = 'B' where id = 1;"
  session locklab-C 4 "update $T set status = 'C' where id = 2;"
  sleep 10
}
queue() {  # 同一行排队
  session locklab-A 0 "update $T set status = 'A' where id = 1;"
  session locklab-B 2 "update $T set status = 'B' where id = 1;"
  session locklab-C 4 "update $T set status = 'C' where id = 1;"
  sleep 10
}

log "== 场景 1a：不同行串成的链，结束中间的 B"
chain; state; lstx_local; kill_tag locklab-B; sleep 5; state; release

log "== 场景 1b：不同行串成的链，结束链头 A"
chain; state; kill_tag locklab-A; sleep 5; state; release

log "== 场景 2a：同一行排队，结束 B"
queue; state; lstx_local; kill_tag locklab-B; sleep 5; state; release

log "== 场景 2b：同一行排队，结束链头 A"
queue; state; kill_tag locklab-A; sleep 5; state; release

log "== 清理"
sql "drop table $T purge;"
cat "$RUN"/*.out >>"$OUT" 2>/dev/null; rm -rf "$RUN"
log "完成，完整输出在 $OUT"
