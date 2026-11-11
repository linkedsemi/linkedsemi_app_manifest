#!/usr/bin/env bash
#
# 批量编译 810_driver_test/projects 下的所有 Zephyr 工程，检查是否有编译错误。
#
# 判定一个目录是"可编译工程"的条件：同时包含 CMakeLists.txt 和 prj.conf。
#
# 板级自动选择（依据 810_driver_test/SPEC_REFERENCE.md §6.1.10）：
#   - 单核工程（工程目录下只有 cpu1_* 一个固件目录）: lsqsh_evb@1os/lsqsh/cpu1
#   - 双核工程的 cpu1 侧                           : lsqsh_evb@2os/lsqsh/cpu1
#   - 双核工程的另一核（cpu0_* / cpu2_*）          : lsqsh_evb@2os/lsqsh/cpu2
#   用 -b 可以强制所有工程使用同一个板级。
#
# 用法：
#   ./build_all_apps.sh                 # 编译默认目录下所有工程（自动选板级）
#   ./build_all_apps.sh --list          # 只列出会被编译的工程及其板级
#   ./build_all_apps.sh -a 810_driver_test/projects/spi_test
#   ./build_all_apps.sh -b 'lsqsh_evb@2os/lsqsh/cpu1' -d build -t 600
#
# 特点：
#   - 顺序执行，不会出现多个 west build 并发清理同一个 build 目录的问题
#   - 每个工程的完整日志单独保存
#   - 某个工程失败不会中断，最后统一汇总并返回非 0 退出码
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

BOARD=""    # 空 = 按工程自动选择；非空 = 强制该板级
APPS_DIR="$WORKSPACE/810_driver_test/projects"
BUILD_DIR="build"
LOG_ROOT="$WORKSPACE/build_logs"
TIMEOUT_SECS=0
STOP_ON_ERROR=0
LIST_ONLY=0

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  -b, --board BOARD       强制所有工程使用该板级 (默认: 按单核/双核规则自动选择)
  -a, --apps-dir DIR      要扫描的目录 (默认: 810_driver_test/projects)
  -d, --build-dir DIR     构建目录 (默认: build，相对工作区根目录)
  -l, --log-dir DIR       日志根目录 (默认: build_logs)
  -t, --timeout SECONDS   单个工程超时时间，0 表示不限制 (默认: 0)
      --stop-on-error     第一个失败就停止
      --list              只列出工程，不编译
  -h, --help              显示帮助

自动选板级规则:
  单核工程 (只有 cpu1_* 固件目录) : lsqsh_evb@1os/lsqsh/cpu1
  双核工程 cpu1 侧               : lsqsh_evb@2os/lsqsh/cpu1
  双核工程另一核 (cpu0_*/cpu2_*) : lsqsh_evb@2os/lsqsh/cpu2

示例:
  $(basename "$0")
  $(basename "$0") --list
  $(basename "$0") -a 810_driver_test/projects/spi_test
  $(basename "$0") -b 'lsqsh_evb@2os/lsqsh/cpu1' -d build
EOF
}

die() {
    echo "错误: $*" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--board)       BOARD="${2:-}"; shift 2 ;;
        -a|--apps-dir)    APPS_DIR="${2:-}"; shift 2 ;;
        -d|--build-dir)   BUILD_DIR="${2:-}"; shift 2 ;;
        -l|--log-dir)     LOG_ROOT="${2:-}"; shift 2 ;;
        -t|--timeout)     TIMEOUT_SECS="${2:-}"; shift 2 ;;
        --stop-on-error)  STOP_ON_ERROR=1; shift ;;
        --list)           LIST_ONLY=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "未知参数: $1" >&2; usage; exit 2 ;;
    esac
done

# 相对路径统一按工作区根目录解析
case "$APPS_DIR" in /*) ;; *) APPS_DIR="$WORKSPACE/$APPS_DIR" ;; esac
case "$LOG_ROOT" in /*) ;; *) LOG_ROOT="$WORKSPACE/$LOG_ROOT" ;; esac

command -v west >/dev/null 2>&1 || die "找不到 west 命令"
[ -d "$WORKSPACE/.west" ] || die "$WORKSPACE 不是 west 工作区（缺少 .west/）"
[ -d "$APPS_DIR" ] || die "目录不存在: $APPS_DIR"
case "$TIMEOUT_SECS" in ''|*[!0-9]*) die "--timeout 必须是数字" ;; esac

# 发现工程：包含 CMakeLists.txt 且包含 prj.conf 的目录
discover_apps() {
    local f d
    while IFS= read -r -d '' f; do
        d="$(dirname "$f")"
        [ -f "$d/prj.conf" ] && printf '%s\n' "$d"
    done < <(find "$APPS_DIR" -type f -name CMakeLists.txt -print0) | sort
}

# 按 810_driver_test/SPEC_REFERENCE.md §6.1.10 的规则选择板级：
#   工程目录下 cpu* 子目录数 == 1 -> 单核，用 1os
#   否则为双核：cpu1 侧用 2os/cpu1，另一核（cpu0_*/cpu2_*）用 2os/cpu2
board_for_app() {
    local app="$1"
    local group app_name core_count
    group="$(dirname "$app")"
    app_name="$(basename "$app")"

    core_count=$(find "$group" -mindepth 1 -maxdepth 1 -type d -name 'cpu*' | wc -l)

    if [ "$core_count" -le 1 ]; then
        printf '%s\n' "lsqsh_evb@1os/lsqsh/cpu1"
    else
        case "$app_name" in
            cpu1_*) printf '%s\n' "lsqsh_evb@2os/lsqsh/cpu1" ;;
            *)      printf '%s\n' "lsqsh_evb@2os/lsqsh/cpu2" ;;
        esac
    fi
}

mapfile -t APPS < <(discover_apps)
TOTAL=${#APPS[@]}
[ "$TOTAL" -gt 0 ] || die "在 $APPS_DIR 下没有找到可编译工程（需要同时有 CMakeLists.txt 和 prj.conf）"

if [ "$LIST_ONLY" -eq 1 ]; then
    echo "扫描目录: $APPS_DIR"
    echo "共 $TOTAL 个工程:"
    i=0
    for app in "${APPS[@]}"; do
        i=$((i + 1))
        app_board="$BOARD"
        [ -z "$app_board" ] && app_board="$(board_for_app "$app")"
        printf '  %2d. %-58s [%s]\n' "$i" "${app#"$WORKSPACE/"}" "${app_board#*@}"
    done
    exit 0
fi

RUN_DIR="$LOG_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.txt"

echo "============================================================"
echo " 工作区   : $WORKSPACE"
echo " 扫描目录 : $APPS_DIR"
if [ -n "$BOARD" ]; then
    echo " 板级目标 : $BOARD (强制)"
else
    echo " 板级目标 : 自动（单核 @1os / 双核 @2os）"
fi
echo " 构建目录 : $BUILD_DIR"
echo " 工程数量 : $TOTAL"
echo " 日志目录 : $RUN_DIR"
echo " 超时     : $([ "$TIMEOUT_SECS" -gt 0 ] && echo "${TIMEOUT_SECS}s" || echo "无限制")"
echo "============================================================"

PASS=0
FAIL=0
FAILED_APPS=()

for idx in "${!APPS[@]}"; do
    app="${APPS[$idx]}"
    rel="${app#"$WORKSPACE/"}"
    log_name="$(printf '%s' "$rel" | tr '/ ' '__')"
    log="$RUN_DIR/${log_name}.log"

    auto_board="$(board_for_app "$app")"
    app_board="$BOARD"
    [ -z "$app_board" ] && app_board="$auto_board"

    if [ -n "$BOARD" ] && [ "$BOARD" != "$auto_board" ]; then
        echo "  (!) $rel 按单核/双核规则应使用 $auto_board（当前被 -b 强制为 $BOARD，可能失败）"
    fi

    printf '[%2d/%2d] %-58s ' "$((idx + 1))" "$TOTAL" "$rel"
    start=$(date +%s)

    cmd=(west build -p always -b "$app_board" -d "$BUILD_DIR" "$app")
    if [ "$TIMEOUT_SECS" -gt 0 ]; then
        cmd=(timeout --foreground "$TIMEOUT_SECS" "${cmd[@]}")
    fi

    if ( cd "$WORKSPACE" && "${cmd[@]}" ) >"$log" 2>&1; then
        dur=$(( $(date +%s) - start ))
        echo "PASS (${dur}s) [${app_board#*@}]"
        PASS=$((PASS + 1))
        printf 'PASS\t%s\t%ss\t%s\n' "$rel" "$dur" "$app_board" >>"$SUMMARY"
    else
        rc=$?
        dur=$(( $(date +%s) - start ))
        if [ "$rc" -eq 124 ] && [ "$TIMEOUT_SECS" -gt 0 ]; then
            echo "FAIL (超时 ${dur}s) [${app_board#*@}] 日志: $log"
        else
            echo "FAIL (${dur}s) [${app_board#*@}] 日志: $log"
        fi
        FAIL=$((FAIL + 1))
        FAILED_APPS+=("$rel")
        printf 'FAIL\t%s\t%ss\t%s\t%s\n' "$rel" "$dur" "$app_board" "$log" >>"$SUMMARY"

        # 打印几条关键错误，方便直接看到原因
        grep -aE 'error:|Error|FAILED|fatal error|CMake Error' "$log" 2>/dev/null \
            | tail -n 3 | sed 's/^/         /'

        if [ "$STOP_ON_ERROR" -eq 1 ]; then
            echo "按 --stop-on-error 停止。"
            break
        fi
    fi
done

echo "============================================================"
echo " 结果: 共 $TOTAL 个工程，通过 $PASS 个，失败 $FAIL 个"
if [ "${#FAILED_APPS[@]}" -gt 0 ]; then
    echo " 失败列表:"
    for app in "${FAILED_APPS[@]}"; do
        echo "   - $app"
    done
fi
echo " 日志目录: $RUN_DIR"
echo " 汇总文件: $SUMMARY"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
