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
REWARD_ADDRESS="0x938dE25d7035F094A00d26EA10C7E8B7B139a0dA"
NODE_COUNT=700
INSTANCE_COUNT=4

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

# 优化系统网络参数
optimize_network() {
    log_info "正在优化系统网络参数..."

    # 创建备份目录
    BACKUP_DIR="/root/network_config_backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p $BACKUP_DIR
    log_info "将在 $BACKUP_DIR 目录下创建配置文件备份"

    # 备份原始配置文件
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf $BACKUP_DIR/sysctl.conf.bak
        log_info "已备份 /etc/sysctl.conf 到 $BACKUP_DIR/sysctl.conf.bak"
    fi

    if [ -f /etc/security/limits.conf ]; then
        cp /etc/security/limits.conf $BACKUP_DIR/limits.conf.bak
        log_info "已备份 /etc/security/limits.conf 到 $BACKUP_DIR/limits.conf.bak"
    fi

    # 配置sysctl参数
    cat > /etc/sysctl.conf << EOF
fs.file-max=4194304

net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=8388608
net.core.wmem_default=8388608
net.core.netdev_max_backlog=100000
net.core.somaxconn=32768

net.ipv4.udp_mem=8388608 16777216 33554432
net.ipv4.neigh.default.gc_stale_time=120
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2

net.ipv4.tcp_syncookies=1
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=30
net.ipv4.tcp_keepalive_intvl=5
net.ipv4.tcp_keepalive_probes=2
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_syn_backlog=10240
net.ipv4.tcp_max_tw_buckets=60000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fack=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_rmem=4096 524288 67108864
net.ipv4.tcp_wmem=4096 524288 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_early_retrans=1
net.ipv4.ip_forward=1

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 配置系统文件描述符限制
    cat > /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
EOF

    # 应用sysctl配置
    log_info "应用系统参数..."
    sysctl -p

    # 设置当前会话的限制
    log_info "设置当前会话的文件描述符和进程数限制..."
    ulimit -n 1048576
    ulimit -u 1048576

    log_success "系统网络参数优化完成！"
    log_info "当前文件描述符限制: $(ulimit -n)"
    log_info "当前进程数限制: $(ulimit -u)"

    # 提示备份位置和恢复方法
    log_info "配置文件备份已保存在: $BACKUP_DIR"
    log_info "如需恢复，请执行以下命令:"
    log_info "cp $BACKUP_DIR/sysctl.conf.bak /etc/sysctl.conf"
    log_info "cp $BACKUP_DIR/limits.conf.bak /etc/security/limits.conf"
    log_info "sysctl -p"
}

# 安装 Docker
install_docker() {
    log_info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
}

# 安装 Docker Compose
install_docker_compose() {
    log_info "安装 Docker Compose..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    curl -L "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

# 设置 antnode
setup_antnode() {
    log_info "设置 antnode..."
    mkdir -p /data
    cd /data
    
    log_info "克隆仓库..."
    git clone https://github.com/Lazycat2017/antnode-docker
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
     log_info "安装 nezha agent..."
     cd /tmp
     curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
     chmod +x agent.sh
     env NZ_SERVER=wk.ka.dog:443 NZ_TLS=true NZ_CLIENT_SECRET=faH3fQ1G198ehhJXBn7bBR1uSh7vrTgc ./agent.sh
 }

# 拉取 Docker 镜像2
pull_docker_images() {
    log_info "拉取 Docker 镜像..."
    cd /data/antnode-docker1
    docker build . --tag ghcr.io/lushdog/antnode:latest --build-arg VERSION=2025.9.2.1
}

# 设置定时清理日志的任务
setup_cron_job() {
    log_info "设置定时清理日志的任务..."
    
    # 定义定时任务内容
    CRON_JOB='0 3 * * * find /data/antnode-docker*/autonom_data/ -type f -name "antnode.log.*T*" -delete'

    # 备份现有 crontab（以防修改出错）
    if ! crontab -l > /tmp/current_cron.bak 2>/dev/null; then
        log_info "当前没有crontab任务，将创建新的任务"
    fi

    # 检查是否已存在该任务，避免重复添加
    if crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
        log_info "Crontab 任务已存在，无需重复添加。"
    else
        # 将新任务追加到当前的 crontab 任务列表
        if ! (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -; then
            log_error "Crontab 任务添加失败"
            return 1
        fi
        log_success "Crontab 任务已成功添加！"
    fi

    # 显示当前 crontab 任务列表
    log_info "当前 crontab 任务如下："
    crontab -l
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
    optimize_network
    install_docker
    install_docker_compose
    setup_antnode
    install_nezha_agent
    pull_docker_images
    setup_cron_job
    cleanup
    
    log_success "所有操作完成！"
    log_info "建议重启系统以确保所有参数生效"
}

# 执行主函数
main