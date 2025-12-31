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

# 检查并安装/更新 Docker
if command -v docker &> /dev/null; then
    log_info "检查 Docker 版本..."
    CURRENT_DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    
    # 获取最新 Docker 版本（从 Docker 官方 API）
    LATEST_DOCKER_VERSION=$(curl -s https://api.github.com/repos/moby/moby/releases/latest | jq -r .tag_name | sed 's/^v//')
    
    if [ "$CURRENT_DOCKER_VERSION" = "unknown" ]; then
        log_error "无法获取当前 Docker 版本，重新安装..."
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
        log_success "Docker 重新安装完成"
    elif [ "$CURRENT_DOCKER_VERSION" != "$LATEST_DOCKER_VERSION" ]; then
        log_info "当前 Docker 版本: $CURRENT_DOCKER_VERSION"
        log_info "最新 Docker 版本: $LATEST_DOCKER_VERSION"
        log_info "正在更新 Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl restart docker
        log_success "Docker 更新完成！新版本: $(docker version --format '{{.Server.Version}}')"
    else
        log_success "Docker 已是最新版本 ($CURRENT_DOCKER_VERSION)，跳过更新"
    fi
    
    # 确保 Docker 服务正在运行
    if ! systemctl is-active --quiet docker; then
        systemctl start docker
        systemctl enable docker
    fi
else
    log_info "Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    log_success "Docker 安装完成！版本: $(docker version --format '{{.Server.Version}}')"
fi

# 检查并安装/更新 Docker Compose
if command -v docker-compose &> /dev/null; then
    log_info "检查 Docker Compose 版本..."
    CURRENT_COMPOSE_VERSION=$(docker-compose version --short 2>/dev/null || echo "unknown")
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    
    if [ "$CURRENT_COMPOSE_VERSION" = "unknown" ]; then
        log_error "无法获取当前 Docker Compose 版本，重新安装..."
        curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        log_success "Docker Compose 重新安装完成"
    elif [ "$CURRENT_COMPOSE_VERSION" != "${LATEST_COMPOSE_VERSION#v}" ]; then
        log_info "当前 Docker Compose 版本: $CURRENT_COMPOSE_VERSION"
        log_info "最新 Docker Compose 版本: ${LATEST_COMPOSE_VERSION#v}"
        log_info "正在更新 Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        log_success "Docker Compose 更新完成！新版本: $(docker-compose version --short)"
    else
        log_success "Docker Compose 已是最新版本 ($CURRENT_COMPOSE_VERSION)，跳过更新"
    fi
else
    log_info "Docker Compose 未安装，正在安装..."
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose 安装完成！版本: $(docker-compose version --short)"
fi

log_success "Docker和Docker Compose安装完成！"