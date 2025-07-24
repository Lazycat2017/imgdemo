#!/bin/bash

# 设置错误处理
set -e

echo "开始停止所有 Docker Compose 服务..."

# 遍历 /data/antnode-docker1 到 /data/antnode-docker10
for i in {1..10}; do
    dir_path="/data/antnode-docker$i"
    
    if [ -d "$dir_path" ]; then
        echo "进入目录: $dir_path"
        cd "$dir_path"
        
        # 检查是否存在 docker-compose.yml 文件
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo "正在停止 antnode-docker$i 的服务..."
            if docker-compose down; then
                echo "成功停止 antnode-docker$i 的服务"
            else
                echo "警告: 停止 antnode-docker$i 的服务时出现错误，继续执行..."
            fi
        else
            echo "警告: 在 $dir_path 中未找到 docker-compose.yml 文件"
        fi
    else
        echo "目录 $dir_path 不存在，跳过"
    fi
done

echo "所有 Docker Compose 服务停止完成"

# 自动删除 /data 目录下的所有文件
echo "正在删除 /data 目录下的所有文件..."

# 检查 /data 目录是否存在
if [ -d "/data" ]; then
    # 删除 /data 目录下的所有文件和子目录
    rm -rf /data/*
    echo "成功删除 /data 目录下的所有文件"
else
    echo "警告: /data 目录不存在"
fi

echo "脚本执行完成"