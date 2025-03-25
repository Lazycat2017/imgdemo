#!/bin/bash

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要root权限运行，请使用sudo或以root身份运行"
    exit 1
fi

echo "正在优化系统网络参数..."

# 创建备份目录
BACKUP_DIR="/root/network_config_backup_$(date +%Y%m%d%H%M%S)"
mkdir -p $BACKUP_DIR
echo "将在 $BACKUP_DIR 目录下创建配置文件备份"

# 备份原始配置文件
if [ -f /etc/sysctl.conf ]; then
    cp /etc/sysctl.conf $BACKUP_DIR/sysctl.conf.bak
    echo "已备份 /etc/sysctl.conf 到 $BACKUP_DIR/sysctl.conf.bak"
fi

if [ -f /etc/security/limits.conf ]; then
    cp /etc/security/limits.conf $BACKUP_DIR/limits.conf.bak
    echo "已备份 /etc/security/limits.conf 到 $BACKUP_DIR/limits.conf.bak"
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
echo "应用系统参数..."
sysctl -p

# 设置当前会话的限制
echo "设置当前会话的文件描述符和进程数限制..."
ulimit -n 1048576
ulimit -u 1048576

echo "系统网络参数优化完成！"
echo "当前文件描述符限制: $(ulimit -n)"
echo "当前进程数限制: $(ulimit -u)"

# 提示备份位置和恢复方法
echo "配置文件备份已保存在: $BACKUP_DIR"
echo "如需恢复，请执行以下命令:"
echo "cp $BACKUP_DIR/sysctl.conf.bak /etc/sysctl.conf"
echo "cp $BACKUP_DIR/limits.conf.bak /etc/security/limits.conf"
echo "sysctl -p"

# 提示需要重启
echo "建议重启系统以确保所有参数生效"