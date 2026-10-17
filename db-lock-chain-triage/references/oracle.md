# Oracle：取证视图与实测结果

环境：Oracle 19c EE 双节点 RAC（orcl1@rac1、orcl2@rac2），2026-10-14。实验表 TEST01.LOCK_LAB_ORDERS 两行数据，三个会话 A、B、C 全部在实例 1，实验结束全部 rollback 并 drop。
完整日志见 `samples/oracle-19c-rac-*.log`。

## 拼链用 v$wait_chains

SQL 取自 dbatool 的 lsblk 子命令（作者自用的 Oracle 运维工具，bash 脚本的 Go 重写版），见 `scripts/oracle_wait_chains.sql`。要点：

- `start with blocker_is_valid = 'FALSE'`：从不再等别人的会话开始往下展开，也就是从链头开始
- `CONNECT_BY_ROOT(sid)`：每个等待者都能直接拿到自己所属链的链头
- 生成的 kill 语句只针对链头，并用 `g.type <> 'BACKGROUND'` 排除后台进程
- 开头 `SET TRANSACTION READ ONLY`

## 实测：两种链形

| 场景 | 构造 | v$wait_chains 给出的结构 |
|---|---|---|
| 不同行串成的链 | A 改行 1；B 改行 2 后再改行 1；C 改行 2 | A ← B ← C，三层 |
| 同一行排队 | A、B、C 依次改行 1 | B、C 都直接挂在 A 下，星形 |

同一行排队在 KingbaseES 上测出的是三层链（C 等 B 持有的行锁），Oracle 上是星形（B、C 都等 A 的事务）。Skill 不能预设链的形状，只能拼出来再看。

## 实测：结束不同会话之后

| 场景 | 结束谁 | 之后的状态 |
|---|---|---|
| 不同行的链 | 中间的 B | C 立刻拿到行 2 执行完；A 仍持有行 1；B 的事务被回滚 |
| 不同行的链 | 链头 A | B 拿到行 1 执行完，转为 INACTIVE 持有两行；C 改为等 B |
| 同一行排队 | B | C 仍在等，阻塞者仍是 A |
| 同一行排队 | 链头 A | B 拿到行 1；C 改为等 B |

结论：
- 同一行排队，结束非链头的会话没有任何用处
- 不同行的链，结束中间环节能放行下游，代价是回滚一个本来在正常等锁的业务事务，链头照样占着锁
- 结束链头之后，后面的会话按顺序推进；下游还会再等一下，等的是刚拿到锁的那个会话提交

## 实测：两个工具给出的 kill 名单不一样

不同行的链，同一时刻：

| 工具 | 给出的 kill |
|---|---|
| lsblk（v$wait_chains + CONNECT_BY_ROOT） | 只有 A |
| lstx 同款 SQL（按每个等待者的直接阻塞者） | A 和 B |

lstx 把中间的 B 也列了进去。照着它的名单全部执行，就是多回滚了一个正常事务。

## 实测：视图之间对不上

- 第一轮"不同行的链"，v$wait_chains 已经给出三层链，同一时刻 gv$session 里 B、C 的 blocking_session、final_blocking_session 都是空的
- 第二轮"同一行排队"，B 的 blocking_session 有值，C 的却是空的；结束 A 之后 C 的 blocking_session 才显示为 B

blocking_session 为空不能当成"没有被堵"。以 v$wait_chains 为准，gv$session 只做补充。

## 实测：工具本身也会失败

dbatool lstx 原版用 gv$session 关联 gv$transaction，在这套 RAC 上两次都报：

    ORA-12850: Could not allocate slaves on all specified instances: 2 needed, 1 allocated

根因没有查。改成本实例 v$ 视图后能跑出结果，但只覆盖本实例的会话。Skill 遇到这种情况要写明"只看了实例 1"，不能当成全集群的结论。

## 实验口径说明

实验会话用 `/ as sysdba` 连接，所以 wait_user、block_user 显示为 SYS；锁的对象是 TEST01 下的实验表。
