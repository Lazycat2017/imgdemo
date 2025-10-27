#!/bin/bash

# Neptune GPU Miner 启动脚本（使用 screen 会话 npt）
# 作用：创建名为 npt 的 screen 会话并在其中运行 dr_neptune_prover
# 用法：./npt.sh [WORKER_ID] [GPU_IDS]
# 例如：./npt.sh qj5091 "0,1,2,3"
# 或者：./npt.sh qj5092 "0,1,2,3,4,5,6,7"

set -euo pipefail

# 固定前缀
WORKER_PREFIX="congtoukaisi."

# 参数处理
if [ $# -eq 0 ]; then
    # 没有参数，使用默认值
    WORKER_ID="qj5090"
    GPU_IDS="0,1,2,3,4,5,6,7"
elif [ $# -eq 1 ]; then
    # 只有一个参数，作为 WORKER_ID
    WORKER_ID="$1"
    GPU_IDS="0,1,2,3,4,5,6,7"
elif [ $# -eq 2 ]; then
    # 两个参数，分别是 WORKER_ID 和 GPU_IDS
    WORKER_ID="$1"
    GPU_IDS="$2"
else
    echo "用法：$0 [WORKER_ID] [GPU_IDS]"
    echo "例如：$0 qj5091 \"0,1,2,3\""
    echo "或者：$0 qj5092 \"0,1,2,3,4,5,6,7\""
    echo "或者直接运行 $0 使用默认配置 (qj5090)"
    exit 1
fi

# 组合完整的 WORKER 名称
WORKER="${WORKER_PREFIX}${WORKER_ID}"

echo "使用配置："
echo "  WORKER: $WORKER"
echo "  GPU_IDS: $GPU_IDS"

SESSION="npt"
BIN="dr_neptune_prover"
URL="https://dl.zao.re/npt/dr_neptune_prover"
POOL="stratum+tcp://neptune.drpool.io:30127"
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