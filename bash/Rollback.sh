#!/bin/bash

# 添加错误处理
set -e

# 拉取指定版本镜像
echo "正在拉取 antnode:4.1.1 镜像..."
docker pull ghcr.io/lushdog/antnode:4.1.1
docker tag ghcr.io/lushdog/antnode:4.1.1 ghcr.io/lushdog/antnode:latest

# 停止所有容器
echo "正在停止所有容器..."
for i in {1..19}; do 
  if [ -d "/data/antnode-docker$i" ]; then
    cd /data/antnode-docker$i && docker-compose down
  else
    echo "目录 /data/antnode-docker$i 不存在，跳过"
  fi
done

# 使用screen命令建立后台窗口执行run.sh
echo "启动后台任务..."
if [ -f "/data/run.sh" ]; then
  screen -dmS runantnode bash -c '/data/run.sh'
else
  echo "警告: /data/run.sh 文件不存在，无法启动后台任务"
fi

echo "回滚操作完成"