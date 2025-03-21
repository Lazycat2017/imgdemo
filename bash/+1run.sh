#!/bin/bash
# 检查当前运行的 antnode 容器
HIGHEST_NODE=$(docker ps --format '{{.Names}}' | grep 'antnode[0-9][0-9]*-node-1' | sed 's/antnode\([0-9][0-9]*\)-node-1/\1/g' | sort -n | tail -n 1)

if [ -z "$HIGHEST_NODE" ]; then
    echo "未找到任何 antnode 容器，退出脚本"
    exit 1
fi

echo "当前最高节点编号: antnode${HIGHEST_NODE}-node-1"

# 计算下一个节点编号
NEXT_NODE=$((HIGHEST_NODE + 1))
TARGET_DIR="/data/antnode-docker${NEXT_NODE}"

echo "尝试启动 antnode-docker${NEXT_NODE}"

# 检查目标目录是否存在
if [ ! -d "$TARGET_DIR" ]; then
    echo "目录 $TARGET_DIR 不存在，终止脚本"
    exit 1
fi

# 直接进入目标目录并启动 docker-compose
cd $TARGET_DIR || { echo "目录 $TARGET_DIR 不存在，退出"; exit 1; }
docker-compose up -d
echo "antnode-docker${NEXT_NODE} 已启动"