# 迁移提供者清单

> 只列特化脚本；状态由生成/测试者更新。

| from → to | 文件 | 生成日期 | 状态 | 说明 |
|---|---|---|---|---|
| 0.2.1-rc.2 → 0.2.2-rc.1 | `migrate-0.2.1-rc.2-to-0.2.2-rc.1.sh` | 2026-11-05 | 已使用 | ①profile 里 `link:` 依赖从旧检出改写为目标检出并 `dsh plugin install`；②插件挂载链重指目标检出 + 补 `setup.sh` 漏登记的 `plugin-remove`；③补搬 `.anonymous-user-id`/`defaulted-choices.md`/`wake.log.md`/`speech-to-text` 模型缓存；④plan 零写入（规避通用版 dry-run 的 `mkdir` 副作用）；⑤只跑 compat-check 静态+自检（`--live` 因 headless 不挂存储凭据会误报） |

## 状态定义

- `未验证`：已生成，未跑 plan/隔离验证。
- `已验证`：`--dry-run` 零写入通过；隔离 home 实机冒烟通过（启动 0 未激活 + `--dump-config` insert/override 全命中）。
- `已使用`：在某次真迁移中用过（注明备份/日志位置，不在本仓库存日志）。
- `已废弃`：版本对过时或脚本被替代。

## 0.2.1-rc.2 → 0.2.2-rc.1 的验证证据（2026-11-05）

- plan：`rdsh migrate --from 0.2.1-rc.2 --to 0.2.2-rc.1 --items=… --sessions none --dry-run --provider 20261105-0.2.1-to-0.2.2` 退出 0，目标 home 未创建、备份未创建。
- 隔离 apply（`RDSH_DATA_ROOT` 指向临时目录，源 home 只读复制）：通用版 + 特化步骤后，目标版本实机 `dsh web` 启动日志 **0 个 `did not activate`**，`--dump-config` 的 14 条 insert / 17 条覆盖 id 全命中，HTTP 返回 401（服务正常要 token）。
- 负样本：特化前同一流程启动报 `1 entry did not activate: @deepseek-ai/dsh-host-plugin-remove`；目标 home 有实例在跑时 plan/apply 硬停（`-f` 不越过）；未知 `--items` 报错退出 2。
- 未做：`compat-check --live` 实机门（headless 凭据已知问题，启动目标后在会话内复跑）。

## 已用于真机迁移（2026-11-05 23:43，用户执行）

- 本脚本已由**用户**用于 0.2.1-rc.2 → 0.2.2-rc.1 的**真机迁移**（不是只在隔离环境验证）：迁移完成后停掉 0.2.1 实例，2026-11-06 08:03 启动 0.2.2 实例——当前在用的这一版就是这次迁移的产物。
- 证据（本机，不在本仓库）：备份 `$SUITE/backup/migrate-0.2.1-rc.2-to-0.2.2-rc.1-20261105-234346/`；特化步骤日志 `$SUITE/backup/migrate-0.2.1-rc.2-to-0.2.2-rc.1-20261105-234345-specialize/{特化步骤.log,dump-config.txt,patch-ids.txt,plugin-install.log}`；迁移日志 `$SUITE/logs/migrate-0.2.1-rc.2-to-0.2.2-rc.1-20261105-234345*.log`。
- 部署副本与仓库副本 md5 一致：`d7f86212861fecc9873d5a5535242165`。

## 配套技能

- `skills/migrate-specialize/SKILL.md` —— 特化提供者的生成/验证/归档流程（本仓库公开分享版；运行时权威副本在 `$SUITE/shared/skills/migrate-specialize/`）。
