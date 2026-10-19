-- db-lock-chain-triage：Oracle 阻塞链（只读）
-- 取自作者生产排障在用的 Oracle 运维脚本（bash 版与 Go 版 dbatool）的 lsblk，Oracle 19c RAC 实测可用。
-- 只打印 kill 语句，不执行；是否执行由 DBA 决定。
set linesize 500 pagesize 999 numwidth 5
col event for a30
col sid for a15
col sql_text for a60
col kill for a60
SET TRANSACTION READ ONLY;

select name from v$database;

select inst_id, event, count(*)
from gv$session
where wait_class# <> 6
group by inst_id, event
order by 2;

with blocked as (
    select instance, sid, serial, bl_inst, bl_sid, bl_serial, lv, r_instance, r_sid, r_serial, num_waiters, blocker_chain_id, rownum rn
    from (
        select instance,
               to_char(sid) sid,
               sess_serial# serial,
               blocker_instance bl_inst,
               blocker_sid bl_sid,
               blocker_sess_serial# bl_serial,
               level lv,
               CONNECT_BY_ROOT(instance) r_instance,
               CONNECT_BY_ROOT(sid) r_sid,
               CONNECT_BY_ROOT(sess_serial#) r_serial,
               num_waiters,
               blocker_chain_id
        from v$wait_chains
        connect by prior sid = blocker_sid
               and prior sess_serial# = blocker_sess_serial#
               and prior instance = blocker_instance
        start with blocker_is_valid = 'FALSE'
    )
    where num_waiters > 0 or bl_sid is not null
)
select instance,
       lpad(' ', 2 * (lv - 1)) || blocked.sid sid,
       serial,
       g.sql_id,
       g.event
from blocked, gv$session g
where g.sid = blocked.sid
  and g.inst_id = blocked.instance
order by rn;

with blocked as (
    select instance, sid, serial, bl_inst, bl_sid, bl_serial, lv, r_instance, r_sid, r_serial, num_waiters, blocker_chain_id, rownum rn
    from (
        select instance,
               to_char(sid) sid,
               sess_serial# serial,
               blocker_instance bl_inst,
               blocker_sid bl_sid,
               blocker_sess_serial# bl_serial,
               level lv,
               CONNECT_BY_ROOT(instance) r_instance,
               CONNECT_BY_ROOT(sid) r_sid,
               CONNECT_BY_ROOT(sess_serial#) r_serial,
               num_waiters,
               blocker_chain_id
        from v$wait_chains
        connect by prior sid = blocker_sid
               and prior sess_serial# = blocker_sess_serial#
               and prior instance = blocker_instance
        start with blocker_is_valid = 'FALSE'
    )
    where num_waiters > 0 or bl_sid is not null
)
select distinct 'alter system kill session '''||r_sid||','||r_serial||',@'||r_instance||''' immediate;' kill
from blocked, gv$session g
where g.sid = blocked.sid
  and g.inst_id = blocked.instance
  and g.type <> 'BACKGROUND';
commit;
exit;
