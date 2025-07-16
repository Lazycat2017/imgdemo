#!/bin/bash

# 停止nexus服务
echo "开始停止nexus服务..."

# 检查并重启 /data/nexus 到 /data/nexus5
for i in "" 1 2 3 4 5; do
    if [ "$i" = "" ]; then
        nexus_dir="/data/nexus"
    else
        nexus_dir="/data/nexus$i"
    fi
    
    if [ -d "$nexus_dir" ]; then
        echo "进入目录: $nexus_dir"
        cd "$nexus_dir"
        
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo "在 $nexus_dir 中执行 docker-compose down"
            docker-compose down
            
            if [ $? -eq 0 ]; then
                echo "$nexus_dir down 成功"
            else
                echo "$nexus_dir down 失败"
            fi
        else
            echo "在 $nexus_dir 中未找到 docker-compose.yml 文件"
        fi
    else
        echo "目录 $nexus_dir 不存在，跳过"
    fi
done

echo "所有操作完成"