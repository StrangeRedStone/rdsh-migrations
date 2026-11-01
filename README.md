# rdsh-migrations

rdsh / dsh 的**一次性版本迁移提供者**仓库：存放“从旧版本迁到新版本”的特化 `migrate.sh`。
运行时仍由 rdsh 的迁移前门 `rdsh migrate` 调用；本仓库只做归档/分享，不是 rdsh 的下载内容。

## 它和 rdsh 主仓库的分工

| 位置 | 内容 |
|---|---|
| `rdsh` 主仓库 / 部署目录 | 通用 `migrate.sh`、前门 `plugins.d/rdsh-migrate.sh`、`rdsh cd` 等长期能力 |
| **本仓库** | 只放**版本对特化**的 `migrate-<from>-to-<to>[-<id>].sh`，一次性；用完可删 |
| 运行目录 | 把本仓库的脚本复制到 `$(rdsh cd --manage)/`，`rdsh migrate` 就能发现 |

## 文件与命名

```
migrate-<from>-to-<to>[-<id>].sh    # 与通用 migrate.sh 同目录运行；文件头自述
index.md                            # 清单（版本对/日期/状态/说明）
```

每个特化脚本第一行元数据（前门用 `sed` 读，字段不能含空格）：

```bash
#!/usr/bin/env bash
# rdsh-migrate: from=0.2.0-rc.2 to=0.2.1-rc.2 id=20261025-0.2.0-to-0.2.1 items=sessions,storages,settings,credentials,assets,plugins,profile,probe summary=一句话
```

## 使用

```bash
# 1) 取到本机运行目录
M="$(rdsh cd --manage)"
cp migrate-0.2.0-rc.2-to-0.2.1-rc.2.sh "$M/"

# 2) 看前门发现了什么
rdsh migrate --list

# 3) 只读预演（目标实例必须已停）
rdsh migrate --from 0.2.0-rc.2 --to 0.2.1-rc.2 \
  --items profile,plugins --sessions none --dry-run --provider <id>

# 4) 真迁移（日志在 $SUITE/logs；用户随后启动目标确认）
rdsh migrate --from 0.2.0-rc.2 --to 0.2.1-rc.2 --items ... --provider <id>
```

完成后本机那份可删；仓库里的保留作档案。

## 提供者契约

- 与通用 `migrate.sh` 相同的 CLI：`<from> <to> --items=... --sessions=none|all|file:<json> [--dry-run] [--force]`
- `--dry-run` 必须**零副作用**；真迁移自己写日志；错误返回非零。
- 安全闸门（目标 home 在跑/无备份/磁盘/权限/隐私）永远硬停，`-f` 不越过。
- 不自动启动目标实例。

## 禁止放入

- 会话数据、`.credentials.yaml`、备份目录、日志原件、任何密钥/令牌。
- 与版本无关的通用逻辑（那属于 rdsh 主仓库的 `migrate.sh`）。

## 生成方式

用 rdsh 的 skill `migrate-specialize`（在 `$SUITE/shared/skills/migrate-specialize/`）生成；
不要手写整份迁移器，也不要把通用脚本复制进来冒充特化版。
