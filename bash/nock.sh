#!/bin/bash

# 进入/data目录
cd /data || { echo "无法进入/data目录"; exit 1; }

# 拉取nockchain仓库，添加重试逻辑
max_attempts=3
attempt=1
while [ $attempt -le $max_attempts ]; do
    echo "尝试拉取仓库 (第 $attempt 次)..."
    if git clone https://git.max.xch.im/maxmind/nockchain; then
        echo "仓库克隆成功"
        break
    else
        echo "第 $attempt 次拉取失败"
        if [ $attempt -eq $max_attempts ]; then
            echo "达到最大尝试次数，仓库克隆失败"
            exit 1
        fi
        # 随机等待3-6秒
        sleep_time=$(( RANDOM % 4 + 3 ))
        echo "等待 $sleep_time 秒后重试..."
        sleep $sleep_time
        attempt=$((attempt + 1))
    fi
done

# 进入nockchain目录
cd nockchain || { echo "无法进入nockchain目录"; exit 1; }

# 复制.env.sample为.env
cp .env.example .env || { echo "复制.env_example失败"; exit 1; }

# 替换MINING_PUBKEY的值
sed -i 's/^MINING_PUBKEY=.*/MINING_PUBKEY=39GUmwZeKy3GRGJ9qmdigyBuEfyHroXFgCoTRSwUbJvqX7u9n3A42nK864VNhmcXaUaGfYCwKxLsRW1V1qEHPeCcFoWLPEMYdxiBUQVgZGyXRSmTcwuW1tB7qauVrmftRRdL/' .env || { echo "替换MINING_PUBKEY失败"; exit 1; }

# 更新容器
docker-compose pull
# 启动容器
#docker-compose up -d || { echo "启动docker-compose失败"; exit 1; }

echo "nockchain已成功部署"