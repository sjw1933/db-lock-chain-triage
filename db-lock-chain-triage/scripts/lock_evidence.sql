-- db-lock-chain-triage：锁等待现场采集 SQL（全部只读）
-- 适用：KingbaseES Oracle 兼容模式（视图在 sys_catalog 下）。
-- MySQL 兼容模式把 sys_catalog.sys_locks / sys_catalog.sys_stat_activity
-- 换成 sys_locks / sys_stat_activity 即可，其余不变。
-- 来源：故障分析助手巡检采集模板（锁与阻塞、事务与清理、连接与会话三组），
-- Oracle / MySQL 兼容模式实测 14/14 项、0.5 秒。
--
-- 账号要求：只读账号 + sys_read_all_stats 预置角色，否则别人会话的 SQL
-- 显示为 <insufficient privilege>，按 backend_type 过滤的计数也会偏小。
--   GRANT sys_read_all_stats TO nlq_reader;   -- 由 DBA 执行，代价：能看到其他会话正在执行的 SQL 原文

-- 1. 等待锁的数量（只做定性：>0 说明现在有人在等）
select count(*) as waiting_lock_count
from sys_catalog.sys_locks
where granted = false;

-- 2. 阻塞对：谁等谁。一行是一条边，链头要靠多行拼出来，不能只看第一行
select a.pid as blocked_pid,
       a.usename as blocked_user,
       left(a.query, 200) as blocked_query,
       b.pid as blocking_pid,
       b.usename as blocking_user,
       left(b.query, 200) as blocking_query
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
where not blocked.granted and blocker.granted;

-- 3. 未结束的事务，按开始时间排。链头常常是这里排第一的 idle in transaction
select pid,
       usename,
       application_name,
       client_addr,
       state,
       now() - xact_start as xact_duration,
       now() - query_start as query_duration,
       wait_event_type,
       wait_event,
       left(query, 200) as query
from sys_catalog.sys_stat_activity
where backend_type = 'client backend'
  and xact_start is not null
order by xact_start nulls last;

-- 4. 连接按状态分布：用来判断“看全了没有”。总数明显少于进程表，说明权限不够
select coalesce(state, 'null') as state,
       count(*) as connections
from sys_catalog.sys_stat_activity
where backend_type = 'client backend'
group by state
order by connections desc;
