# db-lock-chain-triage

数据库锁等待根因定位 Skill。用服务器日志、主机进程表、库内锁视图三类证据拼出阻塞链，找到链头（不再等别人的那个会话），排除遗留会话和旧证据的干扰，给出带依据、可由 DBA 确认后执行的处置建议。

目录约定和 CloudQ、WorkBuddy 的 Skill 一致（SKILL.md + references + scripts），在 KingbaseES 和 Oracle 19c RAC 上做过实测，并在 WorkBuddy 和 CloudQ 中挂载调用过。

配套文章：《锁等待先找链头：一个 DBA Skill 在 WorkBuddy 和 CloudQ 里的实测》（腾讯云架构师技术同盟 · AIOps 最佳实践 · CloudQ 共创计划征文）。

## 目录

```
db-lock-chain-triage/                 Skill 本体，整个目录即可挂载
├── SKILL.md                          元数据、执行步骤、安全边界、铁律
├── references/evidence-rules.md      10 条判断规则，每条附真实反例或实测
├── references/oracle.md              Oracle 取证视图与 RAC 实测结果
├── scripts/lock_log_chain.py         解析 KingbaseES 服务器日志，还原链和链头，不连库
├── scripts/lock_evidence.sql         KingbaseES 4 条只读 SQL
├── scripts/oracle_wait_chains.sql    Oracle 用 v$wait_chains 从链头展开整条链，只读
└── samples/                          实测日志
labs/                                 锁链复现实验脚本（只在测试库上运行）
├── kingbase/lock_chain_lab_kes.sh
└── oracle/lock_chain_lab.sh, lock_chain_lab2.sh
workbuddy-runs/                       WorkBuddy、CloudQ 挂载测试的输入证据、诊断报告和实测记录，以及 WorkBuddy 自行修改 Skill 的 diff
```

## 安装

WorkBuddy：把 `db-lock-chain-triage/` 整个目录复制到 `~/.workbuddy/skills/`，重启 WorkBuddy，在"专家·技能·连接器 → 技能 → 已安装"里确认启用。

CloudQ：在 CloudQ 控制台「Skills · MCP · 知识库 → Skill → 导入 SKILL」上传 zip 包（把 `db-lock-chain-triage/` 目录打包即可，SKILL.md 位于一级子目录）。实测中 CloudQ 不一定会自动选中自定义 Skill，使用时在对话输入框的 Skills 里手动选中。CloudQ 在云端运行，读不到本机文件，证据需要以文本形式贴进对话。

其他支持 SKILL.md 约定的 Agent 平台，按各自的技能目录放置即可。改动 SKILL.md 后建议先校验 YAML 头：

```bash
python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]).read().split('---')[1])['name'])" db-lock-chain-triage/SKILL.md
```

## 使用

直接用自然语言描述现象并给出证据，例如：

> 订单支付卡住了，帮我看看谁堵住了谁、该怎么处理。实例是 KingbaseES V009R002C014，Oracle 兼容模式。三类证据在 ./evidence/ 下：主机进程表、库内视图（lock_evidence.sql 的输出）、服务器日志。

日志解析脚本也可以单独运行：

```bash
python3 db-lock-chain-triage/scripts/lock_log_chain.py db-lock-chain-triage/samples/kes-oracle-mode-20260913-1536.log
```

## 实测环境

| 数据库 | 版本 | 内容 |
|---|---|---|
| KingbaseES | V009R002C014（Oracle 兼容模式） | 同一行三段锁链复现，三类证据同时采集，结束不同会话后的对照 |
| KingbaseES | Oracle / MySQL 兼容模式 | 巡检 SQL 14 项实测 |
| Oracle | 19c EE 双节点 RAC | 不同行链与同一行排队两种链形，v$wait_chains 拼链，kill 名单对照 |

## 安全边界

- Skill 只做只读诊断，不执行结束会话、取消语句、DDL、DML。处置建议由 DBA 确认后自己执行。
- `labs/` 下的实验脚本会建表、造锁并结束实验会话，只能在测试库上运行。脚本只操作自己建的实验表和带 `locklab` 标识的会话，结束时回滚并删除实验表。
- 样例日志中的数据库用户名已替换为 `app_user`，主机地址、密码等信息已去除。

## 已知限制

- 达梦等其他数据库的取证视图还没有写进 Skill。
- Oracle RAC 上按 gv$ 关联 gv$transaction 的查询在实测环境报 ORA-12850，根因未查；降级到本实例 v$ 视图时只覆盖本实例。
- CloudQ 中实测：第一版规则下，手动选中 Skill 后曾把「结束中间会话可放行下游」用到同一行排队的链上（与实测不符），也没有指出视图与进程表的连接数差异；改写执行步骤（先判断同行还是不同行、核对证据数量）后在 CloudQ 中复测，两处问题都没有再出现，记录见 `workbuddy-runs/2026-10-19-CloudQ/`。仅一次复测，样本有限。CloudQ 从云侧发现异常再交给本 Skill 的联动尚未测试。

## 许可

MIT，见 [LICENSE](LICENSE)。
