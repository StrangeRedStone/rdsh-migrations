#!/usr/bin/env bash
# rdsh-migrate: from=0.2.1-rc.2 to=0.2.2-rc.1 id=20261105-0.2.1-to-0.2.2 items=sessions,storages,settings,credentials,assets,plugins,profile,probe features=items,sessions-file,profile-relink,plugin-link,extra-files,static-probe summary=0.2.1-rc.2→0.2.2-rc.1：profile链改写+插件挂载修补+附加文件+静态探针
# =============================================================================
# migrate-0.2.1-rc.2-to-0.2.2-rc.1.sh —— 0.2.1-rc.2 → 0.2.2-rc.1 特化迁移提供者（一次性）
#
# 与通用 $MANAGE_ROOT/migrate.sh 同目录、同 CLI：通用版先跑，再补这一对版本的特有步骤。
# 前门 `rdsh migrate` 会同时看到 generic 与本脚本 → 必须显式 --provider 选择。
#
# 为什么需要特化（都是 2026-11-05 实测到的，不是猜的）：
#   1) 通用版把源的 profiles/web/package.json 原样拷进空目标 home，里面的
#      `link:/…/deepseek-harness-dsh-0.2.1-rc.2/packages/...` 仍指向旧检出；不改写则
#      subagent-codex / subagent-claude-code 以 0.2.1 的代码跑在 0.2.2 宿主上。
#   2) 通用版跑 home 里的 plugins/setup.sh 重建挂载链，但 setup.sh 漏登记 2026-11-05
#      新增的 plugin-remove（缺 ln 与 deps）。实测目标实例启动报
#      "1 entry did not activate: @deepseek-ai/dsh-host-plugin-remove"。
#      （已顺手修好 0.2.1 home 的 setup.sh；本脚本仍做通用修补，防止旧 setup.sh 再被拷过去。）
#   3) 通用版只搬 sessions/storages/settings/credentials/plugins/profile，不搬
#      .anonymous-user-id / defaulted-choices.md / wake.log.md / speech-to-text 模型缓存。
#   4) 通用版 --dry-run 在选到 profile 时会 mkdir 目标 home：merge_profile_manifest
#      无条件 `mkdir -p "$DST_HOME/profiles/web"` → plan 不是零写入。本脚本 plan 时
#      把 profile 项交给自己的只读计划打印，确保 --dry-run 零副作用。
#   5) 通用版探针默认 --live；0.2.1 起 headless 隔离 home 不挂存储凭据，live 会因
#      ACCOUNT_SIGN_IN_REQUIRED 误报（skill migrate-specialize 已知点）。本脚本只跑
#      静态+自检；实机验收留给人（启动目标后在会话里跑 compat_check --live）。
#
# 不做：不自动启动目标实例；不改通用 migrate.sh；不改检出；不应用 $SUITE/patches
#       （ask-user-countdown 基线 0.2.0，对 0.2.1/0.2.2 都冲突 —— 只报告，不代拍板）。
# 回退：删本脚本即可（rm <本文件>）；home 回退按通用备份目录里的 README-还原.md。
# =============================================================================
set -euo pipefail

# ---------------- 根目录解析：与通用 migrate.sh 同一套规则 ----------------
RDSH_CONFIG="${RDSH_CONFIG:-$HOME/.config/rdsh/config}"
cfg_get() {
  [ -f "$RDSH_CONFIG" ] || return 0
  local v
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$RDSH_CONFIG" | tail -1)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  printf '%s' "$v"
}
expand_tilde() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
BASE="$(expand_tilde "${RDSH_BASE:-$(cfg_get BASE)}")"; [ -n "$BASE" ] || BASE="$HOME/Mapp"
MANAGE_ROOT="$(expand_tilde "${RDSH_MANAGE_ROOT:-$(cfg_get MANAGE_ROOT)}")"
if [ -z "$MANAGE_ROOT" ]; then
  MANAGE_ROOT="$BASE/dsh"
  if [ ! -f "$MANAGE_ROOT/Rdsh.sh" ]; then
    _self_dir="$(dirname "$(readlink -f "$0")")"
    [ -f "$_self_dir/Rdsh.sh" ] && MANAGE_ROOT="$_self_dir"
  fi
fi
DATA_ROOT="$(expand_tilde "${RDSH_DATA_ROOT:-$(cfg_get DATA_ROOT)}")";         [ -n "$DATA_ROOT" ]   || DATA_ROOT="$BASE/.dsh-suite/data"
BACKUP_ROOT="$(expand_tilde "${RDSH_BACKUP_ROOT:-$(cfg_get BACKUP_ROOT)}")";   [ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="$BASE/.dsh-suite/backup"
SHARED_ROOT="$(expand_tilde "${RDSH_SHARED_HOME:-$(cfg_get SHARED_ROOT)}")";   [ -n "$SHARED_ROOT" ] || SHARED_ROOT="$BASE/.dsh-suite/shared"
PLUGIN_ROOT="$(expand_tilde "${RDSH_PLUGIN_ROOT:-$(cfg_get PLUGIN_ROOT)}")";   [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="$BASE/.dsh-suite/plugins"
GENERIC="$MANAGE_ROOT/migrate.sh"
ALL_ITEMS="sessions,storages,settings,credentials,assets,plugins,profile,probe"

log()  { printf '\033[1;34m[specialize]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[specialize!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[specialize!]\033[0m %s\n' "$*" >&2; exit 2; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
act()  { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

usage() { sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------- 参数（与通用版同契约；前门只会传这些） ----------------
DRY=0; FORCE=0; ITEMS=""; SESSIONS_MODE=""; SESSIONS_FILE=""; SRC_ARG=""; DST_ARG=""
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --dry-run|--plan) DRY=1; shift ;;
    --carry-sessions=*) SESSIONS_MODE="${a#*=}"; shift ;;
    --carry-sessions) [ $# -ge 2 ] || die '--carry-sessions 需要值'; SESSIONS_MODE="$2"; shift 2 ;;
    --sessions=file:*) SESSIONS_MODE=file; SESSIONS_FILE="${a#--sessions=file:}"; shift ;;
    --sessions=*) SESSIONS_MODE="${a#*=}"; shift ;;
    --sessions) [ $# -ge 2 ] || die '--sessions 需要值'; SESSIONS_MODE="$2"; shift 2 ;;
    --sessions-file=*) SESSIONS_MODE=file; SESSIONS_FILE="${a#--sessions-file=}"; shift ;;
    --sessions-file) [ $# -ge 2 ] || die '--sessions-file 需要路径'; SESSIONS_MODE=file; SESSIONS_FILE="$2"; shift 2 ;;
    --items=*) ITEMS="${a#*=}"; shift ;;
    -a|--all) ITEMS="$ALL_ITEMS"; shift ;;
    --items) [ $# -ge 2 ] || die '--items 需要值'; ITEMS="$2"; shift 2 ;;
    --force|-f) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知选项：$a（用 --help）" ;;
    *) if [ -z "$SRC_ARG" ]; then SRC_ARG="$a"; elif [ -z "$DST_ARG" ]; then DST_ARG="$a"; else die "多余参数：$a"; fi; shift ;;
  esac
done
case "${SESSIONS_MODE:-none}" in none|all|file) ;; *) die '--sessions 只能是 none|all|file（file 需 --sessions-file）' ;; esac
SESSIONS_MODE="${SESSIONS_MODE:-none}"
[ "$SESSIONS_MODE" = file ] && [ -z "$SESSIONS_FILE" ] && die '--sessions-file 需要一个 JSON 文件路径'
[ -n "$SRC_ARG" ] && [ -n "$DST_ARG" ] || { usage; die '需要 <from> <to>（或 --help）'; }
[ "$ITEMS" = "all" ] || [ -z "$ITEMS" ] && ITEMS="$ALL_ITEMS"
_norm=""; IFS_SAVE="$IFS"; IFS=','
for it in $ITEMS; do
  it="$(printf '%s' "$it" | tr -d '[:space:]')"; [ -n "$it" ] || continue
  case ",$ALL_ITEMS," in *",$it,"*) ;; *) die "未知 items：$it（可选：$ALL_ITEMS）" ;; esac
  case ",$_norm," in *",$it,"*) ;; *) _norm="${_norm:+$_norm,}$it" ;; esac
done
IFS="$IFS_SAVE"; ITEMS="$_norm"
[ -n "$ITEMS" ] || die '--items 不能为空'
has_item() { case ",$ITEMS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
sub_items() {  # <items> <要剔除的项>
  printf '%s' "$1" | awk -F, -v drop="$2" '{o="";for(i=1;i<=NF;i++) if($i!=drop) o=(o==""?$i:o","$i); print o}'
}

# ---------------- 检出/版本解析：与通用 migrate.sh 一致 ----------------
read_version() {
  local dir="$1" v=""
  [ -f "$dir/package.json" ] && v=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$dir/package.json" | head -1)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$(basename "$dir")"
}
resolve() {
  local arg="$1" i=0 d base ver
  [[ "$arg" == ~* ]] && arg="${arg/#\~/$HOME}"
  if [[ "$arg" == */* || "$arg" == .* ]] && [ -d "$arg" ]; then printf '%s|%s' "$(read_version "$arg")" "$arg"; return; fi
  for d in "$MANAGE_ROOT"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; base="$(basename "$d")"; ver="$(read_version "$d")"
    if [ "$ver" = "$arg" ] || [ "$base" = "$arg" ]; then printf '%s|%s' "$ver" "$d"; return; fi
  done
  for d in "$MANAGE_ROOT"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; base="$(basename "$d")"; ver="$(read_version "$d")"
    if [[ "$ver" == *"$arg"* ]] || [[ "$base" == *"$arg"* ]]; then
      [ "$i" = "1" ] && die "「$arg」匹配到多个检出，请给更精确的版本号/目录名"
      printf '%s|%s' "$ver" "$d"; i=1
    fi
  done
  [ "$i" = "1" ] || die "找不到匹配「$arg」的检出（看 $MANAGE_ROOT）"
}
SRC_INFO="$(resolve "$SRC_ARG")"; SRC_VER="${SRC_INFO%%|*}"; SRC_CHECKOUT="${SRC_INFO#*|}"; SRC_HOME="$DATA_ROOT/$SRC_VER"
DST_INFO="$(resolve "$DST_ARG")"; DST_VER="${DST_INFO%%|*}"; DST_CHECKOUT="${DST_INFO#*|}"; DST_HOME="$DATA_ROOT/$DST_VER"
[ "$SRC_VER" = "0.2.1-rc.2" ] && [ "$DST_VER" = "0.2.2-rc.1" ] || die "本提供者只处理 0.2.1-rc.2 → 0.2.2-rc.1（收到 $SRC_VER → $DST_VER）；其它版本对请用 generic"
[ "$SRC_HOME" != "$DST_HOME" ] || die "源与目标是同一个数据目录（$SRC_HOME）"
[ -d "$SRC_CHECKOUT" ] || die "源检出不存在：$SRC_CHECKOUT"
[ -d "$DST_CHECKOUT" ] || die "目标检出不存在：$DST_CHECKOUT"
[ -d "$SRC_HOME" ] || die "源数据目录不存在：$SRC_HOME"
[ -f "$GENERIC" ] || die "找不到通用迁移器：$GENERIC"
command -v python3 >/dev/null || die '需要 python3'

TS="$(date +%Y%m%d-%H%M%S)"
FIX_BACKUP="$BACKUP_ROOT/migrate-$SRC_VER-to-$DST_VER-$TS-specialize"
NODE_BIN="$(command -v node || true)"
PY=python3

find_running_home() {  # <home> → pid（无则返回 1）
  local want="$1" p h
  for p in /proc/[0-9]*; do
    [ -r "$p/environ" ] || continue
    h="$(tr '\0' '\n' < "$p/environ" 2>/dev/null | sed -nE 's/^DSH_HOME=(.*)$/\1/p' | head -1 || true)"
    [ -n "$h" ] && [ "$h" = "$want" ] && { printf '%s' "${p#/proc/}"; return 0; }
  done
  return 1
}
du_kb() { [ -e "$1" ] && du -sk "$1" 2>/dev/null | awk '{print $1}' || printf '0'; }

# ---------------- 预检（只读；plan 也跑） ----------------
preflight() {
  step "预检（只读）"
  printf '  源   : %s  (home %s)\n' "$SRC_VER" "$SRC_HOME"
  printf '  目标 : %s  (home %s)\n' "$DST_VER" "$DST_HOME"
  printf '  内容 : %s；会话：%s%s\n' "$ITEMS" "$SESSIONS_MODE" "$([ "$SESSIONS_MODE" = file ] && printf "（$SESSIONS_FILE）")"
  printf '  模式 : %s\n' "$([ "$DRY" = "1" ] && echo 'dry-run（零写入）' || echo '实际执行')"
  if [ -f "$DST_CHECKOUT/.installed" ] && [ -d "$DST_CHECKOUT/node_modules" ]; then
    printf '  目标检出：已安装（node_modules + .installed）✅\n'
  else
    warn "目标检出未安装：先跑 \`rdsh install $DST_VER\`，否则迁移完起不来"
  fi
  local tp sp
  if tp="$(find_running_home "$DST_HOME")"; then
    die "安全闸门：目标 home 有实例在跑（pid $tp，$DST_HOME）——先停它；-f 也不越过"
  fi
  if sp="$(find_running_home "$SRC_HOME")"; then
    if [ "$SESSIONS_MODE" != "none" ]; then
      warn "源 home 有实例在跑（pid $sp）：--sessions=$SESSIONS_MODE 会读正在写入的会话；建议先停源实例"
    else
      printf '  源 home 有实例在跑（pid %s）：会话策略 none，只读源数据，可不停\n' "$sp"
    fi
  fi
  # Node：0.2.2 的 engines 要求 >=24.9.0（0.2.1 起就要求；本机实测 node 22 也能 boot，故只警告）
  if [ -n "$NODE_BIN" ]; then
    local nv major minor
    nv="$("$NODE_BIN" -v 2>/dev/null || true)"; nv="${nv#v}"
    major="${nv%%.*}"; minor="${nv#*.}"; minor="${minor%%.*}"
    if awk -v a="${major:-0}" -v b="${minor:-0}" 'BEGIN{exit !(a>24 || (a==24 && b>=9))}'; then
      printf '  node : %s（%s）✅\n' "$NODE_BIN" "$nv"
    else
      warn "node 版本 $nv < 24.9.0（0.2.2 的 engines 要求）→ 建议启动时用 node 24/26；实测 node 22 也能 boot，但不受上游支持"
    fi
  else
    warn '找不到 node：--dump-config 冒烟、plugin install、探针都会跳过'
  fi
  # 磁盘：目标拷贝量 + 通用版备份量 + 200MB 余量
  local need_kb=204800 copy_kb=0 backup_kb=0 avail_kb
  if has_item sessions; then copy_kb=$((copy_kb + $(du_kb "$SRC_HOME/sessions"))); backup_kb=$((backup_kb + $(du_kb "$SRC_HOME/sessions"))); fi
  if has_item storages; then copy_kb=$((copy_kb + $(du_kb "$SRC_HOME/storages"))); backup_kb=$((backup_kb + $(du_kb "$SRC_HOME/storages"))); fi
  if has_item storages; then copy_kb=$((copy_kb + $(du_kb "$SRC_HOME/speech-to-text"))); fi
  if has_item plugins; then copy_kb=$((copy_kb + $(du_kb "$PLUGIN_ROOT"))); backup_kb=$((backup_kb + $(du_kb "$SRC_HOME/plugins"))); fi
  if has_item profile; then copy_kb=$((copy_kb + $(du_kb "$SRC_HOME/profiles/web"))); backup_kb=$((backup_kb + $(du_kb "$SRC_HOME/profiles/web"))); fi
  need_kb=$((copy_kb + backup_kb + need_kb))
  avail_kb="$(df -Pk "$DATA_ROOT" | awk 'NR==2{print $4}')"
  printf '  磁盘 : 预计需 ~%s MB，可用 %s MB\n' "$((need_kb / 1024))" "$((avail_kb / 1024))"
  if [ "$avail_kb" -lt "$need_kb" ]; then
    die "安全闸门：磁盘空间不足（需 ~$((need_kb / 1024)) MB，可用 $((avail_kb / 1024)) MB）"
  fi
  # 补丁集状态：只报告（ask-user-countdown 基线 0.2.0，对 0.2.1/0.2.2 都冲突）
  if [ -f "$MANAGE_ROOT/patch-manager.sh" ]; then
    local pout prc
    set +e
    pout="$(bash "$MANAGE_ROOT/patch-manager.sh" status --repo "$DST_CHECKOUT" 2>&1)"; prc=$?
    set -e
    printf '  补丁集（目标检出）：\n'
    printf '%s\n' "$pout" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'
    if [ "$prc" != "0" ]; then
      warn "补丁集在 $DST_VER 上不干净（退出码 $prc）：本迁移不应用/不还原补丁；需要 ask-user-countdown 行为请单独重导"
    fi
  fi
}

# ---------------- plan 块（只读打印） ----------------
plan_block() {
  step "特化步骤（0.2.1-rc.2 → 0.2.2-rc.1；只读计划，不写入）"
  local nlink nins speech_size
  nlink="$(grep -c 'link:.*deepseek-harness-dsh-' "$SRC_HOME/profiles/web/package.json" 2>/dev/null || true)"
  nins="$(grep -c "name: '@deepseek-ai/dsh-host-\|name: '@deepseek-ai/dsh-client-" "$SRC_HOME/profiles/web/cordis.patch.yml" 2>/dev/null || true)"
  speech_size="（源无此目录）"
  [ -d "$SRC_HOME/speech-to-text" ] && speech_size="$(du -sh "$SRC_HOME/speech-to-text" 2>/dev/null | cut -f1)"
  cat <<EOF
  1) profile 清单：目标 profiles/web/package.json 里 ${nlink:-?} 条 link: 依赖（subagent-codex/claude-code）
     改为指向 $DST_CHECKOUT/packages/...；随后 DSH_HOME=$DST_HOME dsh plugin --profile web install
     重建 profiles/web/node_modules 与 pnpm-lock.yaml。不改则旧检出代码跑在新宿主上（实测缺口）。
  2) 插件挂载：把本地插件运行时依赖软链重指到 0.2.2-rc.1 检出；补齐 patch insert 的 ${nins:-?} 个本地插件
     （含 setup.sh 曾漏登记的 plugin-remove —— 已修 0.2.1 home 的 setup.sh，本脚本再做通用修补）。
  3) 附加 home 文件（assets）：.anonymous-user-id / defaulted-choices.md / wake.log.md（+空 wake/）
     （storages）：speech-to-text 模型缓存（$speech_size，避免首用重下）
     不复制 wake/*.json（避免把旧 home 的待唤醒任务带进新 home）。
  4) 冒烟：目标版本 --dump-config，核对 patch insert 行与覆盖 id 都在组合树里（不启动实例、零端口）。
  5) 探针：compat-check 静态+自检；不跑 --live（0.2.1 起 headless 隔离 home 不挂存储凭据 → 会误报）。
  本脚本不自动启动目标实例；下一步由人执行（见末尾）。
EOF
}

# ---------------- 通用版调用 ----------------
run_generic() {  # $1 = items（已剔除 probe）
  local items="$1"
  local -a args=("$SRC_VER" "$DST_VER" "--items=$items")
  case "$SESSIONS_MODE" in
    none) args+=("--sessions=none") ;;
    all)  args+=("--sessions=all") ;;
    file) args+=("--sessions-file=$SESSIONS_FILE") ;;
  esac
  [ "$FORCE" = "1" ] && args+=("--force")
  [ "$DRY" = "1" ] && args+=("--dry-run")
  bash "$GENERIC" "${args[@]}"
}

# ---------------- 特化修补（只在 apply 跑） ----------------
fix_profile_links() {
  local pj="$DST_HOME/profiles/web/package.json"
  [ -f "$pj" ] || { warn '目标没有 profiles/web/package.json，跳过 link 改写'; return 0; }
  cp -a "$pj" "$FIX_BACKUP/profiles-web-package.json.bak"
  local out
  out="$("$PY" - "$pj" "$DST_CHECKOUT" <<'PY'
import json, os, re, sys
pj, checkout = sys.argv[1], sys.argv[2]
d = json.load(open(pj, encoding='utf-8'))
deps = d.get('dependencies') or {}
changed, unresolved = [], []
for k, v in list(deps.items()):
    if not isinstance(v, str) or not v.startswith('link:'):
        continue
    path = v[5:]
    m = re.search(r'/deepseek-harness-dsh-[^/]+/(packages(?:/.*)?)$', path)
    if not m:
        continue
    cand = os.path.join(checkout, m.group(1))
    if os.path.exists(cand):
        nv = 'link:' + cand
        if nv != v:
            deps[k] = nv; changed.append((k, v, nv))
    else:
        unresolved.append((k, path))
if changed:
    json.dump(d, open(pj, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    open(pj, 'a').write('\n')
for k, o, n in changed:
    print('REWRITE\t%s\t%s\t%s' % (k, o, n))
if not changed:
    print('NOCHANGE')
for k, p in unresolved:
    print('UNRESOLVED\t%s\t%s' % (k, p))
PY
)" || { warn "profile link 改写失败（python），目标 package.json 未改"; return 0; }
  printf '%s\n' "$out" | while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      REWRITE) printf '  + link 改写 %s\n      旧: %s\n      新: %s\n' "$a" "$b" "$c" ;;
      NOCHANGE) printf '  = profile link 无需改写\n' ;;
      UNRESOLVED) warn "link 依赖没有对应的 0.2.2 包：$a（$b）" ;;
    esac
  done
}

fix_plugin_links() {
  local patch="$DST_HOME/profiles/web/cordis.patch.yml"
  local out
  out="$("$PY" - "$DST_HOME" "$DST_CHECKOUT" "$patch" "$FIX_BACKUP/patch-ids.txt" <<'PY'
import glob, json, os, re, sys
home, checkout, patch, id_out = sys.argv[1:5]
plugins = os.path.join(home, 'plugins')
appnm = os.path.join(checkout, 'apps/cli/node_modules/@deepseek-ai')
prof_nm = os.path.join(home, 'profiles/node_modules/@deepseek-ai')

def ensure(link, target):
    if os.path.lexists(link):
        try:
            if os.path.realpath(link) == os.path.realpath(target):
                return False
        except OSError:
            pass
        os.unlink(link)
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(target, link)
    return True

byname = {}
if os.path.isdir(plugins):
    for d in sorted(os.listdir(plugins)):
        pj = os.path.join(plugins, d, 'package.json')
        if not os.path.isfile(pj):
            continue
        try:
            nm = json.load(open(pj, encoding='utf-8')).get('name')
        except Exception:
            continue
        if nm:
            byname[nm] = os.path.join(plugins, d)

relinked, added = [], []
for nm, pdir in byname.items():
    nmp = os.path.join(pdir, 'node_modules/@deepseek-ai')
    if not os.path.isdir(nmp):
        continue
    for dep in sorted(os.listdir(nmp)):
        tgt = os.path.join(appnm, dep)
        if os.path.exists(tgt) and ensure(os.path.join(nmp, dep), tgt):
            relinked.append((os.path.basename(pdir), dep))

for nm, pdir in byname.items():
    lib = os.path.join(pdir, 'lib')
    if not os.path.isdir(lib):
        continue
    for f in glob.glob(os.path.join(lib, '*.mjs')) + glob.glob(os.path.join(lib, '*.js')):
        if f.endswith('.map'):
            continue
        try:
            txt = open(f, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for m in re.findall(r"(?:from\s*|import\s*\(\s*)['\"](@deepseek-ai/[A-Za-z0-9._/-]+)['\"]", txt):
            seg = m.split('/')
            if len(seg) < 2:
                continue
            tgt = os.path.join(appnm, seg[1])
            if not os.path.exists(tgt):
                continue
            link = os.path.join(pdir, 'node_modules/@deepseek-ai', seg[1])
            if ensure(link, tgt):
                added.append((os.path.basename(pdir), '/'.join(seg[:2])))

insert_entries, override_ids = [], []
if os.path.isfile(patch):
    data = None
    try:
        import yaml
        class L(yaml.SafeLoader): pass
        L.add_constructor('tag:yaml.org,2002:js', lambda l, n: l.construct_scalar(n))
        data = yaml.load(open(patch, encoding='utf-8').read(), Loader=L)
    except Exception:
        data = None
    if isinstance(data, list):
        for e in data:
            if not isinstance(e, dict):
                continue
            ins = e.get('insert')
            if isinstance(ins, list):
                for it in ins:
                    if isinstance(it, dict):
                        if it.get('name'):
                            insert_entries.append((str(it.get('id', '')), it['name']))
            if e.get('id'):
                override_ids.append(str(e['id']))
    else:
        txt = open(patch, encoding='utf-8', errors='replace').read()
        insert_entries = [('', n) for n in re.findall(r"name:\s*['\"]?(@deepseek-ai/[A-Za-z0-9._/-]+)", txt)]
        override_ids = re.findall(r"(?m)^- id:\s*['\"]?([A-Za-z0-9._-]+)", txt)

for iid, nm in insert_entries:
    if nm in byname:
        if ensure(os.path.join(prof_nm, nm.split('/')[-1]), byname[nm]):
            added.append(('profile', nm))

with open(id_out, 'w', encoding='utf-8') as fh:
    for iid, nm in insert_entries:
        fh.write('INSERT\t%s\t%s\n' % (iid, nm))
    for iid in override_ids:
        fh.write('OVERRIDE\t%s\n' % iid)

print('STAT\trelink=%d add=%d local_plugins=%d insert=%d override=%d' % (
    len(relinked), len(added), len(byname), len(insert_entries), len(override_ids)))
for p, d in relinked:
    print('  relink %s -> %s' % (p, d))
for p, d in added:
    print('  add %s -> %s' % (p, d))
PY
)" || { warn '插件挂载链修补失败（python）；目标 home 未改'; return 0; }
  printf '%s\n' "$out"
}

run_plugin_install() {
  local pj="$DST_HOME/profiles/web/package.json"
  [ -f "$pj" ] || return 0
  [ -n "$NODE_BIN" ] || { warn '找不到 node：跳过 dsh plugin install（可稍后手工跑）'; return 0; }
  local cli="$DST_CHECKOUT/apps/cli/lib/bin.js"
  [ -f "$cli" ] || { warn "目标检出没有 $cli：跳过 plugin install"; return 0; }
  act "DSH_HOME=$DST_HOME $NODE_BIN $cli plugin --profile web install"
  local out rc
  set +e
  out="$(DSH_HOME="$DST_HOME" "$NODE_BIN" "$cli" plugin --profile web install 2>&1)"; rc=$?
  set -e
  printf '%s\n' "$out" | sed 's/^/    /'
  printf '%s\n' "$out" > "$FIX_BACKUP/plugin-install.log"
  if [ "$rc" != "0" ]; then
    warn "dsh plugin install 失败（rc=$rc）：profile 里 @local/@deepseek-ai link 依赖可能没装好；可手工重跑见本脚本"
  fi
}

smoke_dump_config() {
  [ -n "$NODE_BIN" ] || { warn '找不到 node：跳过 --dump-config 冒烟'; return 0; }
  local cli="$DST_CHECKOUT/apps/cli/lib/bin.js"
  [ -f "$cli" ] || { warn "目标检出没有 $cli：跳过 --dump-config"; return 0; }
  local out="$FIX_BACKUP/dump-config.txt" err="$FIX_BACKUP/dump-config.err"
  act "DSH_HOME=$DST_HOME $NODE_BIN $cli --profile web --dump-config"
  if DSH_HOME="$DST_HOME" "$NODE_BIN" "$cli" --profile web --dump-config >"$out" 2>"$err"; then
    "$PY" - "$out" "$err" "$FIX_BACKUP/patch-ids.txt" <<'PY'
import re, sys
dump, err, ids = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(dump, encoding='utf-8', errors='replace').read()
present = set(re.findall(r'(?m)^- id:\s*(\S+)', txt))
insert, overrides = [], []
try:
    for line in open(ids, encoding='utf-8'):
        p = line.rstrip('\n').split('\t')
        if p and p[0] == 'INSERT' and len(p) >= 3:
            insert.append((p[1], p[2]))
        elif p and p[0] == 'OVERRIDE' and len(p) >= 2:
            overrides.append(p[1])
except OSError:
    pass
miss_i = [(i, n) for i, n in insert if i and i not in present]
miss_o = [i for i in overrides if i not in present]
print('  dump-config: 组合树 %d 个条目；insert %d（缺 %d）；覆盖 id %d（缺 %d）%s' % (
    len(present), len(insert), len(miss_i), len(overrides), len(miss_o),
    ' ✅' if not miss_i and not miss_o else ' ⚠️'))
for i, n in miss_i:
    print('    ⚠️ 缺 insert 条目 %s（%s）' % (i, n))
for i in miss_o:
    print('    ⚠️ 缺覆盖 id %s' % i)
e = open(err, encoding='utf-8', errors='replace').read().strip()
for line in e.splitlines()[:15]:
    print('    stderr: %s' % line)
PY
    printf '  （dump 输出：%s；stderr：%s）\n' "$out" "$err"
  else
    warn "--dump-config 失败（见 $err）"; sed -n '1,10p' "$err" 2>/dev/null | sed 's/^/    /'
  fi
}

run_probe_static() {
  local cli="$DST_HOME/plugins/compat-check/lib/cli.mjs"
  if [ ! -f "$cli" ]; then
    # 目标 home 可能没选 plugins；退回源 home 的探针（只看目标 home，不写目标）
    cli="$SRC_HOME/plugins/compat-check/lib/cli.mjs"
  fi
  [ -f "$cli" ] || { warn '没有 compat-check，跳过探针'; return 0; }
  [ -n "$NODE_BIN" ] || { warn '找不到 node：跳过探针'; return 0; }
  local out="$FIX_BACKUP/compat-report.md" rc
  act "RDSH_BASE=$BASE $NODE_BIN $cli --home $DST_HOME --checkout $DST_CHECKOUT --scope all --selftest --from $SRC_VER（不跑 --live）"
  set +e
  out="$(RDSH_BASE="$BASE" "$NODE_BIN" "$cli" --home "$DST_HOME" --checkout "$DST_CHECKOUT" --scope all --selftest --from "$SRC_VER" 2>&1)"; rc=$?
  set -e
  printf '%s\n' "$out" > "$FIX_BACKUP/compat-report.md"
  printf '%s\n' "$out" | grep -E '^## 结论|^- 自检|^- 实测门|⛔|⚠️' | sed 's/^/  /' || true
  printf '  探针退出码 %s（0 可继续 / 1 有 WARN / 2 有 ERROR；P1：只提示不拦）\n' "$rc"
  printf '  说明：未跑 --live 实测门（0.2.1 起 headless 隔离 home 不挂存储凭据会误报）；启动目标后请在会话里跑 compat_check\n'
}

carry_extra_files() {
  if has_item assets; then
    local f
    for f in .anonymous-user-id defaulted-choices.md wake.log.md; do
      if [ ! -e "$SRC_HOME/$f" ]; then
        printf '  - 源没有 %s，跳过\n' "$f"; continue
      fi
      if [ -e "$DST_HOME/$f" ]; then
        printf '  = %s 目标已有，未动\n' "$f"; continue
      fi
      act "cp -a $SRC_HOME/$f → $DST_HOME/$f"
      [ "$DRY" = "0" ] && cp -a "$SRC_HOME/$f" "$DST_HOME/$f"
      printf '  + %s（保持匿名 ID / 台账 / 唤醒日志连续）\n' "$f"
    done
    act "mkdir -p $DST_HOME/wake"
    [ "$DRY" = "0" ] && mkdir -p "$DST_HOME/wake"
    printf '  不复制 wake/*.json：避免把旧 home 的待唤醒任务带进新 home\n'
  fi
  if has_item storages; then
    local src="$SRC_HOME/speech-to-text"
    if [ -d "$src" ]; then
      if [ -e "$DST_HOME/speech-to-text" ]; then
        printf '  = speech-to-text 目标已有，未动\n'
      else
        act "cp -a $src → $DST_HOME/speech-to-text（$(du -sh "$src" 2>/dev/null | cut -f1)）"
        [ "$DRY" = "0" ] && cp -a "$src" "$DST_HOME/speech-to-text"
        printf '  + speech-to-text 模型缓存（voice-input 首用不重下 231M）\n'
      fi
    else
      printf '  - 源没有 speech-to-text，跳过\n'
    fi
  fi
}

# ---------------- 主流程 ----------------
preflight

if [ "$DRY" = "1" ]; then
  # 零写入：通用版 plan 若带 profile 会 mkdir 目标 home（已知缺陷），故 plan 时剔除 profile 项；
  # probe 也剔除（通用版 plan 会打印 --live，而特化版不跑 --live），都由本脚本的只读计划块展示。
  PLAN_ITEMS="$(sub_items "$(sub_items "$ITEMS" profile)" probe)"
  if [ -n "$PLAN_ITEMS" ]; then
    log "通用迁移器计划（items=$PLAN_ITEMS；profile 与 probe 项由特化脚本单独打印，避免 dry-run 写入）"
    run_generic "$PLAN_ITEMS"
  else
    log '只选了 profile/probe：通用迁移器无计划可跑，直接看特化计划'
  fi
  plan_block
  echo
  printf '\033[1;36m== dry-run 结束 ==\033[0m\n（零写入：没有创建目标 home / 备份 / 任何文件）\n'
  exit 0
fi

# ---- apply ----
step "特化迁移：$SRC_VER → $DST_VER"
GITEMS="$(sub_items "$ITEMS" probe)"
if [ -n "$GITEMS" ]; then
  log "先跑通用迁移器（items=$GITEMS；probe 留到最后，等修补完再跑）"
  run_generic "$GITEMS"
  [ -d "$DST_HOME" ] || die "通用迁移后目标 home 不存在：$DST_HOME"
else
  warn '只选了 probe：跳过通用迁移主体'
  [ -d "$DST_HOME" ] || die "目标 home 不存在，没有可探的对象：$DST_HOME"
fi
mkdir -p "$FIX_BACKUP"
{ echo "# 特化步骤日志（$TS）"; echo "源=$SRC_VER 目标=$DST_VER items=$ITEMS sessions=$SESSIONS_MODE"; echo; } > "$FIX_BACKUP/特化步骤.log"

if has_item profile || has_item plugins; then
  step "特化 1/4：profile 清单 link 改写（旧检出 → $DST_VER）"
  if has_item profile; then
    { echo '## profile link 改写'; fix_profile_links; } 2>&1 | tee -a "$FIX_BACKUP/特化步骤.log"
  else
    printf '  - 未选 profile，跳过\n'
  fi
  step "特化 2/4：插件挂载链修补（重指目标检出的运行时依赖 + 补 patch insert 的本地插件）"
  if has_item plugins; then
    { echo; echo '## 插件挂载链'; fix_plugin_links; } 2>&1 | tee -a "$FIX_BACKUP/特化步骤.log"
  else
    printf '  - 未选 plugins，跳过（若选了 profile，仍会跑 plugin install）\n'
  fi
  step "特化 3/4：dsh plugin --profile web install（重建 profile node_modules / pnpm-lock）"
  run_plugin_install 2>&1 | tee -a "$FIX_BACKUP/特化步骤.log"
else
  step "特化 1-3/4：未选 profile/plugins，跳过 profile 与插件修补"
fi

step "特化 4/4：附加 home 文件"
carry_extra_files 2>&1 | tee -a "$FIX_BACKUP/特化步骤.log"

if has_item profile; then
  step "冒烟：目标版本 --dump-config（不启动实例）"
  smoke_dump_config 2>&1 | tee -a "$FIX_BACKUP/特化步骤.log"
fi
if has_item probe; then
  step "探针：compat-check 静态 + 自检（不跑 --live）"
  run_probe_static 2>&1 | tee -a "$FIX_BACKUP/特化步骤.log"
fi

step "完成"
printf '  特化日志与产物：%s\n' "$FIX_BACKUP"
printf '  通用版备份：%s/migrate-%s-to-%s-*（含 README-还原.md）\n' "$BACKUP_ROOT" "$SRC_VER" "$DST_VER"
cat <<EOF

  下一步（由人执行；本脚本不自动启动目标）：
    1) 先停当前实例（3080 上还跑着 $SRC_VER）：rdsh stop 3080
    2) rdsh start $DST_VER
    3) 验收：启动日志无 failed to import / did not activate / patch: entry ... not found
       界面里 @local 插件、subagent 工具、记忆库工具在；会话（若选了）可打开

  已知项（只报告，不代拍板）：
    - 补丁集 ask-user-countdown（基线 0.2.0）对 0.2.1/0.2.2 都冲突，未应用；要倒计时行为需重导补丁。
    - fs-observation-policy 在 0.2.2 出厂 disabled（write 可覆盖未读文件、edit 不再查陈旧版本）。
      要保留 0.2.1 的旧行为，在 $DST_HOME/profiles/web/cordis.patch.yml 追加：
          - id: fs-observation-policy
            disabled: false
    - 新增可选 bundle（可稍后在插件管理器里开）：@deepseek-ai/dsh-experimental-forge-bundle、
      @deepseek-ai/dsh-experimental-liveshare、@deepseek-ai/dsh-personalized-recommendations
    - 0.2.2 移除 @deepseek-ai/dsh-client-ui-deepseek-model-label-1017 与 tool-subagent-list-agents
      （本机 profile/插件未引用，仅产品变化）。
EOF
exit 0
