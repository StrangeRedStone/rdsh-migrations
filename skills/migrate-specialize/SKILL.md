---
name: migrate-specialize
description: 按版本对生成一次性迁移提供者。需要为某次 dsh 升级写特化 migrate.sh、使用迁移前门、或把特化脚本归档到 rdsh-migrations 时使用。
---
# migrate-specialize —— 按版本对生成一次性迁移提供者

## 仓库

- 特化脚本的归档仓库：`~/workspace/rdsh-migrations`（GitHub `StrangeRedStone/rdsh-migrations`）。
- **运行时仍放 `$MANAGE_ROOT`**；需要留档时才把脚本复制到该仓库（`migrate-<from>-to-<to>[-<id>].sh`），更新 `index.md`，本地 commit；push 由用户执行。
- 仓库只存特化脚本与说明；禁止会话/凭据/日志。

## 定义域

- **迁移前门**：`plugins.d/rdsh-migrate.sh` 提供的 `rdsh migrate`。只负责流程（选提供者 / plan 闸门 / 日志 / 下一步），所有选择显式参数。
- **通用版**：`$MANAGE_ROOT/migrate.sh`（原名原位，长期保留、可直接跑作应急）。
- **特化版**：`$MANAGE_ROOT/migrate-<from>-to-<to>[-<id>].sh`。**一次性**：需要时生成，用完可删；与通用版同目录、靠文件头区分，不新开目录、不建 registry。
- **提供者契约**：与通用版相同的 CLI：
  ```
  <provider> <from> <to> --items=a,b,c --sessions=none|all|file:<json> [--dry-run] [--force]
  ```
  `--dry-run` 必须零副作用；真迁移写自己的日志；错误返回非零。安全闸门（目标在跑/无备份/磁盘/权限/隐私）永远硬停。
- **不做**：图形界面、TTY 交互、自动启动目标、改通用脚本。

## 什么时候用

`rdsh migrate --from <a> --to <b> ...` 发现多个提供者时，或你判断通用版对这对版本缺少关键步骤时。
**不需要特化就明说“不需要”**，不要为一次性版本硬造资产。

## 步骤

### 1. 取材（只读）

```bash
G="$MANAGE_ROOT/migrate.sh"              # 通用素材
B="$MANAGE_ROOT/deepseek-harness-dsh-<to>" # 目标检出
# 目标版本官方升级指南（中文优先）
find "$B/docs/upgrade-guide" -name 'guide.zh.md' | sort
# 本机历史与事实
sed -n '1,80p' "$G"; rdsh list; rdsh state list
# 上次迁移的体检记录（如果有）
ls "$SUITE/backup"/migrate-*
```

### 2. 列差异（产物是一张表）

至少核对：profile 清单（`profiles/web/package.json` 的 dependencies/bundles）、插件 API/schema、settings/凭据链、被上游移除/改名的包、探针/日志/启动行为、会话格式。
每条写：**现象 → 通用版是否覆盖 → 特化动作**。

### 3. 决定是否生成

- 通用版已覆盖 → 不生成，直接 `rdsh migrate --provider generic ...`。
- 有版本特有步骤 → 生成特化版。

### 4. 生成（与通用版同目录）

```bash
A="$MANAGE_ROOT/migrate-<from>-to-<to>.sh"
cp -a "$MANAGE_ROOT/migrate.sh" "$A"
chmod +x "$A"
```

在文件头**加一行**（前门用 `sed` 读；字段值不能含空格，摘要放 summary）：

```bash
#!/usr/bin/env bash
# rdsh-migrate: from=<from> to=<to> id=<短id> items=sessions,storages,settings,credentials,assets,plugins,profile,probe features=items,sessions-file summary=<一句话>
```

然后按差异表插入特化逻辑；**不要改通用版**。若特化逻辑只涉及“跑完通用步骤后补几步”，可在脚本里先 `bash "$MANAGE_ROOT/migrate.sh" ...` 再补；但 plan 模式也必须零写入。

### 5. 静态与 zero-write 校验

```bash
bash -n "$A"
rdsh migrate --list                       # 应能看到特化版（from/to 匹配时）
rdsh migrate --from <from> --to <to> --items assets --sessions none --dry-run --provider <id>
# 期望：plan 退出 0，且目标 home 没有任何新写入（前后 find -newer 对照）
```

如果 plan 需要真实环境但会写盘，说明设计不合格：plan 必须只读。

### 6. 交付

报告：脚本路径、差异表/特化动作、plan 结果、未验证项、删除命令（`rm "$A"`）、回退方式。
真迁移由用户/前门执行；**不要自己 --dry-run 之外动目标 home**。

### 7. 归档（可选）

若用户要留档：
```bash
R="$HOME/workspace/rdsh-migrations"
cp "$A" "$R/"
# 更新 $R/index.md 一行（from→to / 文件 / 日期 / 状态 / 说明）
cd "$R" && git add -A && git commit -m "migrate: <from> → <to>"
# push 由用户执行
```

## 0.2.0→0.2.1 的已知特化点（样例，不是通例）

- profile 清单丢失：迁移器只搬 `cordis.patch.yml`，需合并 `profiles/web/package.json` 的本地依赖/bundles + node_modules 软链；
- 上游移除运行时不变式注册表：patch 里的 `@deepseek-ai/dsh-invariants` / `*/invariant` 行与插件伴生要删；
- 探针 CLI 默认 workdir 受 `RDSH_BASE` 影响：调用前导出 `RDSH_BASE`;
- 0.2.1 headless 不挂存储凭据/账号 provider：compat-check `--live` 会失败，别把它当目标不兼容；
- 会话挑选：通用版支持 `--sessions-file`（来自 `session-archive pick --select-only`），特化版无需重复实现。

## 负样本（必须失败/必须拒绝）

- 特化版没有 `--dry-run` 零写入 → 不接受；
- `--items` 含未知项 → 必须报错，不静默忽略；
- 目标实例在跑、无备份、磁盘不足 → 必须硬停；
- 通用 `migrate.sh` 被特化生成过程修改 → 必须发现并还原（比对 mtime/校验和）。

## 边界

- 不要生成“第二份通用脚本”：特化只放版本差异，通用仍为唯一兜底。
- 特化脚本用完即弃；长期归档单开仓库（用户 2026-11-01 已建仓，路径见其说明），不要塞回 rdsh 主仓库。
- 所有凭证/会话内容不进报告；迁移日志可能含路径，汇报时按需打码。
