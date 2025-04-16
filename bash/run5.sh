#!/bin/bash

# 创建一个新的 screen 会话并在其中执行脚本
screen -dmS run bash -c '
    # 进入 /data 目录
    cd /data || { echo "目录 /data 不存在，退出"; exit 1; }
    
    # 创建 run.sh 并写入启动脚本
    cat > run.sh << "EOF"
#!/bin/bash

# 检查系统负载函数
check_load() {
    # 获取当前系统负载的第一个值（1分钟平均负载）
    local current_load=$(cat /proc/loadavg | awk "{print \$1}")
    
    # 使用简单的字符串比较
    if (( $(echo "$current_load < 300" | bc -l) )); then
        return 0  # 负载小于300，返回成功
    else
        return 1  # 负载大于等于300，返回失败
    fi
}

for i in {1..8}; do 
    echo "正在启动 /data/antnode-docker$i 的 docker-compose 任务..."
    cd /data/antnode-docker$i || { echo "目录 /data/antnode-docker$i 不存在，跳过"; continue; }
    
    # 启动 docker-compose
    docker-compose up -d
    
    echo "已启动 /data/antnode-docker$i，等待系统负载降低..."
    
    # 循环检查系统负载，直到负载小于300
    while ! check_load; do
        current_load=$(cat /proc/loadavg | awk "{print \$1}")
        echo "当前系统负载较高: $current_load，等待30秒..."
        sleep 30
    done
    
    current_load=$(cat /proc/loadavg | awk "{print \$1}")
    echo "系统负载已降低: $current_load，等待10分钟后继续部署下一个容器"
    sleep 600  # 600秒 = 10分钟
    
    echo "继续部署下一个容器"
done

echo "所有任务已启动"
EOF
    
    # 赋予执行权限
    chmod +x run.sh
    
    # 执行 run.sh
    ./run.sh
'