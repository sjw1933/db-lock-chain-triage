---
name: db-lock-chain-triage
description: >-
  对数据库锁等待做根因定位——用服务器日志、进程表和锁视图三类证据拼出阻塞链，找到链头，
  排除遗留会话和旧证据的干扰，给出带依据的处置建议。当用户提到「接口卡住」「锁等待」「谁堵住了谁」
  「still waiting for」「idle in transaction」「enq: TX - row lock contention」时使用。
  已在 KingbaseES（Oracle / MySQL 兼容模式）和 Oracle 19c RAC 上实测。
  仅做只读诊断，结束会话等处置由 DBA 确认后自己执行。
---

# 锁等待根因定位

## 工具与证据边界

- `scripts/lock_log_chain.py`：解析 KingbaseES 服务器日志的 still waiting for 记录，还原链和链头，不连库
- `scripts/lock_evidence.sql`：KingbaseES 四条只读 SQL（等锁数、阻塞对、未结束事务、连接分布）
- `scripts/oracle_wait_chains.sql`：Oracle 用 v$wait_chains 从链头展开整条链，只读
- 主机进程表（`ps --ppid <实例主进程>`）：KingbaseES 可选，能看到 `idle in transaction`、`UPDATE waiting`

SQL 通过平台的只读 SQL 工具执行。证据只来自「日志 + 视图 + 进程表」三类。应用日志、业务代码不在范围内；需要它们才能定论的，只输出假设并标注待验证。
判断规则和反例见 `references/evidence-rules.md`；Oracle 的视图差异和实测结果见 `references/oracle.md`。遇到计数对不上、权限不足、多条链并存、视图之间对不上时按需读取。

## 执行步骤

1. 确认采集口径：数据库类型与版本、实例（RAC 写明看了哪几个实例）、采集时间、账号权限。只用最新一次巡检，旧巡检只在做前后对比时才纳入
2. 拼链：KingbaseES 用日志脚本 + 阻塞对 SQL，两边合并去重；Oracle 用 v$wait_chains。一行只是一条边，必须拼到「不再等别人」的那个会话才算链头。不预设链的形状，同一行排队在不同数据库上可能是串行链，也可能是星形
3. 看链头：查链头的状态和事务时长。空闲却持有事务（KingbaseES 的 idle in transaction，Oracle 的 INACTIVE + SQL*Net message from client）说明它拿了锁但什么都没在做；它显示的 SQL 只是最后执行过的一条，不一定是拿锁的那条
4. 分组与排除：按锁对象把链分组，互不相干的链分开报；后台进程之间的等待链剔除；事务时长超过业务正常值一个数量级的会话单独标为「遗留会话」
5. 输出：链结构、链头、各等待者已等时长、依据、置信度及为什么不是更高、下一步只读验证或待 DBA 确认的处置

## 安全边界

只读诊断，不执行结束会话、取消语句、DDL、DML。
建议结束会话时，写明结束哪一个、对方未提交的事务会被回滚、结束之后下游预计怎么变化，由 DBA 确认后执行。
工具自动生成的 kill 名单，必须先和链头核对再转给 DBA，不原样转发。
采集账号的权限不足时，如实报告「看不全」，不替用户提权，给出授权语句和代价由 DBA 决定。

## 铁律

- 链头以「不再等别人」为准，不以等得最久、语句最显眼为准。处置建议默认指向链头：同一行排队时结束中间会话没有用；不同行串成的链，结束中间会话能放行下游，但要回滚一个正常业务事务，链头照样占着锁
- 判断有没有锁等待，看查询结果，不看证据里有没有锁查询的文本
- 出现 `<insufficient privilege>`、连接数明显少于进程表、blocking_session 为空但等待事件是锁、RAC 只查到部分实例，结论都是「看不全」，不是「没有」
- 置信度必须说明为什么不是更高；日志和视图、视图和视图对不上时上报差异，不挑一边用
