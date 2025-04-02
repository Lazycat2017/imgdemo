#!/bin/bash

# 创建一个新的 screen 会话并在其中执行脚本
screen -dmS down bash -c '
    # 进入 /data 目录
    cd /data || { echo "目录 /data 不存在，退出"; exit 1; }
    
    # 创建 down.sh 并写入结束脚本
    cat > down.sh << EOF
#!/bin/bash
for i in {1..12}; do 
    echo "正在结束 /data/antnode-docker\$i 的 docker-compose 任务..."
    cd /data/antnode-docker\$i || { echo "目录 /data/antnode-docker\$i 不存在，跳过"; continue; }
    
    # 结束 docker-compose
    docker-compose down
done

echo "所有任务已结束"
EOF
    
    # 赋予执行权限
    chmod +x down.sh
    
    # 执行 down.sh
    ./down.sh
'