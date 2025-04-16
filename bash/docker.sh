#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

# 更新系统
log_info "更新系统..."
apt update -y

# 检查是否安装jq
if ! command -v jq &> /dev/null; then
    log_info "jq未安装，正在安装..."
    apt install -y jq
else
    log_success "jq已安装，跳过安装"
fi

# 检查是否安装Docker
if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
    log_success "Docker已安装并运行中，跳过安装"
else
    log_info "Docker未安装或未运行，正在安装..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
fi

# 安装 Docker Compose
if command -v docker-compose &> /dev/null; then
    log_success "Docker Compose 已安装，跳过安装"
else
    log_info "安装 Docker Compose..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    curl -L "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose 安装完成"
fi

log_success "Docker和Docker Compose安装完成！"