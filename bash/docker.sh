#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
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

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

# 代理地址
PROXY_URL="https://docker.ka.dog"
USE_PROXY=false

# ========================
# 前置检查
# ========================

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本"
    log_info "使用方法: sudo bash $0"
    exit 1
fi

# 检测是否为中国IP（不依赖jq，使用grep作为备选）
is_china_ip() {
    log_info "检测IP位置..."
    local country=""
    local response=""
    
    # 尝试 ip-api.com
    response=$(curl -s --connect-timeout 5 "http://ip-api.com/json" 2>/dev/null)
    
    # 优先使用 jq，如果不可用则使用 grep
    if command -v jq &> /dev/null; then
        country=$(echo "$response" | jq -r '.countryCode' 2>/dev/null)
    else
        # 备选方案：使用 grep 提取 countryCode
        country=$(echo "$response" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
    fi
    
    # 如果第一个服务失败，尝试 ipinfo.io
    if [ -z "$country" ] || [ "$country" = "null" ]; then
        response=$(curl -s --connect-timeout 5 "https://ipinfo.io/json" 2>/dev/null)
        if command -v jq &> /dev/null; then
            country=$(echo "$response" | jq -r '.country' 2>/dev/null)
        else
            country=$(echo "$response" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        fi
    fi
    
    # 如果仍然无法获取，默认不使用代理
    if [ -z "$country" ] || [ "$country" = "null" ]; then
        log_warn "无法检测IP位置，默认使用直连"
        return 1
    fi
    
    if [ "$country" = "CN" ]; then
        log_info "检测到中国IP，将使用代理: $PROXY_URL"
        return 0
    else
        log_info "非中国IP ($country)，使用直连"
        return 1
    fi
}

# 获取GitHub URL（根据是否使用代理）
get_github_url() {
    local original_url="$1"
    if [ "$USE_PROXY" = true ]; then
        # 将 https://github.com 替换为代理地址
        echo "$original_url" | sed "s|https://github.com|${PROXY_URL}/https://github.com|g" | sed "s|https://api.github.com|${PROXY_URL}/https://api.github.com|g"
    else
        echo "$original_url"
    fi
}

# 安装Docker（根据是否使用代理选择不同方式）
install_docker() {
    if [ "$USE_PROXY" = true ]; then
        # 中国IP使用阿里云镜像安装
        log_info "使用阿里云镜像安装 Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null
        if [ $? -ne 0 ] || [ ! -s /tmp/get-docker.sh ]; then
            # 如果直接下载失败，尝试使用阿里云源手动安装
            log_warn "从 get.docker.com 下载失败，尝试备用方案..."
            
            # 获取系统版本代号（使用 /etc/os-release，更可靠）
            local version_codename=""
            if [ -f /etc/os-release ]; then
                version_codename=$(grep "VERSION_CODENAME" /etc/os-release | cut -d'=' -f2)
            fi
            # 如果没有获取到，尝试其他方式
            if [ -z "$version_codename" ]; then
                version_codename=$(cat /etc/debian_version 2>/dev/null | cut -d'/' -f1 | cut -d'.' -f1)
                # 将数字版本映射到代号
                case "$version_codename" in
                    12) version_codename="bookworm" ;;
                    11) version_codename="bullseye" ;;
                    10) version_codename="buster" ;;
                    *) version_codename="bookworm" ;;  # 默认使用 bookworm
                esac
            fi
            
            log_info "检测到系统版本: $version_codename"
            
            # 安装必要依赖
            apt install -y ca-certificates gnupg
            
            # 添加 Docker GPG 密钥
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            
            # 添加 Docker apt 源
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian ${version_codename} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            apt update -y
            apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            sh /tmp/get-docker.sh --mirror Aliyun
            rm -f /tmp/get-docker.sh
        fi
    else
        curl -fsSL https://get.docker.com | sh
    fi
}

# 配置Docker镜像代理（安全更新 daemon.json）
configure_docker_mirror() {
    if [ "$USE_PROXY" = true ]; then
        log_info "配置Docker Hub镜像代理..."
        mkdir -p /etc/docker
        
        local daemon_file="/etc/docker/daemon.json"
        
        # 如果文件存在且有内容，尝试合并配置
        if [ -f "$daemon_file" ] && [ -s "$daemon_file" ] && command -v jq &> /dev/null; then
            # 检查是否已经配置了相同的镜像
            local existing_mirrors=$(jq -r '.["registry-mirrors"][]?' "$daemon_file" 2>/dev/null)
            if echo "$existing_mirrors" | grep -q "$PROXY_URL"; then
                log_success "Docker镜像代理已配置，跳过"
                return 0
            fi
            
            # 合并配置
            local tmp_file=$(mktemp)
            if jq --arg mirror "$PROXY_URL" '.["registry-mirrors"] = (.["registry-mirrors"] // []) + [$mirror] | .["registry-mirrors"] |= unique' "$daemon_file" > "$tmp_file" 2>/dev/null; then
                mv "$tmp_file" "$daemon_file"
                log_success "Docker镜像代理配置已合并到现有配置"
            else
                rm -f "$tmp_file"
                # 如果合并失败，直接覆盖
                cat > "$daemon_file" << EOF
{
    "registry-mirrors": ["${PROXY_URL}"]
}
EOF
                log_warn "配置合并失败，已覆盖现有配置"
            fi
        else
            # 文件不存在或没有jq，直接创建
            cat > "$daemon_file" << EOF
{
    "registry-mirrors": ["${PROXY_URL}"]
}
EOF
            log_success "Docker镜像代理配置已创建"
        fi
        
        # 如果Docker正在运行，重载配置
        if systemctl is-active --quiet docker 2>/dev/null; then
            systemctl daemon-reload
            systemctl restart docker
            log_success "Docker服务已重启，代理生效"
        else
            log_info "Docker服务未运行，代理将在下次启动时生效"
        fi
    fi
}

# 标准化版本号（去除 v 前缀和后缀如 -ce）
normalize_version() {
    echo "$1" | sed 's/^v//' | sed 's/-ce$//' | sed 's/-.*$//'
}

# 安全获取 GitHub API 数据
get_latest_version() {
    local repo="$1"
    local api_url=$(get_github_url "https://api.github.com/repos/${repo}/releases/latest")
    local version=""
    
    version=$(curl -s --connect-timeout 10 "$api_url" | jq -r .tag_name 2>/dev/null)
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        log_warn "无法从 GitHub API 获取 $repo 最新版本"
        echo ""
        return 1
    fi
    
    echo "$version"
    return 0
}

# 下载文件并验证
download_file() {
    local url="$1"
    local output="$2"
    local description="$3"
    
    log_info "正在下载 $description..."
    
    if curl -L --connect-timeout 30 --retry 3 -o "$output" "$url" 2>/dev/null; then
        # 验证文件是否下载成功且不为空
        if [ -s "$output" ]; then
            log_success "$description 下载完成"
            return 0
        else
            log_error "$description 下载失败：文件为空"
            rm -f "$output"
            return 1
        fi
    else
        log_error "$description 下载失败"
        return 1
    fi
}

# ========================
# 主流程开始
# ========================

# 更新系统
log_info "更新系统..."
apt update -y

# 检查并安装 curl（脚本核心依赖）
if ! command -v curl &> /dev/null; then
    log_info "curl未安装，正在安装..."
    apt install -y curl
else
    log_success "curl已安装"
fi

# 检查并安装 jq
if ! command -v jq &> /dev/null; then
    log_info "jq未安装，正在安装..."
    apt install -y jq
else
    log_success "jq已安装"
fi

# 检测IP并设置代理标志
if is_china_ip; then
    USE_PROXY=true
fi

# ========================
# Docker 安装/更新
# ========================

log_info "检查 Docker..."

if command -v docker &> /dev/null; then
    log_info "Docker 已安装，检查版本..."
    CURRENT_DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    
    # 获取最新 Docker 版本
    LATEST_DOCKER_VERSION=$(get_latest_version "moby/moby")
    
    if [ -z "$LATEST_DOCKER_VERSION" ]; then
        log_warn "无法获取最新 Docker 版本，跳过版本检查"
        # 仍然确保代理配置
        configure_docker_mirror
    elif [ "$CURRENT_DOCKER_VERSION" = "unknown" ]; then
        log_error "无法获取当前 Docker 版本，重新安装..."
        install_docker
        systemctl start docker
        systemctl enable docker
        configure_docker_mirror
        log_success "Docker 重新安装完成"
    else
        # 标准化版本进行比较
        CURRENT_NORMALIZED=$(normalize_version "$CURRENT_DOCKER_VERSION")
        LATEST_NORMALIZED=$(normalize_version "$LATEST_DOCKER_VERSION")
        
        if [ "$CURRENT_NORMALIZED" != "$LATEST_NORMALIZED" ]; then
            log_info "当前 Docker 版本: $CURRENT_DOCKER_VERSION"
            log_info "最新 Docker 版本: $LATEST_DOCKER_VERSION"
            log_info "正在更新 Docker..."
            install_docker
            configure_docker_mirror
            systemctl restart docker
            log_success "Docker 更新完成！新版本: $(docker version --format '{{.Server.Version}}')"
        else
            log_success "Docker 已是最新版本 ($CURRENT_DOCKER_VERSION)"
            # 确保代理配置
            configure_docker_mirror
        fi
    fi
    
    # 确保 Docker 服务正在运行
    if ! systemctl is-active --quiet docker; then
        log_info "启动 Docker 服务..."
        systemctl start docker
        systemctl enable docker
    fi
else
    log_info "Docker 未安装，正在安装..."
    install_docker
    systemctl start docker
    systemctl enable docker
    configure_docker_mirror
    log_success "Docker 安装完成！版本: $(docker version --format '{{.Server.Version}}')"
fi

# ========================
# Docker Compose 安装/更新
# ========================

log_info "检查 Docker Compose..."

# 获取当前安装的 Docker Compose 版本（支持插件和独立版本）
get_compose_version() {
    # 优先检查插件版本 (docker compose)
    if docker compose version &>/dev/null; then
        docker compose version --short 2>/dev/null
        return 0
    fi
    # 然后检查独立版本 (docker-compose)
    if command -v docker-compose &>/dev/null; then
        docker-compose version --short 2>/dev/null
        return 0
    fi
    echo ""
    return 1
}

# 检查 Docker Compose 是否已安装
compose_installed() {
    docker compose version &>/dev/null || command -v docker-compose &>/dev/null
}

# 获取最新版本
LATEST_COMPOSE_VERSION=$(get_latest_version "docker/compose")

if [ -z "$LATEST_COMPOSE_VERSION" ]; then
    log_error "无法获取 Docker Compose 最新版本，跳过安装/更新"
else
    if compose_installed; then
        CURRENT_COMPOSE_VERSION=$(get_compose_version)
        
        if [ -n "$CURRENT_COMPOSE_VERSION" ]; then
            log_info "Docker Compose 已安装，版本: $CURRENT_COMPOSE_VERSION"
            
            # 标准化版本比较
            CURRENT_NORMALIZED=$(normalize_version "$CURRENT_COMPOSE_VERSION")
            LATEST_NORMALIZED=$(normalize_version "$LATEST_COMPOSE_VERSION")
            
            if [ "$CURRENT_NORMALIZED" != "$LATEST_NORMALIZED" ]; then
                log_info "最新 Docker Compose 版本: ${LATEST_COMPOSE_VERSION#v}"
                log_info "正在更新 Docker Compose..."
                COMPOSE_DOWNLOAD_URL=$(get_github_url "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)")
                if download_file "$COMPOSE_DOWNLOAD_URL" "/usr/local/bin/docker-compose" "Docker Compose"; then
                    chmod +x /usr/local/bin/docker-compose
                    log_success "Docker Compose 更新完成！新版本: $(get_compose_version)"
                fi
            else
                log_success "Docker Compose 已是最新版本 ($CURRENT_COMPOSE_VERSION)"
            fi
        else
            log_warn "Docker Compose 已安装但无法获取版本"
        fi
    else
        log_info "Docker Compose 未安装，正在安装..."
        COMPOSE_DOWNLOAD_URL=$(get_github_url "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)")
        if download_file "$COMPOSE_DOWNLOAD_URL" "/usr/local/bin/docker-compose" "Docker Compose"; then
            chmod +x /usr/local/bin/docker-compose
            log_success "Docker Compose 安装完成！版本: $(get_compose_version)"
        fi
    fi
fi

# ========================
# 完成
# ========================

echo ""
log_success "========================================"
log_success "Docker 和 Docker Compose 安装/更新完成！"
log_success "========================================"

# 显示版本信息
echo ""
log_info "已安装版本："
echo "  Docker:         $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '未安装')"
echo "  Docker Compose: $(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || echo '未安装')"

if [ "$USE_PROXY" = true ]; then
    echo ""
    log_info "代理配置："
    echo "  镜像加速: $PROXY_URL"
fi