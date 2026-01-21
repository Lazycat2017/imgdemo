#!/bin/bash

# =================================================================
# Docker & Docker Compose 自动化安装/更新脚本
# 支持：Debian / Ubuntu
# 功能：自动检测中国IP并配置镜像加速、安全合并 daemon.json
# =================================================================

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# -----------------------------------------------------------------
# 配置区域
# -----------------------------------------------------------------
PROXY_URL="https://docker.ka.dog"   # Docker 镜像代理
USE_PROXY=false                     # 初始值，稍后自动检测
DOCKER_COMPOSE_DIR="/usr/libexec/docker/cli-plugins"

# -----------------------------------------------------------------
# 基础函数
# -----------------------------------------------------------------

log_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

# 检查系统兼容性
check_system() {
    if [ ! -f /etc/debian_version ]; then
        log_error "本脚本目前仅支持 Debian/Ubuntu 系统。"
        log_error "检测到非 Debian 系系统，停止运行。"
        exit 1
    fi
}

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        log_info "使用方法: sudo bash $0"
        exit 1
    fi
}

# 检测是否为中国IP
is_china_ip() {
    log_info "正在检测网络环境..."
    local country=""
    
    # 优先尝试 ip-api.com
    local response
    response=$(curl -s --connect-timeout 5 "http://ip-api.com/json" 2>/dev/null)
    
    # 因为主流程已安装 jq，直接使用 jq
    if [ -n "$response" ]; then
        country=$(echo "$response" | jq -r '.countryCode' 2>/dev/null)
    fi
    
    # 备选 ipinfo.io
    if [ -z "$country" ] || [ "$country" = "null" ]; then
        response=$(curl -s --connect-timeout 5 "https://ipinfo.io/json" 2>/dev/null)
        if [ -n "$response" ]; then
            country=$(echo "$response" | jq -r '.country' 2>/dev/null)
        fi
    fi
    
    if [ "$country" = "CN" ]; then
        log_info "检测到中国大陆 IP，将启用代理加速: $PROXY_URL"
        return 0
    else
        # 如果检测失败或非CN，默认直连
        local loc_display=${country:-"未知"}
        log_info "非中国大陆 IP (位置: $loc_display)，使用直连模式"
        return 1
    fi
}

# 获取 GitHub URL
get_github_url() {
    local original_url="$1"
    if [ "$USE_PROXY" = true ]; then
        echo "$original_url" | sed "s|https://github.com|${PROXY_URL}/https://github.com|g" | sed "s|https://api.github.com|${PROXY_URL}/https://api.github.com|g"
    else
        echo "$original_url"
    fi
}

# 标准化版本号 (v20.10.1 -> 20.10.1)
normalize_version() {
    echo "$1" | sed -E 's/^docker-//; s/^v//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+'
}

# 获取 GitHub 最新版本
get_latest_version() {
    local repo="$1"
    local api_url
    api_url=$(get_github_url "https://api.github.com/repos/${repo}/releases/latest")
    
    local version
    version=$(curl -s --connect-timeout 10 "$api_url" | jq -r .tag_name 2>/dev/null)
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        # 很多时候是因为 GitHub API 限制，不一定是因为网络不通
        log_warn "无法获取 $repo 最新版本 (可能是 API 速率限制)，跳过版本检查。"
        echo ""
        return 1
    fi
    
    echo "$version"
}

# 下载文件
download_file() {
    local url="$1"
    local output="$2"
    local name="$3"
    
    log_info "正在下载 $name..."
    if curl -L --connect-timeout 60 --retry 3 -o "$output" "$url" 2>/dev/null; then
        if [ -s "$output" ]; then
            log_success "$name 下载完成"
            return 0
        else
            log_error "$name 下载失败：文件为空"
            rm -f "$output"
            return 1
        fi
    else
        log_error "$name 下载请求失败"
        return 1
    fi
}

# -----------------------------------------------------------------
# 核心功能：Docker 安装
# -----------------------------------------------------------------
install_docker() {
    if [ "$USE_PROXY" = true ]; then
        log_info "使用阿里云镜像源安装 Docker..."
        
        # 尝试官方脚本带 Mirror 参数
        if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
             sh /tmp/get-docker.sh --mirror Aliyun
             rm -f /tmp/get-docker.sh
        else
            log_warn "官方脚本下载失败，切换为手动 APT 安装..."
            
            # 手动安装流程
            apt-get update -y
            apt-get install -y ca-certificates gnupg
            
            install -m 0755 -d /etc/apt/keyrings
            # 即使 key 下载失败也不要立即报错退出，尝试继续
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            
            # 自动获取 Debian/Ubuntu 代号
            local codename=""
            if [ -f /etc/os-release ]; then
                codename=$(grep "VERSION_CODENAME" /etc/os-release | cut -d'=' -f2)
            fi
            if [ -z "$codename" ]; then codename="bookworm"; fi # 保底
            
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian ${codename} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            apt-get update -y
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
        fi
    else
        log_info "使用官方源安装 Docker..."
        curl -fsSL https://get.docker.com | sh
    fi
}

# -----------------------------------------------------------------
# 核心功能：镜像加速配置
# -----------------------------------------------------------------
configure_docker_mirror() {
    # 仅当使用了代理，或者强制需要配置时运行
    if [ "$USE_PROXY" = true ]; then
        log_info "检查 Docker 镜像加速配置..."
        mkdir -p /etc/docker
        local daemon_file="/etc/docker/daemon.json"
        local need_reload=false
        
        # 构造临时的 json 内容
        local tmp_json
        
        if [ -f "$daemon_file" ] && [ -s "$daemon_file" ]; then
            # 检查是否已存在该代理
            if grep -q "$PROXY_URL" "$daemon_file"; then
                log_success "镜像代理已存在，无需修改"
                return 0
            fi
            
            log_info "合并镜像配置到 daemon.json..."
            # 使用 jq 安全插入并去重
            local tmp_file=$(mktemp)
            jq --arg mirror "$PROXY_URL" \
               '.["registry-mirrors"] = (.["registry-mirrors"] // []) + [$mirror] | .["registry-mirrors"] |= unique' \
               "$daemon_file" > "$tmp_file"
            
            if [ -s "$tmp_file" ]; then
                mv "$tmp_file" "$daemon_file"
                need_reload=true
            else
                rm -f "$tmp_file"
                log_error "JSON合并失败，跳过配置"
            fi
        else
            log_info "创建新的 daemon.json..."
            cat > "$daemon_file" << EOF
{
    "registry-mirrors": ["${PROXY_URL}"]
}
EOF
            need_reload=true
        fi
        
        if [ "$need_reload" = true ]; then
            if systemctl is-active --quiet docker; then
                systemctl daemon-reload
                systemctl restart docker
                log_success "Docker 服务已重启，加速配置生效"
            fi
        fi
    fi
}

# -----------------------------------------------------------------
# 主逻辑
# -----------------------------------------------------------------

# 1. 预检
check_root
check_system

# 2. 安装基础依赖
log_info "正在更新系统软件源..."
apt-get update -y >/dev/null 2>&1  # 静默更新，出错再显示
if [ $? -ne 0 ]; then
    log_warn "apt-get update 返回了错误，尝试继续运行..."
fi

log_info "安装必要工具 (curl, jq)..."
apt-get install -y curl jq >/dev/null 2>&1

# 3. 检测网络环境
if is_china_ip; then
    USE_PROXY=true
fi

# 4. Docker 处理
log_info "----------------------------------------"
log_info "开始检查 Docker 环境"
log_info "----------------------------------------"

if command -v docker &> /dev/null; then
    CURRENT_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    LATEST_VER=$(get_latest_version "moby/moby")
    
    if [ -n "$LATEST_VER" ]; then
        NORM_CURRENT=$(normalize_version "$CURRENT_VER")
        NORM_LATEST=$(normalize_version "$LATEST_VER")
        
        if [ "$NORM_CURRENT" != "$NORM_LATEST" ]; then
            log_info "发现新版本 (当前: $NORM_CURRENT, 最新: $NORM_LATEST)，准备更新..."
            install_docker
            # 更新后重置镜像配置以防万一
            configure_docker_mirror
            log_success "Docker 更新完毕"
        else
            log_success "Docker 已是最新版 ($CURRENT_VER)"
            configure_docker_mirror # 即使不更新，也要检查配置是否丢失
        fi
    else
        log_warn "跳过 Docker 版本比对"
        configure_docker_mirror
    fi
else
    log_info "Docker 未安装，开始安装..."
    install_docker
    systemctl start docker
    systemctl enable docker
    configure_docker_mirror
    log_success "Docker 安装完毕"
fi

# 5. Docker Compose 处理
log_info "----------------------------------------"
log_info "开始检查 Docker Compose 环境"
log_info "----------------------------------------"

# 优先检查插件版本
COMPOSE_VER=""
if docker compose version &>/dev/null; then
    COMPOSE_VER=$(docker compose version | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

LATEST_COMPOSE=$(get_latest_version "docker/compose")

if [ -n "$LATEST_COMPOSE" ]; then
    NEED_INSTALL=false
    if [ -z "$COMPOSE_VER" ]; then
        log_info "Docker Compose 未安装"
        NEED_INSTALL=true
    else
        NORM_CUR_COMP=$(normalize_version "$COMPOSE_VER")
        NORM_LAT_COMP=$(normalize_version "$LATEST_COMPOSE")
        log_info "Compose 当前: $NORM_CUR_COMP, 最新: $NORM_LAT_COMP"
        if [ "$NORM_CUR_COMP" != "$NORM_LAT_COMP" ]; then
            NEED_INSTALL=true
        else
            log_success "Docker Compose 已是最新"
        fi
    fi
    
    if [ "$NEED_INSTALL" = true ]; then
        log_info "正在安装/更新 Docker Compose ($LATEST_COMPOSE)..."
        # 构造下载链接
        DL_URL=$(get_github_url "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE}/docker-compose-$(uname -s)-$(uname -m)")
        
        mkdir -p "$DOCKER_COMPOSE_DIR"
        if download_file "$DL_URL" "${DOCKER_COMPOSE_DIR}/docker-compose" "Docker Compose Plugin"; then
            chmod +x "${DOCKER_COMPOSE_DIR}/docker-compose"
            # 兼容旧命令
            ln -sf "${DOCKER_COMPOSE_DIR}/docker-compose" /usr/local/bin/docker-compose
            log_success "Docker Compose 安装成功"
        fi
    fi
else
    if [ -z "$COMPOSE_VER" ]; then
        log_error "无法获取最新版且本地未安装，Docker Compose 安装失败"
    else
        log_warn "无法获取最新版，保留当前版本: $COMPOSE_VER"
    fi
fi

# -----------------------------------------------------------------
# 结束
# -----------------------------------------------------------------
echo ""
log_success "========================================"
log_success "所有任务执行完毕！"
log_info "Docker版本:  $(docker --version 2>/dev/null)"
log_info "Compose版本: $(docker compose version --short 2>/dev/null)"
log_success "========================================"