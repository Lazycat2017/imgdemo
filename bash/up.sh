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
for i in {1..4}; do 
  if [ -d "/data/antnode-docker$i" ]; then
    cd "/data/antnode-docker$i" && docker-compose down || echo "警告: 容器 $i 停止失败"
  else
    echo "目录 /data/antnode-docker$i 不存在，跳过"
  fi
done

# 修改NODE_COUNT配置
echo "正在修改NODE_COUNT配置..."
for i in {1..4}; do 
   sed -i 's/^NODE_COUNT=.*/NODE_COUNT=700/' /data/antnode-docker$i/.env 
done

# 本地编译镜像2
echo "正在编译 antnode 镜像..."
cd /data/antnode-docker1/
if docker build . --tag ghcr.io/lushdog/antnode:latest --build-arg VERSION=2025.9.2.1; then
    echo "镜像编译成功"
else
    echo "错误: 镜像编译失败"
    exit 1
fi

# 执行run.sh
echo "启动后台任务..."
if [ -f "/data/run.sh" ]; then
    # 检查文件权限
    if [ ! -x "/data/run.sh" ]; then
        chmod +x /data/run.sh
    fi
    # 执行前检查文件内容
    if grep -q '[[:print:]]' "/data/run.sh"; then
        bash /data/run.sh
    else
        echo "错误: run.sh 文件存在但为空或包含不可打印字符"
        exit 1
    fi
else
    echo "警告: /data/run.sh 文件不存在，正在下载..."
    cd /data/ || { echo "错误: 无法切换到 /data 目录"; exit 1; }
    
    # 下载前备份目标位置的文件(如果存在)
    if [ -f "run.sh" ]; then
        mv run.sh "run.sh.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 使用临时文件进行下载
    TMP_FILE=$(mktemp)
    if wget -O "$TMP_FILE" https://raw.githubusercontent.com/Lazycat2017/imgdemo/refs/heads/master/ant/2176G/run.sh; then
        # 检查下载的文件是否为空
        if [ -s "$TMP_FILE" ]; then
            mv "$TMP_FILE" run.sh
            chmod +x run.sh
            ./run.sh
        else
            echo "错误: 下载的文件为空"
            rm -f "$TMP_FILE"
            exit 1
        fi
    else
        echo "错误: 下载失败"
        rm -f "$TMP_FILE"
        exit 1
    fi
fi

echo "操作完成"