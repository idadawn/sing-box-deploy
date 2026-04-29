#!/usr/bin/env bash
# Claude Code 启动脚本
# 默认使用 bypassPermissions 模式，跳过所有权限确认提示
exec "$(command -v claude)" -c --permission-mode bypassPermissions "$@"
