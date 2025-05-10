#!/bin/bash

# 设置错误处理
set -eo pipefail  # 如果发生错误或管道失败，脚本将立即退出
trap 'echo "错误发生在第 $LINENO 行，退出状态: $?" >&2' ERR

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 定义配置参数
REWARD_ADDRESS="0x73b548474b878d8451dbb4d0fe7b4f2c3b890bdc"
NODE_COUNT=200
INSTANCE_COUNT=29

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
update_system() {
    log_info "更新系统..."
    apt update -y
}

# 安装必要的软件包
install_packages() {
    log_info "安装必要的软件包..."
    apt install -y btop vnstat duf vim screen build-essential jq git libssl-dev unzip curl sudo wget ca-certificates bc neofetch 
}

# 配置 BBR
configure_bbr() {
    log_info "检查 BBR 是否已配置..."
    
    # 检查当前 TCP 拥塞控制算法
    CURRENT_TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    
    if [ "$CURRENT_TCP_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "fq" ]; then
        log_success "BBR 已配置，跳过配置"
    else
        log_info "配置 BBR..."
        cat <<EOF | tee /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl -p
    fi
}


# 安装 Docker
install_docker() {
    log_info "检查 Docker 是否已安装..."
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        log_success "Docker 已安装并运行中，跳过安装"
    else
        log_info "安装 Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
    fi
}

# 安装 Docker Compose
install_docker_compose() {
    log_info "检查 Docker Compose 是否已安装..."
    if command -v docker-compose &> /dev/null; then
        log_success "Docker Compose 已安装，跳过安装"
    else
        log_info "安装 Docker Compose..."
        LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
        curl -L "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
}

# 设置 antnode
setup_antnode() {
    log_info "设置 antnode..."
    
    # 检查 /data 目录是否存在
    if [ -d "/data" ]; then
        log_info "/data 目录已存在，跳过创建"
    else
        log_info "创建 /data 目录..."
        mkdir -p /data
    fi
    
    cd /data
    
    log_info "克隆仓库..."
    git clone https://git.max.xch.im/maxmind/antnode-docker
    cd antnode-docker
    
    log_info "修改 .env 文件..."
    sed -i "s|REWARD_ADDRESS=.*|REWARD_ADDRESS=${REWARD_ADDRESS}|g" .env
    sed -i "s|NODE_COUNT=.*|NODE_COUNT=${NODE_COUNT}|g" .env
    
    log_info "创建 ${INSTANCE_COUNT} 个实例..."
    for i in $(seq 1 $INSTANCE_COUNT); do
        cp -r /data/antnode-docker /data/antnode-docker$i
        sed -i "s/name: antnode/name: antnode$i/g" /data/antnode-docker$i/docker-compose.yml
    done
    
    rm -rf /data/antnode-docker
}

# 安装 nezha agent
install_nezha_agent() {
    log_info "检查 nezha agent 是否已安装..."
    if systemctl is-active --quiet nezha-agent.service; then
        log_success "nezha agent 已安装并运行中，跳过安装"
    else
        log_info "安装 nezha agent..."
        cd /tmp
        curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
        chmod +x agent.sh
        env NZ_SERVER=tz.ka.dog:8008 NZ_TLS=false NZ_CLIENT_SECRET=2rmHr9RMlXNQEVvXgT9axnDihvdZMlBe ./agent.sh
    fi
}

# 拉取 Docker 镜像
pull_docker_images() {
    log_info "清理现有 Docker 镜像..."
    docker image prune -a -f
    
    log_info "拉取 Docker 镜像..."
    docker pull ghcr.io/lushdog/antnode:4.1.2
    docker tag ghcr.io/lushdog/antnode:4.1.2 ghcr.io/lushdog/antnode:latest
#    cd /data/antnode-docker1
#    docker-compose pull
}

# 清理函数
cleanup() {
    log_info "清理临时文件..."
    rm -f /tmp/agent.sh
}

# 主函数
main() {
    log_info "开始执行脚本..."

    update_system
    install_packages
    configure_bbr
    install_packages
    install_docker
    install_docker_compose
    setup_antnode
    install_nezha_agent
    pull_docker_images
    cleanup
    
    log_success "所有操作完成！"
}

# 执行主函数
main
