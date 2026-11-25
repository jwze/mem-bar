#!/bin/bash
# 构建用的运行上限工具。
#
# macOS 14/15 不自带 coreutils 的 `timeout`，所以这里是一个纯 bash 的兜底实现：
# 到点就把**整棵进程树**（swift build 会拉起 swift-build / swift-frontend 等子进程）杀掉，
# 并把 124 返回给调用方。
#
# 用法：
#   source Scripts/timeout.sh
#   run_with_timeout 60 swift build -c release --product MemBar

# 递归打印一个进程的全部后代 pid。
descendants() {
    local parent=$1 child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}

# run_with_timeout <秒> <命令...>
# 正常情况下返回命令自身的退出码；超过上限返回 124（与 GNU timeout 一致）。
run_with_timeout() {
    local limit=$1
    shift 1

    # 命令结束后才写这个文件。不能用 `kill -0` 轮询：已退出但未被 wait 的僵尸进程同样存活，
    # 循环会永远退不出来。
    local marker
    marker="$(mktemp "${TMPDIR:-/tmp}/membar-step.XXXXXX")"
    rm -f "$marker"

    ( rc=0; "$@" || rc=$?; printf '%s' "$rc" > "$marker" ) &
    local pid=$!

    local waited=0
    while [ ! -s "$marker" ]; do
        if [ "$waited" -ge "$limit" ]; then
            # 先把整棵树快照下来：父进程一旦退出，子进程会被 launchd 收养，`pgrep -P` 就找不到
            # 它们了，届时只能靠这份名单补刀。
            local tree
            tree="$(descendants "$pid")"
            # shellcheck disable=SC2086
            kill -TERM $tree "$pid" 2>/dev/null || true
            sleep 1
            tree="$(descendants "$pid") $tree"
            # shellcheck disable=SC2086
            kill -KILL $tree "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            rm -f "$marker"
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done

    local status
    status="$(cat "$marker")"
    rm -f "$marker"
    wait "$pid" 2>/dev/null || true
    return "${status:-1}"
}