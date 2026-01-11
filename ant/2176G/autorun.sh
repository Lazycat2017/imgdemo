#!/bin/bash

# 创建一个新的 screen 会话并在其中执行脚本
screen -dmS autorun bash -c '
    # 进入 /data 目录
    cd /data || { echo "目录 /data 不存在，退出"; exit 1; }
    
    # 创建 autorun.sh 并写入启动脚本
    cat > autorun.sh << "EOF"
#!/bin/bash

# 添加时间戳日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查依赖
check_dependencies() {
    local missing_deps=0
    
    if ! command -v bc &> /dev/null; then
        log "✗ 缺少依赖: bc 命令未安装"
        ((missing_deps++))
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        log "✗ 缺少依赖: docker-compose 命令未安装"
        ((missing_deps++))
    fi
    
    if [ $missing_deps -gt 0 ]; then
        log "请先安装缺少的依赖"
        exit 1
    fi
}

# 获取系统负载函数
get_load() {
    cat /proc/loadavg | awk '{print $1}'
}

# 检查系统负载函数
check_load() {
    local current_load=$(get_load)
    if (( $(echo "$current_load < 300" | bc -l) )); then
        return 0  # 负载小于300，返回成功
    else
        return 1  # 负载大于等于300，返回失败
    fi
}

# 检查依赖
check_dependencies

# 统计变量
stopped_count=0
stop_failed_count=0
started_count=0
failed_count=0
total_to_start=4

log "=========================================="
log "第一步：检查并停止现有容器"
log "=========================================="

# 使用临时文件记录停止结果
temp_file="/tmp/docker_stop_result_$$.txt"
: > "$temp_file"

# 检查是否有运行中的容器并停止
for i in {1..20}; do 
    local_dir="/data/antnode-docker$i"
    if [ -d "$local_dir" ]; then
        # 使用子shell避免cd副作用
        (
            cd "$local_dir" || exit 1
            # 检查是否有运行中的容器
            if docker-compose ps -q 2>/dev/null | grep -q .; then
                log "检测到 $local_dir 有运行中的容器，正在停止..."
                if docker-compose down > /dev/null 2>&1; then
                    echo "success" >> "$temp_file"
                    log "✓ 成功停止 $local_dir"
                else
                    echo "failed" >> "$temp_file"
                    log "✗ 停止 $local_dir 失败"
                fi
            fi
        )
    fi
done

# 统计停止结果
stopped_count=$(grep -c "success" "$temp_file" 2>/dev/null || echo 0)
stop_failed_count=$(grep -c "failed" "$temp_file" 2>/dev/null || echo 0)
rm -f "$temp_file"

log "容器停止完成，成功: $stopped_count 个，失败: $stop_failed_count 个"
log "等待5秒后开始启动..."
sleep 5
echo ""

log "=========================================="
log "第二步：启动容器 (共 $total_to_start 个)"
log "=========================================="

for i in {1..4}; do 
    local_dir="/data/antnode-docker$i"
    log "[$i/$total_to_start] 正在启动 $local_dir ..."
    
    # 检查目录是否存在
    if [ ! -d "$local_dir" ]; then
        log "✗ 目录 $local_dir 不存在，跳过"
        ((failed_count++))
        continue
    fi
    
    # 检查docker-compose.yml是否存在
    if [ ! -f "$local_dir/docker-compose.yml" ] && [ ! -f "$local_dir/docker-compose.yaml" ]; then
        log "✗ $local_dir 中未找到 docker-compose 配置文件，跳过"
        ((failed_count++))
        continue
    fi
    
    # 使用子shell执行启动操作
    (
        cd "$local_dir" || exit 1
        
        # 启动 docker-compose（隐藏输出）
        if ! docker-compose up -d > /dev/null 2>&1; then
            log "✗ 启动 $local_dir 失败"
            exit 1
        fi
        
        # 验证容器是否成功启动
        sleep 2
        if ! docker-compose ps -q 2>/dev/null | grep -q .; then
            log "✗ $local_dir 容器启动后未运行"
            exit 1
        fi
        
        log "✓ 成功启动 $local_dir"
    )
    
    # 检查子shell的退出状态
    if [ $? -ne 0 ]; then
        ((failed_count++))
        continue
    fi
    
    ((started_count++))
    
    # 最后一个容器不需要等待
    if [ $i -eq $total_to_start ]; then
        log "最后一个容器已启动，无需等待"
        break
    fi
    
    log "等待系统负载降低..."
    
    # 循环检查系统负载，直到负载小于300（增加超时机制）
    wait_count=0
    max_wait_cycles=120  # 最多等待60分钟（120次 * 30秒）
    
    while ! check_load; do
        current_load=$(get_load)
        log "当前系统负载较高: $current_load，等待30秒..."
        sleep 30
        
        ((wait_count++))
        if [ $wait_count -ge $max_wait_cycles ]; then
            log "⚠ 等待超时（60分钟），系统负载仍然较高: $current_load"
            log "⚠ 继续部署下一个容器（可能会增加系统压力）"
            break
        fi
    done
    
    current_load=$(get_load)
    log "系统负载已降低: $current_load，等待10分钟后继续部署下一个容器"
    sleep 600  # 600秒 = 10分钟
done

echo ""
log "=========================================="
log "执行完成统计"
log "=========================================="
log "停止容器数: $stopped_count (失败: $stop_failed_count)"
log "成功启动数: $started_count"
log "启动失败数: $failed_count"
log "总计应启动: $total_to_start"

if [ $failed_count -eq 0 ]; then
    log "✓ 所有任务执行成功！"
    exit 0
else
    log "⚠ 部分任务执行失败，请检查日志"
    exit 1
fi
EOF

    # 赋予执行权限
    chmod +x autorun.sh
    
    # 执行 autorun.sh
    ./autorun.sh
'