#!/bin/bash
#############################################################
# 多功能隧道转发脚本
# 功能：
#   1. 创建/管理 IPv4 GRE 隧道
#   2. 创建/管理 IPv6 GRE (ip6gre) 隧道
#   3. iptables 端口转发 (DNAT/SNAT)
#   4. GRE 隧道端口转发 (nftables, 自动识别隧道类型)
#############################################################

red="\033[31m"
green="\033[32m"
yellow="\033[33m"
cyan="\033[36m"
bold="\033[1m"
reset="\033[0m"

BASE_DIR=/etc/tunnel-forward
FORWARD_CONF=$BASE_DIR/forward.conf        # iptables 转发规则
GRE_CONF=$BASE_DIR/gre-forward.conf        # GRE 隧道转发规则
TUNNEL_CONF=$BASE_DIR/tunnels.conf          # 已创建的隧道信息

[[ "$EUID" -ne 0 ]] && { echo -e "${red}错误: 请以 root 权限运行此脚本！${reset}"; exit 1; }

mkdir -p $BASE_DIR
touch $FORWARD_CONF $GRE_CONF $TUNNEL_CONF

# 自动修复: 清理配置文件中残留的 @NONE 后缀 (旧版 bug)
for _f in "$GRE_CONF" "$TUNNEL_CONF"; do
    if grep -q '@NONE' "$_f" 2>/dev/null; then
        sed -i 's/@NONE//g' "$_f"
    fi
done

# ======================== 依赖检查 ========================

check_and_install() {
    local cmd=$1
    local pkg_debian=$2
    local pkg_rhel=$3
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    echo -e "${yellow}>> 未检测到 $cmd，正在安装...${reset}"
    # 判断包管理器
    if command -v apt-get &>/dev/null; then
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y -qq "$pkg_debian" > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q "$pkg_rhel" > /dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg_rhel" > /dev/null 2>&1
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$pkg_debian" > /dev/null 2>&1
    else
        echo -e "${red}错误: 无法识别包管理器，请手动安装 $cmd${reset}"
        return 1
    fi
    if command -v "$cmd" &>/dev/null; then
        echo -e "${green}   $cmd 安装成功${reset}"
    else
        echo -e "${red}   $cmd 安装失败，请手动安装${reset}"
        return 1
    fi
}

# iptables
check_and_install iptables iptables iptables
# nftables
check_and_install nft nftables nftables
# iproute2 (ip 命令)
check_and_install ip iproute2 iproute

# ======================== 工具函数 ========================

get_local_ipv4() {
    ip -o -4 addr list | grep -Ev '\s(docker|lo|br-|veth|tun)' | awk '{print $4}' | cut -d/ -f1 | \
    grep -Ev '(^127\.)|(^10\.)|(^172\.(1[6-9]|2[0-9]|3[01])\.)|(^192\.168\.)' | head -n1
    # 如果没有公网 IP，取第一个非 lo 的
    if [ -z "$(ip -o -4 addr list | grep -Ev '\s(docker|lo|br-|veth|tun)' | awk '{print $4}' | cut -d/ -f1 | \
    grep -Ev '(^127\.)|(^10\.)|(^172\.(1[6-9]|2[0-9]|3[01])\.)|(^192\.168\.)')" ]; then
        ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | head -n1
    fi
}

get_local_ipv6() {
    ip -o -6 addr list scope global | grep -Ev '\s(docker|lo|br-|veth|tun)' | awk '{print $4}' | cut -d/ -f1 | head -n1
}

is_valid_port() {
    echo "$1" | grep -qE '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_port_range() {
    echo "$1" | grep -qE '^[0-9]+-[0-9]+$'
}

is_valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

is_valid_ipv6() {
    echo "$1" | grep -qE '^[0-9a-fA-F:]+$'
}

enable_ip_forward() {
    echo -e "${cyan}>> 开启 IP 转发...${reset}"
    # IPv4
    if ! sysctl -n net.ipv4.ip_forward 2>/dev/null | grep -q 1; then
        sysctl -w net.ipv4.ip_forward=1 > /dev/null
    fi
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    # IPv6
    if ! sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null | grep -q 1; then
        sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    fi
    if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null 2>&1
    echo -e "${green}   IP 转发已开启${reset}"
}

# 开放 FORWARD 链
open_forward_chain() {
    # 删除 REJECT/DROP 规则
    local lines
    lines=$(iptables -L FORWARD -n --line-number 2>/dev/null | grep -iE "REJECT|DROP" | grep "0.0.0.0/0" | sort -rn | awk '{print $1}')
    for line in $lines; do
        iptables -D FORWARD "$line" 2>/dev/null
    done
    iptables --policy FORWARD ACCEPT 2>/dev/null
}

# 检测已有 GRE 隧道并返回列表
# 过滤掉系统默认接口 gre0, ip6gre0 和 @NONE 后缀
list_gre_tunnels() {
    {
        ip -d link show type gre 2>/dev/null
        ip -d link show type ip6gre 2>/dev/null
    } | grep -E "^[0-9]+:" \
      | awk -F'[: @]+' '{print $2}' \
      | grep -Ev '^(gre0|ip6gre0|ip6tnl0|sit0|erspan0|gretap0)$' \
      | grep -v '^$' \
      | sort -u
}

# 获取隧道类型: gre 或 ip6gre
get_tunnel_type() {
    local tun_name=$1
    local info
    info=$(ip -d link show "$tun_name" 2>/dev/null)
    if echo "$info" | grep -q "ip6gre"; then
        echo "ip6gre"
    elif echo "$info" | grep -q "gre"; then
        echo "gre"
    else
        echo "unknown"
    fi
}

# 获取隧道内网 IP
get_tunnel_ip() {
    local tun_name=$1
    ip -4 addr show dev "$tun_name" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
}

# 获取隧道对端内网 IP (隧道内网网段的另一端)
get_tunnel_peer_ip() {
    local tun_name=$1
    local local_ip
    local_ip=$(get_tunnel_ip "$tun_name")
    if [ -z "$local_ip" ]; then
        echo ""
        return
    fi
    # 从路由表中查找隧道对端
    local subnet
    subnet=$(ip route show dev "$tun_name" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | head -n1)
    echo "$subnet"
}

show_banner() {
    clear
    echo -e "${bold}${cyan}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║          多功能隧道转发管理脚本 v1.0                     ║"
    echo "║                                                         ║"
    echo "║  功能: GRE隧道创建 / 端口转发 / GRE隧道转发             ║"
    echo "║  支持: IPv4 GRE / IPv6 GRE (ip6gre) / iptables / nft   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo -e "  本机 IPv4: ${green}$(get_local_ipv4)${reset}"
    echo -e "  本机 IPv6: ${green}$(get_local_ipv6)${reset}"

    local tunnels
    tunnels=$(list_gre_tunnels)
    if [ -n "$tunnels" ]; then
        echo -e "  已有隧道: ${yellow}${tunnels//$'\n'/ , }${reset}"
    fi
    echo ""
}

# ======================== 模块1: GRE 隧道管理 ========================

create_ipv4_gre() {
    echo ""
    echo -e "${bold}=== 创建 IPv4 GRE 隧道 ===${reset}"
    echo ""

    local tun_name local_ipv4 remote_ipv4 local_inner remote_inner mtu_val

    echo -n "隧道接口名称 [默认: tun-gre]: "; read tun_name
    tun_name=${tun_name:-tun-gre}

    # 检查是否已存在
    if ip link show "$tun_name" &>/dev/null; then
        echo -e "${red}错误: 接口 $tun_name 已存在！请先删除或使用其他名称${reset}"
        return 1
    fi

    local default_ipv4
    default_ipv4=$(get_local_ipv4)
    echo -n "本机公网 IPv4 [默认: $default_ipv4]: "; read local_ipv4
    local_ipv4=${local_ipv4:-$default_ipv4}

    echo -n "对端公网 IPv4: "; read remote_ipv4
    if ! is_valid_ipv4 "$remote_ipv4"; then
        echo -e "${red}错误: 无效的 IPv4 地址${reset}"
        return 1
    fi

    echo -n "本端隧道内网 IP [默认: 10.10.1.1/24]: "; read local_inner
    local_inner=${local_inner:-10.10.1.1/24}

    echo -n "MTU [默认: 1450]: "; read mtu_val
    mtu_val=${mtu_val:-1450}

    echo ""
    echo -e "${cyan}>> 加载 ip_gre 内核模块...${reset}"
    modprobe ip_gre
    if ! grep -q "^ip_gre$" /etc/modules 2>/dev/null; then
        echo "ip_gre" >> /etc/modules
    fi

    echo -e "${cyan}>> 创建 GRE 隧道...${reset}"
    ip tunnel add "$tun_name" mode gre remote "$remote_ipv4" local "$local_ipv4" ttl 255
    if [ $? -ne 0 ]; then
        echo -e "${red}错误: 隧道创建失败${reset}"
        return 1
    fi

    ip addr add "$local_inner" dev "$tun_name"
    ip link set "$tun_name" mtu "$mtu_val" up

    # 记录隧道信息
    sed -i "/^$tun_name|/d" $TUNNEL_CONF
    echo "$tun_name|gre|$local_ipv4|$remote_ipv4|$local_inner|$mtu_val" >> $TUNNEL_CONF

    echo ""
    echo -e "${green}✓ IPv4 GRE 隧道创建成功！${reset}"
    echo -e "  接口: ${bold}$tun_name${reset}"
    echo -e "  模式: gre (IPv4)"
    echo -e "  本端: $local_ipv4 → 对端: $remote_ipv4"
    echo -e "  内网: $local_inner"
    echo -e "  MTU:  $mtu_val"
    echo ""

    ask_persist_tunnel "$tun_name" "gre" "$local_ipv4" "$remote_ipv4" "$local_inner" "$mtu_val"
}

create_ipv6_gre() {
    echo ""
    echo -e "${bold}=== 创建 IPv6 GRE (ip6gre) 隧道 ===${reset}"
    echo ""

    local tun_name local_ipv6 remote_ipv6 local_inner mtu_val

    echo -n "隧道接口名称 [默认: tun-gre]: "; read tun_name
    tun_name=${tun_name:-tun-gre}

    if ip link show "$tun_name" &>/dev/null; then
        echo -e "${red}错误: 接口 $tun_name 已存在！请先删除或使用其他名称${reset}"
        return 1
    fi

    local default_ipv6
    default_ipv6=$(get_local_ipv6)
    echo -n "本机公网 IPv6 [默认: $default_ipv6]: "; read local_ipv6
    local_ipv6=${local_ipv6:-$default_ipv6}

    echo -n "对端公网 IPv6: "; read remote_ipv6
    if ! is_valid_ipv6 "$remote_ipv6"; then
        echo -e "${red}错误: 无效的 IPv6 地址${reset}"
        return 1
    fi

    echo -n "本端隧道内网 IP [默认: 10.10.1.1/24]: "; read local_inner
    local_inner=${local_inner:-10.10.1.1/24}

    echo -n "MTU [默认: 1400]: "; read mtu_val
    mtu_val=${mtu_val:-1400}

    echo ""
    echo -e "${cyan}>> 加载 ip6_gre 内核模块...${reset}"
    modprobe ip6_gre
    if ! grep -q "^ip6_gre$" /etc/modules 2>/dev/null; then
        echo "ip6_gre" >> /etc/modules
    fi

    echo -e "${cyan}>> 创建 ip6gre 隧道...${reset}"
    ip link add "$tun_name" type ip6gre \
        local "$local_ipv6" \
        remote "$remote_ipv6" \
        ttl 255 encaplimit none
    if [ $? -ne 0 ]; then
        echo -e "${red}错误: 隧道创建失败${reset}"
        return 1
    fi

    ip addr add "$local_inner" dev "$tun_name"
    ip link set "$tun_name" mtu "$mtu_val" up

    # 记录隧道信息
    sed -i "/^$tun_name|/d" $TUNNEL_CONF
    echo "$tun_name|ip6gre|$local_ipv6|$remote_ipv6|$local_inner|$mtu_val" >> $TUNNEL_CONF

    echo ""
    echo -e "${green}✓ IPv6 GRE (ip6gre) 隧道创建成功！${reset}"
    echo -e "  接口: ${bold}$tun_name${reset}"
    echo -e "  模式: ip6gre (GRE over IPv6)"
    echo -e "  本端: $local_ipv6 → 对端: $remote_ipv6"
    echo -e "  内网: $local_inner"
    echo -e "  MTU:  $mtu_val"
    echo ""

    ask_persist_tunnel "$tun_name" "ip6gre" "$local_ipv6" "$remote_ipv6" "$local_inner" "$mtu_val"
}

ask_persist_tunnel() {
    local tun_name=$1 tun_type=$2 local_addr=$3 remote_addr=$4 inner_ip=$5 mtu_val=$6

    echo -e "${yellow}是否持久化隧道（重启不丢失）？${reset}"
    echo "  1) 使用 systemd-networkd 持久化"
    echo "  2) 使用 ifupdown 持久化"
    echo "  3) 不持久化（仅当前会话有效）"
    echo -n "请选择 [默认: 3]: "; read persist_choice
    persist_choice=${persist_choice:-3}

    local inner_ip_only inner_mask
    inner_ip_only=$(echo "$inner_ip" | cut -d/ -f1)
    inner_mask=$(echo "$inner_ip" | cut -d/ -f2)
    [ "$inner_mask" = "$inner_ip_only" ] && inner_mask=24

    case $persist_choice in
    1)
        # systemd-networkd
        local netdev_file="/etc/systemd/network/10-${tun_name}.netdev"
        local network_file="/etc/systemd/network/10-${tun_name}.network"

        if [ "$tun_type" = "gre" ]; then
            cat > "$netdev_file" <<EOF
[NetDev]
Name=$tun_name
Kind=gre

[Tunnel]
Local=$local_addr
Remote=$remote_addr
TTL=255
EOF
        else
            cat > "$netdev_file" <<EOF
[NetDev]
Name=$tun_name
Kind=ip6gre

[Tunnel]
Local=$local_addr
Remote=$remote_addr
TTL=255
EncapsulationLimit=none
EOF
        fi

        cat > "$network_file" <<EOF
[Match]
Name=$tun_name

[Link]
MTUBytes=$mtu_val

[Address]
Address=${inner_ip_only}/${inner_mask}
EOF
        systemctl restart systemd-networkd
        echo -e "${green}✓ 已通过 systemd-networkd 持久化${reset}"
        ;;
    2)
        # ifupdown
        local iface_file="/etc/network/interfaces.d/$tun_name"
        if [ "$tun_type" = "gre" ]; then
            cat > "$iface_file" <<EOF
auto $tun_name
iface $tun_name inet static
    address $inner_ip_only
    netmask 255.255.255.0
    pre-up ip tunnel add $tun_name mode gre remote $remote_addr local $local_addr ttl 255
    post-up ip link set dev $tun_name mtu $mtu_val
    post-down ip tunnel del $tun_name
EOF
        else
            cat > "$iface_file" <<EOF
auto $tun_name
iface $tun_name inet static
    address $inner_ip_only
    netmask 255.255.255.0
    pre-up ip link add $tun_name type ip6gre local $local_addr remote $remote_addr ttl 255 encaplimit none
    post-up ip link set dev $tun_name mtu $mtu_val
    post-down ip link del $tun_name
EOF
        fi
        echo -e "${green}✓ 已通过 ifupdown 持久化 ($iface_file)${reset}"
        ;;
    *)
        echo -e "${yellow}  隧道未持久化，重启后将丢失${reset}"
        ;;
    esac
}

delete_tunnel() {
    echo ""
    echo -e "${bold}=== 删除 GRE 隧道 ===${reset}"
    echo ""

    local tunnels
    tunnels=$(list_gre_tunnels)
    if [ -z "$tunnels" ]; then
        echo -e "${yellow}当前没有 GRE 隧道${reset}"
        return
    fi

    echo "当前隧道列表:"
    local i=1
    local tun_arr=()
    while IFS= read -r tun; do
        local ttype
        ttype=$(get_tunnel_type "$tun")
        local tip
        tip=$(get_tunnel_ip "$tun")
        echo -e "  ${bold}$i)${reset} $tun  [类型: $ttype, 内网IP: ${tip:-无}]"
        tun_arr+=("$tun")
        ((i++))
    done <<< "$tunnels"

    echo ""
    echo -n "请选择要删除的隧道编号: "; read choice
    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tun_arr[@]}" ]; then
        echo -e "${red}无效选择${reset}"
        return 1
    fi

    local del_tun="${tun_arr[$((choice-1))]}"
    local del_type
    del_type=$(get_tunnel_type "$del_tun")

    echo -e "${yellow}确认删除隧道 $del_tun ？ [y/N]${reset}"; read confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消"
        return
    fi

    ip link set "$del_tun" down 2>/dev/null

    # 统一用 ip link del 删除（对 gre 和 ip6gre 都有效）
    # ip tunnel del 只能删 IPv4 tunnel，且某些情况下名称不匹配会失败
    ip link del "$del_tun" 2>/dev/null
    # 如果 ip link del 失败，再尝试 ip tunnel del（兼容旧内核）
    if ip link show "$del_tun" &>/dev/null; then
        ip tunnel del "$del_tun" 2>/dev/null
    fi

    # 验证是否删除成功
    if ip link show "$del_tun" &>/dev/null; then
        echo -e "${red}✗ 隧道 $del_tun 删除失败，请手动检查: ip link del $del_tun${reset}"
        return 1
    fi

    # 清理持久化文件
    rm -f "/etc/systemd/network/10-${del_tun}.netdev" \
          "/etc/systemd/network/10-${del_tun}.network" \
          "/etc/network/interfaces.d/${del_tun}" 2>/dev/null
    sed -i "/^$del_tun|/d" "$TUNNEL_CONF"

    # 清理相关的 GRE 转发规则
    sed -i "/|$del_tun$/d" "$GRE_CONF"

    echo -e "${green}✓ 隧道 $del_tun 已删除${reset}"
}

show_tunnels() {
    echo ""
    echo -e "${bold}=== 当前 GRE 隧道状态 ===${reset}"
    echo ""

    local tunnels
    tunnels=$(list_gre_tunnels)
    if [ -z "$tunnels" ]; then
        echo -e "${yellow}当前没有 GRE 隧道${reset}"
        return
    fi

    while IFS= read -r tun; do
        local ttype tip
        ttype=$(get_tunnel_type "$tun")
        tip=$(get_tunnel_ip "$tun")
        local status
        status=$(ip link show "$tun" 2>/dev/null | grep -oE "state [A-Z]+" | awk '{print $2}')
        local mtu
        mtu=$(ip link show "$tun" 2>/dev/null | grep -oE "mtu [0-9]+" | awk '{print $2}')

        echo -e "  ${bold}$tun${reset}"
        echo -e "    类型: $ttype"
        echo -e "    状态: ${status:-UNKNOWN}"
        echo -e "    内网: ${tip:-无}"
        echo -e "    MTU:  ${mtu:-N/A}"

        # 显示隧道端点信息
        local detail
        detail=$(ip -d link show "$tun" 2>/dev/null)
        local remote_ep
        remote_ep=$(echo "$detail" | grep -oE "remote [0-9a-fA-F.:]+")
        local local_ep
        local_ep=$(echo "$detail" | grep -oE "local [0-9a-fA-F.:]+")
        [ -n "$local_ep" ] && echo -e "    本端: ${local_ep#local }"
        [ -n "$remote_ep" ] && echo -e "    对端: ${remote_ep#remote }"
        echo ""
    done <<< "$tunnels"
}

# ======================== 模块2: iptables 端口转发 ========================

add_iptables_forward() {
    echo ""
    echo -e "${bold}=== 添加 iptables 端口转发规则 ===${reset}"
    echo ""

    local localport remoteport remotehost

    echo -n "本地监听端口: "; read localport
    if ! is_valid_port "$localport"; then
        echo -e "${red}错误: 端口无效，请输入 1-65535 的数字${reset}"
        return 1
    fi

    echo -n "目标 IP / 域名: "; read remotehost
    if [ -z "$remotehost" ]; then
        echo -e "${red}错误: 目标地址不能为空${reset}"
        return 1
    fi

    echo -n "目标端口 [默认: 与本地端口相同]: "; read remoteport
    remoteport=${remoteport:-$localport}
    if ! is_valid_port "$remoteport"; then
        echo -e "${red}错误: 端口无效${reset}"
        return 1
    fi

    # 域名解析
    local remote_ip="$remotehost"
    if ! is_valid_ipv4 "$remotehost"; then
        echo -e "${cyan}>> 解析域名 $remotehost ...${reset}"
        remote_ip=$(host -t a "$remotehost" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        if [ -z "$remote_ip" ]; then
            # 尝试 dig
            remote_ip=$(dig +short "$remotehost" A 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        fi
        if [ -z "$remote_ip" ]; then
            echo -e "${red}错误: 域名解析失败${reset}"
            return 1
        fi
        echo -e "   解析结果: $remote_ip"
    fi

    enable_ip_forward
    open_forward_chain

    local localIP
    localIP=$(get_local_ipv4)

    # 添加 iptables 规则 (带 comment 标记，方便识别和清理)
    iptables -t nat -A PREROUTING -p tcp --dport "$localport" -j DNAT --to-destination "$remote_ip:$remoteport" -m comment --comment "tf:$localport"
    iptables -t nat -A PREROUTING -p udp --dport "$localport" -j DNAT --to-destination "$remote_ip:$remoteport" -m comment --comment "tf:$localport"
    iptables -t nat -A POSTROUTING -p tcp -d "$remote_ip" --dport "$remoteport" -j SNAT --to-source "$localIP" -m comment --comment "tf:$localport"
    iptables -t nat -A POSTROUTING -p udp -d "$remote_ip" --dport "$remoteport" -j SNAT --to-source "$localIP" -m comment --comment "tf:$localport"

    # 保存到配置
    sed -i "/^$localport>/d" "$FORWARD_CONF"
    echo "$localport>$remotehost:$remoteport" >> "$FORWARD_CONF"

    echo ""
    echo -e "${green}✓ 转发规则添加成功: $localport → $remotehost($remote_ip):$remoteport${reset}"
}

del_iptables_forward() {
    echo ""
    echo -e "${bold}=== 删除 iptables 端口转发规则 ===${reset}"
    echo ""

    if [ ! -s "$FORWARD_CONF" ]; then
        echo -e "${yellow}当前没有转发规则${reset}"
        return
    fi

    echo "当前转发规则:"
    local i=1
    local rules=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "  $i) $line"
        rules+=("$line")
        ((i++))
    done < "$FORWARD_CONF"

    echo ""
    echo -n "请输入要删除的规则编号 (或输入本地端口号): "; read choice

    local target_line=""
    if echo "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -le "${#rules[@]}" ] && [ "$choice" -ge 1 ]; then
        target_line="${rules[$((choice-1))]}"
    else
        # 按端口号查找
        target_line=$(grep "^${choice}>" "$FORWARD_CONF" | head -n1)
    fi

    if [ -z "$target_line" ]; then
        echo -e "${red}未找到匹配的规则${reset}"
        return 1
    fi

    local port
    port=$(echo "$target_line" | cut -d'>' -f1)
    local target
    target=$(echo "$target_line" | cut -d'>' -f2)
    local thost
    thost=$(echo "$target" | cut -d':' -f1)
    local tport
    tport=$(echo "$target" | cut -d':' -f2)

    # 解析 IP
    local remote_ip="$thost"
    if ! is_valid_ipv4 "$thost"; then
        remote_ip=$(host -t a "$thost" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        [ -z "$remote_ip" ] && remote_ip=$(dig +short "$thost" A 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    fi

    local localIP
    localIP=$(get_local_ipv4)

    # 删除 iptables 规则 (按 comment 标记精确删除)
    if [ -n "$remote_ip" ]; then
        iptables -t nat -D PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "$remote_ip:$tport" -m comment --comment "tf:$port" 2>/dev/null
        iptables -t nat -D PREROUTING -p udp --dport "$port" -j DNAT --to-destination "$remote_ip:$tport" -m comment --comment "tf:$port" 2>/dev/null
        iptables -t nat -D POSTROUTING -p tcp -d "$remote_ip" --dport "$tport" -j SNAT --to-source "$localIP" -m comment --comment "tf:$port" 2>/dev/null
        iptables -t nat -D POSTROUTING -p udp -d "$remote_ip" --dport "$tport" -j SNAT --to-source "$localIP" -m comment --comment "tf:$port" 2>/dev/null
    fi

    sed -i "/^${port}>/d" "$FORWARD_CONF"
    echo -e "${green}✓ 已删除规则: $target_line${reset}"
}

list_iptables_forward() {
    echo ""
    echo -e "${bold}=== 当前 iptables 转发规则 ===${reset}"
    echo ""

    if [ ! -s "$FORWARD_CONF" ]; then
        echo -e "${yellow}当前没有转发规则${reset}"
    else
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local port
            port=$(echo "$line" | cut -d'>' -f1)
            local target
            target=$(echo "$line" | cut -d'>' -f2)
            echo -e "  ${bold}$port${reset} → $target"
        done < "$FORWARD_CONF"
    fi

    echo ""
    echo -e "${cyan}--- iptables NAT 表当前状态 ---${reset}"
    iptables -L PREROUTING -n -t nat --line-number 2>/dev/null
    echo ""
    iptables -L POSTROUTING -n -t nat --line-number 2>/dev/null
}

# 设置 iptables 转发服务 (支持域名动态解析)
setup_forward_service() {
    enable_ip_forward
    open_forward_chain

    cat > /usr/local/bin/tunnel-forward-dnat.sh <<"SERVICEEOF"
#!/bin/bash
[[ "$EUID" -ne 0 ]] && echo "Error: must run as root" && exit 1

base=/etc/tunnel-forward
conf=$base/forward.conf
touch "$conf"

turnOnNat() {
    sed -n '/^net.ipv4.ip_forward=1/'p /etc/sysctl.conf | grep -q "net.ipv4.ip_forward=1"
    if [ $? -ne 0 ]; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p > /dev/null 2>&1
    fi
    iptables --policy FORWARD ACCEPT 2>/dev/null
}
turnOnNat

lastRules=""
while true; do
    localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | \
    grep -Ev '(^127\.)|(^10\.)|(^172\.(1[6-9]|2[0-9]|3[01])\.)|(^192\.168\.)' | head -n1)
    [ -z "$localIP" ] && localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | head -n1)

    newRules=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        port=$(echo "$line" | cut -d'>' -f1)
        target=$(echo "$line" | cut -d'>' -f2)
        host=$(echo "$target" | cut -d':' -f1)
        tport=$(echo "$target" | cut -d':' -f2)

        # 域名解析
        if echo "$host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            ip="$host"
        else
            ip=$(host -t a "$host" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
            [ -z "$ip" ] && ip=$(dig +short "$host" A 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        fi
        [ -z "$ip" ] && continue
        newRules="${newRules}${port}:${ip}:${tport}\n"
    done < "$conf"

    if [ "$newRules" != "$lastRules" ]; then
        # 只清理本脚本添加的规则（带 tf: 标记），不影响其他规则
        for chain in PREROUTING POSTROUTING; do
            while true; do
                linenum=$(iptables -t nat -L "$chain" -n --line-number 2>/dev/null | grep 'tf:' | head -n1 | awk '{print $1}')
                [ -z "$linenum" ] && break
                iptables -t nat -D "$chain" "$linenum"
            done
        done
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            port=$(echo "$line" | cut -d'>' -f1)
            target=$(echo "$line" | cut -d'>' -f2)
            host=$(echo "$target" | cut -d':' -f1)
            tport=$(echo "$target" | cut -d':' -f2)

            if echo "$host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                ip="$host"
            else
                ip=$(host -t a "$host" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
                [ -z "$ip" ] && ip=$(dig +short "$host" A 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
            fi
            [ -z "$ip" ] && continue

            iptables -t nat -A PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "$ip:$tport" -m comment --comment "tf:$port"
            iptables -t nat -A PREROUTING -p udp --dport "$port" -j DNAT --to-destination "$ip:$tport" -m comment --comment "tf:$port"
            iptables -t nat -A POSTROUTING -p tcp -d "$ip" --dport "$tport" -j SNAT --to-source "$localIP" -m comment --comment "tf:$port"
            iptables -t nat -A POSTROUTING -p udp -d "$ip" --dport "$tport" -j SNAT --to-source "$localIP" -m comment --comment "tf:$port"
        done < "$conf"
        lastRules="$newRules"
        echo "[$(date)] iptables 规则已更新"
    fi
    sleep 60
done
SERVICEEOF
    chmod +x /usr/local/bin/tunnel-forward-dnat.sh

    cat > /lib/systemd/system/tunnel-forward.service <<'EOF'
[Unit]
Description=端口转发服务 (iptables DNAT/SNAT, 支持域名动态解析)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash /usr/local/bin/tunnel-forward-dnat.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tunnel-forward > /dev/null 2>&1
    systemctl restart tunnel-forward > /dev/null 2>&1

    echo -e "${green}✓ 转发服务已安装并启动 (支持域名动态解析, 60秒轮询)${reset}"
}

# ======================== 模块3: GRE 隧道端口转发 (nftables) ========================

add_gre_forward() {
    echo ""
    echo -e "${bold}=== 添加 GRE 隧道端口转发 (nftables) ===${reset}"
    echo ""

    # 自动检测已有隧道
    local tunnels
    tunnels=$(list_gre_tunnels)
    if [ -z "$tunnels" ]; then
        echo -e "${red}错误: 未检测到 GRE 隧道，请先创建隧道${reset}"
        return 1
    fi

    # 选择隧道
    local tun_name tun_arr=()
    echo "检测到以下 GRE 隧道:"
    local i=1
    while IFS= read -r tun; do
        local ttype tip
        ttype=$(get_tunnel_type "$tun")
        tip=$(get_tunnel_ip "$tun")
        echo -e "  ${bold}$i)${reset} $tun  [类型: $ttype, 内网IP: $tip]"
        tun_arr+=("$tun")
        ((i++))
    done <<< "$tunnels"

    if [ "${#tun_arr[@]}" -eq 1 ]; then
        tun_name="${tun_arr[0]}"
        echo -e "  自动选择: ${green}$tun_name${reset}"
    else
        echo ""
        echo -n "选择隧道编号: "; read choice
        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tun_arr[@]}" ]; then
            echo -e "${red}无效选择${reset}"
            return 1
        fi
        tun_name="${tun_arr[$((choice-1))]}"
    fi

    local tun_type
    tun_type=$(get_tunnel_type "$tun_name")
    local tun_ip
    tun_ip=$(get_tunnel_ip "$tun_name")

    echo ""
    echo -e "隧道: ${bold}$tun_name${reset} (类型: $tun_type)"
    echo ""

    # 输入对端隧道内网 IP
    local peer_ip
    echo -n "对端隧道内网 IP [例如 10.10.1.2]: "; read peer_ip
    if ! is_valid_ipv4 "$peer_ip"; then
        echo -e "${red}错误: 无效的 IPv4 地址${reset}"
        return 1
    fi

    # 输入转发端口
    local port_input
    echo ""
    echo "端口格式说明:"
    echo "  单端口:     443"
    echo "  端口范围:   10000-20000"
    echo "  多端口:     443,8080,8443"
    echo ""
    echo -n "转发端口: "; read port_input
    if [ -z "$port_input" ]; then
        echo -e "${red}错误: 端口不能为空${reset}"
        return 1
    fi

    # 协议选择
    echo ""
    echo "转发协议:"
    echo "  1) TCP + UDP [默认]"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    echo -n "选择: "; read proto_choice
    proto_choice=${proto_choice:-1}

    enable_ip_forward

    # 保存到配置
    # 格式: port|peer_ip|proto|tun_name
    echo "$port_input|$peer_ip|$proto_choice|$tun_name" >> "$GRE_CONF"

    # 重新生成并应用 nftables 规则
    rebuild_nftables

    echo ""
    echo -e "${green}✓ GRE 隧道转发规则添加成功${reset}"
    echo -e "  隧道: $tun_name ($tun_type)"
    echo -e "  端口: $port_input → $peer_ip"
}

del_gre_forward() {
    echo ""
    echo -e "${bold}=== 删除 GRE 隧道转发规则 ===${reset}"
    echo ""

    if [ ! -s "$GRE_CONF" ]; then
        echo -e "${yellow}当前没有 GRE 隧道转发规则${reset}"
        return
    fi

    echo "当前 GRE 隧道转发规则:"
    local i=1
    local rules=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local port peer proto tun_name
        port=$(echo "$line" | cut -d'|' -f1)
        peer=$(echo "$line" | cut -d'|' -f2)
        proto=$(echo "$line" | cut -d'|' -f3)
        tun_name=$(echo "$line" | cut -d'|' -f4)
        local proto_str="TCP+UDP"
        [ "$proto" = "2" ] && proto_str="TCP"
        [ "$proto" = "3" ] && proto_str="UDP"
        echo -e "  ${bold}$i)${reset} 端口 $port → $peer [$proto_str] via $tun_name"
        rules+=("$line")
        ((i++))
    done < "$GRE_CONF"

    echo ""
    echo -n "请选择要删除的规则编号: "; read choice
    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#rules[@]}" ]; then
        echo -e "${red}无效选择${reset}"
        return 1
    fi

    # 删除对应行
    local del_line="${rules[$((choice-1))]}"
    grep -vF "$del_line" "$GRE_CONF" > "${GRE_CONF}.tmp"
    mv "${GRE_CONF}.tmp" "$GRE_CONF"

    rebuild_nftables
    echo -e "${green}✓ 规则已删除${reset}"
}

list_gre_forward() {
    echo ""
    echo -e "${bold}=== 当前 GRE 隧道转发规则 ===${reset}"
    echo ""

    if [ ! -s "$GRE_CONF" ]; then
        echo -e "${yellow}当前没有 GRE 隧道转发规则${reset}"
        return
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local port peer proto tun_name
        port=$(echo "$line" | cut -d'|' -f1)
        peer=$(echo "$line" | cut -d'|' -f2)
        proto=$(echo "$line" | cut -d'|' -f3)
        tun_name=$(echo "$line" | cut -d'|' -f4)
        local tun_type
        tun_type=$(get_tunnel_type "$tun_name" 2>/dev/null)
        local proto_str="TCP+UDP"
        [ "$proto" = "2" ] && proto_str="TCP"
        [ "$proto" = "3" ] && proto_str="UDP"
        echo -e "  端口 ${bold}$port${reset} → $peer [$proto_str] via $tun_name ($tun_type)"
    done < "$GRE_CONF"

    echo ""
    echo -e "${cyan}--- nftables 当前规则 ---${reset}"
    nft list ruleset 2>/dev/null || echo -e "${yellow}nftables 未安装或无规则${reset}"
}

# 为 GRE nftables 规则创建独立的 systemd 服务（开机自动加载）
setup_gre_nft_service() {
    cat > /lib/systemd/system/tunnel-gre-nft.service <<'SVCEOF'
[Unit]
Description=加载 GRE 隧道 nftables 转发规则
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/tunnel-forward/nftables-gre.conf
ExecReload=/usr/sbin/nft -f /etc/tunnel-forward/nftables-gre.conf
ExecStop=/usr/sbin/nft delete table ip tunnel_forward ; /usr/sbin/nft delete table inet mss_clamp

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable tunnel-gre-nft > /dev/null 2>&1
}

rebuild_nftables() {
    # nft 已在启动时检查安装，这里仅做保底
    if ! command -v nft &>/dev/null; then
        check_and_install nft nftables nftables || return 1
    fi

    local prerouting_rules=""

    # 用关联数组收集每个隧道的对端
    declare -A tun_peers

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local port peer proto tun_name
        port=$(echo "$line" | cut -d'|' -f1)
        peer=$(echo "$line" | cut -d'|' -f2)
        proto=$(echo "$line" | cut -d'|' -f3)
        tun_name=$(echo "$line" | cut -d'|' -f4)

        # 记录隧道对端
        tun_peers["$tun_name"]="$peer"

        # 生成 prerouting 规则
        local port_expr="$port"
        # 如果包含逗号，用 { } 集合语法
        if echo "$port" | grep -q ","; then
            port_expr="{ $port }"
        fi

        case $proto in
        2)  # 仅 TCP
            prerouting_rules="${prerouting_rules}        tcp dport $port_expr dnat to $peer\n"
            ;;
        3)  # 仅 UDP
            prerouting_rules="${prerouting_rules}        udp dport $port_expr dnat to $peer\n"
            ;;
        *)  # TCP + UDP
            prerouting_rules="${prerouting_rules}        tcp dport $port_expr dnat to $peer\n"
            prerouting_rules="${prerouting_rules}        udp dport $port_expr dnat to $peer\n"
            ;;
        esac
    done < "$GRE_CONF"

    # 生成 postrouting 规则 (按隧道接口去重)
    local postrouting_rules=""
    for tun in "${!tun_peers[@]}"; do
        local peer="${tun_peers[$tun]}"
        # 从 peer IP 推算网段
        local subnet
        subnet=$(echo "$peer" | sed 's/\.[0-9]*$/.0\/24/')
        postrouting_rules="${postrouting_rules}        ip daddr $subnet oifname \"$tun\" masquerade\n"
    done

    # 只刷新脚本自己管理的两个表，不影响其他已有规则
    echo -e "${cyan}>> 更新 nftables 规则（仅更新脚本管理的表）...${reset}"

    # 先删除旧的脚本管理的表（如果存在）
    nft delete table ip tunnel_forward 2>/dev/null
    nft delete table inet mss_clamp 2>/dev/null

    # 生成新规则并直接应用（不写 /etc/nftables.conf，避免覆盖用户已有配置）
    local nft_script_file="$BASE_DIR/nftables-gre.conf"

    cat > "$nft_script_file" <<NFTEOF
#!/usr/sbin/nft -f
# 由 tunnel-forward.sh 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')
# 仅管理 tunnel_forward 和 mss_clamp 两个表，不影响其他规则

table ip tunnel_forward {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

$(echo -e "$prerouting_rules")
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

$(echo -e "$postrouting_rules")
    }
}

# MSS Clamping — 自动调整 TCP MSS，防止隧道内大包被丢弃
table inet mss_clamp {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }
}
NFTEOF

    nft -f "$nft_script_file"
    if [ $? -eq 0 ]; then
        # 设置开机自动加载脚本管理的规则（不覆盖系统 nftables.conf）
        setup_gre_nft_service
        echo -e "${green}   nftables 规则已更新并应用（已有规则未受影响）${reset}"
    else
        echo -e "${red}   nftables 规则应用失败，请检查配置${reset}"
    fi
}

# ======================== 模块4: 一键部署 ========================

one_key_transit() {
    echo ""
    echo -e "${bold}=== 一键部署转发机 (隧道 + 端口转发) ===${reset}"
    echo ""
    echo "此向导将引导你:"
    echo "  1. 创建 GRE 隧道"
    echo "  2. 配置端口转发"
    echo "  3. 持久化所有配置"
    echo ""

    echo -e "${yellow}选择隧道类型:${reset}"
    echo "  1) IPv4 GRE"
    echo "  2) IPv6 GRE (ip6gre) [推荐, 不易被 QoS 限速]"
    echo -n "选择 [默认: 2]: "; read tun_choice
    tun_choice=${tun_choice:-2}

    case $tun_choice in
    1)  create_ipv4_gre ;;
    2)  create_ipv6_gre ;;
    *)  echo -e "${red}无效选择${reset}"; return 1 ;;
    esac

    echo ""
    echo -e "${yellow}是否立即配置端口转发？[Y/n]${reset}"; read do_forward
    if [[ "$do_forward" != "n" && "$do_forward" != "N" ]]; then
        while true; do
            add_gre_forward
            echo ""
            echo -n "继续添加转发规则？[y/N]: "; read more
            [[ "$more" != "y" && "$more" != "Y" ]] && break
        done
    fi

    echo ""
    echo -e "${green}${bold}✓ 转发机部署完成！${reset}"
}

# ======================== 主菜单 ========================

main_menu() {
    while true; do
        show_banner
        echo -e "${bold}请选择操作:${reset}"
        echo ""
        echo -e "  ${cyan}【GRE 隧道管理】${reset}"
        echo "    1) 创建 IPv4 GRE 隧道"
        echo "    2) 创建 IPv6 GRE (ip6gre) 隧道"
        echo "    3) 查看隧道状态"
        echo "    4) 删除隧道"
        echo ""
        echo -e "  ${cyan}【iptables 端口转发】${reset}"
        echo "    5) 添加转发规则"
        echo "    6) 删除转发规则"
        echo "    7) 查看转发规则"
        echo "    8) 安装转发服务 (域名动态解析)"
        echo ""
        echo -e "  ${cyan}【GRE 隧道端口转发 (nftables)】${reset}"
        echo "    9) 添加 GRE 隧道转发规则"
        echo "   10) 删除 GRE 隧道转发规则"
        echo "   11) 查看 GRE 隧道转发规则"
        echo ""
        echo -e "  ${cyan}【快捷操作】${reset}"
        echo "   12) 一键部署转发机"
        echo ""
        echo "    0) 退出"
        echo ""
        echo -n "请输入编号: "; read action

        case $action in
        1)  create_ipv4_gre ;;
        2)  create_ipv6_gre ;;
        3)  show_tunnels ;;
        4)  delete_tunnel ;;
        5)  add_iptables_forward ;;
        6)  del_iptables_forward ;;
        7)  list_iptables_forward ;;
        8)  setup_forward_service ;;
        9)  add_gre_forward ;;
        10) del_gre_forward ;;
        11) list_gre_forward ;;
        12) one_key_transit ;;
        0)  echo -e "${green}再见！${reset}"; exit 0 ;;
        *)  echo -e "${red}无效选项${reset}" ;;
        esac

        echo ""
        echo -e "${yellow}按 Enter 返回主菜单...${reset}"
        read
    done
}

# ======================== 入口 ========================
main_menu
