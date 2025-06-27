#!/bin/bash

# 检查是否在screen会话中运行
if [ -z "$STY" ]; then
    # 如果不在screen会话中，则启动一个新的screen会话来运行此脚本
    echo "正在启动screen会话..."
    # 获取脚本的绝对路径
    SCRIPT_PATH=$(readlink -f "$0")
    # 确保screen会话名称唯一
    SESSION_NAME="antnode_update_$$"
    
    # 使用更可靠的方式启动screen会话
    screen -S "$SESSION_NAME" -dm bash -c "bash \"$SCRIPT_PATH\" _in_screen; exec bash"
    
    # 等待screen会话创建
    sleep 2
    
    # 验证screen会话是否成功创建
    if screen -ls | grep -q "$SESSION_NAME"; then
        echo "screen会话已成功创建，使用以下命令查看运行状态："
        echo "screen -r $SESSION_NAME"
    else
        echo "错误：screen会话创建失败"
        exit 1
    fi
    exit 0
fi

# 添加错误处理
set -e

# 记录日志
exec 1> >(tee -a "/data/up_$(date +%Y%m%d_%H%M%S).log") 2>&1

echo "开始执行更新脚本..."

# 停止所有容器
echo "正在停止所有容器..."
for i in {1..10}; do 
  if [ -d "/data/antnode-docker$i" ]; then
    cd "/data/antnode-docker$i" && docker-compose down || echo "警告: 容器 $i 停止失败"
  else
    echo "目录 /data/antnode-docker$i 不存在，跳过"
  fi
done

# 修改NODE_COUNT配置
echo "正在修改NODE_COUNT配置..."
for i in {1..4}; do 
   sed -i 's/^NODE_COUNT=.*/NODE_COUNT=750/' /data/antnode-docker$i/.env 
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

# 执行run.sh
echo "启动后台任务..."
if [ -f "/data/run.sh" ]; then
    bash /data/run.sh
else
    echo "警告: /data/run.sh 文件不存在，无法启动后台任务"
fi

echo "操作完成"