#!/usr/bin/env bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; }

# 检查是否以 root 运行
if [ "$(id -u)" != "0" ]; then
    log_err "请使用 sudo 或 root 权限运行此脚本"
    exit 1
fi

# 检查虚拟化环境 (简单检查)
if [ -f /.dockerenv ] || grep -q 'docker\|lxc' /proc/1/cgroup; then
    log_err "检测到容器环境 (Docker/LXC)，无法加载内核模块。请在虚拟机或物理机上运行。"
    exit 1
fi

log_info "更新软件源并安装编译依赖..."
# 移除 full-upgrade，避免意外升级内核导致的问题
apt update
apt install -y build-essential git linux-headers-$(uname -r) kmod

# 处理源码目录
WORKDIR="/tmp/lotspeed_install"
if [ -d "$WORKDIR" ]; then
    log_warn "检测到旧的源码目录，正在清理..."
    rm -rf "$WORKDIR"
fi
mkdir -p "$WORKDIR"
cd "$WORKDIR"

log_info "克隆 LotSpeed 仓库 (zeta-tcp 分支)..."
if ! git clone -b zeta-tcp https://ghp.ka.dog/github.com/uk0/lotspeed.git .; then
    log_err "克隆仓库失败，请检查网络连接。"
    exit 1
fi

log_info "开始编译内核模块..."
if ! make; then
    log_err "编译失败！可能是内核头文件不匹配或源码不兼容当前内核版本。"
    exit 1
fi

# 检查 lotspeed.ko 是否生成
if [ ! -f "lotspeed.ko" ]; then
    log_err "编译未报错但未找到 lotspeed.ko 文件。"
    exit 1
fi

KERNEL_MOD_PATH="/lib/modules/$(uname -r)/kernel/net/ipv4"
log_info "安装模块到 $KERNEL_MOD_PATH ..."
mkdir -p "$KERNEL_MOD_PATH"
cp lotspeed.ko "$KERNEL_MOD_PATH/"
depmod -a

log_info "尝试加载模块..."
if ! modprobe lotspeed; then
    log_err "模块加载失败！"
    log_warn "可能有以下原因："
    log_warn "1. 系统开启了 Secure Boot (安全启动)，请在 BIOS/UEFI 中关闭它。"
    log_warn "2. 内核版本不兼容。"
    exit 1
fi

# 再次验证
if lsmod | grep -q lotspeed; then
    log_info "lotspeed 模块加载成功！"
else
    log_err "模块加载验证失败。"
    exit 1
fi

log_info "配置开机自启..."
echo "lotspeed" > /etc/modules-load.d/lotspeed.conf

log_info "应用 Sysctl 参数..."
cat > /etc/sysctl.d/10-lotspeed.conf << EOF
net.ipv4.tcp_congestion_control = lotspeed
net.ipv4.tcp_no_metrics_save = 1
EOF
sysctl --system

# 最终检查
CURRENT_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "$CURRENT_ALGO" == "lotspeed" ]; then
    log_info "安装完成！当前 TCP 拥塞控制算法: ${GREEN}$CURRENT_ALGO${NC}"
    # 清理源码
    cd /
    rm -rf "$WORKDIR"
else
    log_warn "安装似乎完成了，但当前算法仍为: $CURRENT_ALGO，请检查 sysctl 配置。"
fi