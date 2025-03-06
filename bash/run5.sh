#!/bin/bash

# 创建一个新的 screen 会话并在其中执行脚本
screen -dmS run bash -c '
    # 进入 /data 目录
    cd /data || { echo "目录 /data 不存在，退出"; exit 1; }
    
    # 创建 run.sh 并写入启动脚本
    cat > run.sh << EOF
#!/bin/bash
for i in {1..6}; do 
    echo "正在启动 /data/antnode-docker\$i 的 docker-compose 任务..."
    cd /data/antnode-docker\$i || { echo "目录 /data/antnode-docker\$i 不存在，跳过"; continue; }
    
    # 启动 docker-compose
    docker-compose up -d
    
    echo "已启动 /data/antnode-docker\$i，等待 10 分钟..."
    sleep 600  # 600秒 = 10分钟

done

echo "所有任务已启动"
EOF
    
    # 赋予执行权限
    chmod +x run.sh
    
    # 执行 run.sh
    ./run.sh
'