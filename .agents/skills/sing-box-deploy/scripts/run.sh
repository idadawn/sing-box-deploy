#!/usr/bin/env bash
set -eu

usage() {
  cat <<'EOF'
用法
  bash run.sh <操作> <项目根目录> [环境文件]

操作
  validate            校验配置（需要 jq 和 sing-box）
  install-proxy       安装代理并跳过 Pages
  publish-pages       仅发布订阅
  install-with-pages  运行完整安装流程

环境文件默认为项目根目录的 .env。相对路径按项目根目录解析。
EOF
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  usage
  exit 0
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

operation=$1
checkout=$2
env_file=${3-.env}
case "$operation" in
  validate)           set -- --validate-only ;;
  install-proxy)      set -- --skip-pages ;;
  publish-pages)      set -- --pages-only ;;
  install-with-pages) set -- ;;
  *) usage >&2; exit 2 ;;
esac

if [[ -z "$checkout" ]] || ! CDPATH= cd -- "$checkout" 2>/dev/null ||
    [[ ! -f install.sh || ! -f .env.example || ! -f isp-list.example.tsv ]]; then
  echo '请指定包含安装器和两份公开模板的 sing-box-deploy 项目根目录。' >&2
  exit 2
fi
if [[ ! -f "$env_file" || ! -r "$env_file" ]]; then
  echo '私有环境文件缺失或不可读。请从 .env.example 准备配置，或指定已有文件。' >&2
  exit 2
fi
if [[ "$env_file" != /* ]]; then
  env_file="$PWD/$env_file"
fi

# The installer can print credentials or subscription URLs on either stream.
umask 077
log_file=$(mktemp "${TMPDIR:-/tmp}/sing-box-deploy.XXXXXXXX")
trap 'rm -f -- "$log_file"' EXIT
if bash ./install.sh --env "$env_file" "$@" >"$log_file" 2>&1; then
  printf '%s 操作的安装器已正常退出。\n' "$operation"
else
  result=$?
  trap - EXIT
  printf '安装器退出码 %d。请在执行主机查看私有诊断文件 %s\n' "$result" "$log_file" >&2
  exit "$result"
fi
