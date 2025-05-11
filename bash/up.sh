#!/bin/bash

# 添加错误处理
set -e

# 停止所有容器
echo "正在停止所有容器..."
for i in {1..10}; do 
  if [ -d "/data/antnode-docker$i" ]; then
    cd "/data/antnode-docker$i" && docker-compose down || echo "警告: 容器 $i 停止失败"
  else
    echo "目录 /data/antnode-docker$i 不存在，跳过"
  fi
done

# 拉取指定版本镜像
echo "正在拉取 antnode 镜像..."
max_attempts=3
attempt=1
while [ $attempt -le $max_attempts ]; do
    if docker pull ghcr.io/lushdog/antnode:latest; then
        echo "镜像拉取成功"
        break
    else
        echo "第 $attempt 次拉取失败"
        if [ $attempt -eq $max_attempts ]; then
            echo "错误: 镜像拉取失败，已达到最大重试次数"
            exit 1
        fi
        echo "等待 5 秒后重试..."
        sleep 5
        attempt=$((attempt + 1))
    fi
done

# 使用screen命令建立后台窗口执行run.sh
echo "启动后台任务..."
if [ -f "/data/run.sh" ]; then
  if ! screen -dmS runantnode bash -c '/data/run.sh'; then
    echo "错误: 后台任务启动失败"
    exit 1
  fi
else
  echo "警告: /data/run.sh 文件不存在，无法启动后台任务"
fi

echo "操作完成"