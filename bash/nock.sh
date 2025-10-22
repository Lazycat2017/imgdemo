#!/bin/bash

# =============================================================================
# Nockchain GPU Miner 自动化部署脚本
# 功能：自动安装依赖、下载最新版本挖矿程序并在 screen 会话中运行
# =============================================================================

# 配置参数（可通过环境变量覆盖）
PROXY_SERVER="${PROXY_SERVER:-154.17.228.137:8899}"
MINER_LABEL="${MINER_LABEL:-jq54090}"
MINER_NAME="${MINER_NAME:-dog}"
SCREEN_SESSION="${SCREEN_SESSION:-nock}"
LOG_FILE="${LOG_FILE:-/tmp/nock_miner.log}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# 日志记录函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 错误处理函数
error_exit() {
    log "错误: $1"
    exit 1
}

# 重试执行函数
retry_command() {
    local cmd="$1"
    local description="$2"
    local retries=0
    
    while [ $retries -lt $MAX_RETRIES ]; do
        log "尝试 $description (第 $((retries + 1)) 次)"
        if eval "$cmd"; then
            log "$description 成功"
            return 0
        else
            retries=$((retries + 1))
            if [ $retries -lt $MAX_RETRIES ]; then
                log "$description 失败，等待 $RETRY_DELAY 秒后重试..."
                sleep $RETRY_DELAY
            fi
        fi
    done
    
    error_exit "$description 在 $MAX_RETRIES 次尝试后仍然失败"
}

# 检查是否在 screen 会话中
check_screen_session() {
    if [ -z "$STY" ]; then
        log "脚本未在 screen 会话中运行，正在创建 screen 会话..."
        
        # 检查 screen 是否已安装
        if ! command -v screen &> /dev/null; then
            log "正在安装 screen 和 nvtop..."
            retry_command "apt update && apt install screen nvtop -y" "安装依赖包"
        fi
        
        # 创建 screen 会话并重新执行脚本
        log "创建 screen 会话: $SCREEN_SESSION"
        screen -dmS "$SCREEN_SESSION" bash -c "cd $(pwd) && bash $0 _in_screen; exec bash"
        
        # 等待会话创建
        sleep 2
        
        # 验证会话是否创建成功
        if screen -list | grep -q "$SCREEN_SESSION"; then
            log "Screen 会话创建成功！"
            log "使用以下命令查看运行状态："
            log "  screen -r $SCREEN_SESSION"
            log "使用 Ctrl+A+D 从会话中分离"
            exit 0
        else
            error_exit "Screen 会话创建失败"
        fi
    fi
}

# 获取最新版本号
get_latest_version() {
    log "正在获取最新版本信息..."
    
    # 尝试从 GitHub API 获取最新版本
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/GoldenMinerNetwork/golden-miner-nockchain-gpu-miner/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -n "$latest_version" ] && [ "$latest_version" != "null" ]; then
        log "获取到最新版本: $latest_version"
        echo "$latest_version"
    else
        log "警告: 无法获取最新版本，使用默认版本 v0.1.5+1"
        echo "v0.1.5+1"
    fi
}

# 下载挖矿程序
download_miner() {
    local version="$1"
    local filename="golden-miner-pool-prover"
    local url="https://github.com/GoldenMinerNetwork/golden-miner-nockchain-gpu-miner/releases/download/${version}/${filename}"
    
    log "正在下载挖矿程序..."
    log "版本: $version"
    log "URL: $url"
    
    # 如果文件已存在，备份
    if [ -f "$filename" ]; then
        log "发现已存在的文件，创建备份..."
        mv "$filename" "${filename}.backup.$(date +%s)"
    fi
    
    # 下载文件
    retry_command "wget -O $filename '$url'" "下载挖矿程序"
    
    # 验证文件是否下载成功
    if [ ! -f "$filename" ] || [ ! -s "$filename" ]; then
        error_exit "下载的文件不存在或为空"
    fi
    
    # 设置执行权限
    chmod +x "$filename"
    log "文件下载完成并设置执行权限"
    
    # 显示文件信息
    log "文件信息: $(ls -lh $filename)"
}

# 启动挖矿程序
start_miner() {
    local filename="golden-miner-pool-prover"
    
    if [ ! -f "$filename" ]; then
        error_exit "挖矿程序文件不存在: $filename"
    fi
    
    if [ ! -x "$filename" ]; then
        error_exit "挖矿程序文件没有执行权限: $filename"
    fi
    
    log "正在启动挖矿程序..."
    log "代理服务器: $PROXY_SERVER"
    log "标签: $MINER_LABEL"
    log "名称: $MINER_NAME"
    
    # 启动挖矿程序
    log "执行命令: ./$filename --proxy=$PROXY_SERVER --label=$MINER_LABEL --name=$MINER_NAME"
    exec ./"$filename" --proxy="$PROXY_SERVER" --label="$MINER_LABEL" --name="$MINER_NAME"
}

# 主函数
main() {
    log "=== Nockchain GPU Miner 部署脚本开始执行 ==="
    log "日志文件: $LOG_FILE"
    
    # 如果不是在 screen 中运行，则创建 screen 会话
    if [ "$1" != "_in_screen" ]; then
        check_screen_session
        return
    fi
    
    log "在 screen 会话中执行主要逻辑..."
    
    # 检查是否有 root 权限（用于安装软件包）
    if [ "$EUID" -ne 0 ]; then
        log "警告: 脚本未以 root 权限运行，可能无法安装依赖包"
    fi
    
    # 安装依赖包
    log "正在安装依赖包..."
    retry_command "apt update && apt install screen nvtop curl wget -y" "安装依赖包"
    
    # 获取最新版本
    local version
    version=$(get_latest_version)
    
    # 下载挖矿程序
    download_miner "$version"
    
    # 启动挖矿程序
    start_miner
}

# 执行主函数
main "$@"