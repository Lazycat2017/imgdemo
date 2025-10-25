#!/bin/bash

# Neptune GPU Miner 启动脚本（使用 screen 会话 npt）
# 作用：创建名为 npt 的 screen 会话并在其中运行 dr_neptune_prover

set -euo pipefail

SESSION="npt"
BIN="dr_neptune_prover"
URL="https://dl.zao.re/npt/dr_neptune_prover"
WORKER="congtoukaisi.qj5090"
POOL="stratum+tcp://neptune.drpool.io:30127"
GPU_IDS="0,1,2,3,4,5,6,7"
MODE="1"

ensure_deps() {
  if ! command -v screen >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
      echo "安装 screen、wget、curl、nvtop..."
      apt update -y || true
      apt install -y screen wget curl nvtop || true
    else
      echo "警告: 未检测到 apt，假设依赖已安装"
    fi
  fi
  if ! command -v wget >/dev/null 2>&1; then
    echo "错误: 需要 wget，请先安装"
    exit 1
  fi
}

ensure_binary() {
  if [ ! -x "./$BIN" ]; then
    echo "下载 $BIN..."
    wget -O "$BIN" "$URL"
    chmod +x "$BIN"
  fi
}

start_in_screen() {
  local cmd="./$BIN -w $WORKER -p $POOL -g $GPU_IDS -m $MODE"
  echo "创建并启动 screen 会话: $SESSION"
  screen -dmS "$SESSION" bash -c "cd '$(pwd)' && $cmd; exec bash"
  sleep 2
  if screen -list | grep -q "$SESSION"; then
    echo "screen 会话 '$SESSION' 已启动。附加查看：screen -r $SESSION"
  else
    echo "错误: 创建 screen 会话失败"
    exit 1
  fi
}

main() {
  ensure_deps
  ensure_binary
  # 始终在新的 screen 会话中运行矿工
  start_in_screen
}

main "$@"