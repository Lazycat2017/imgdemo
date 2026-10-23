#!/bin/bash
#############################################################
# 多功能隧道转发脚本
# 功能：
#   1. 创建/管理 IPv4 GRE 隧道
#   2. 创建/管理 IPv6 GRE (ip6gre) 隧道
#   3. iptables 端口转发 (DNAT/SNAT)
#   4. GRE 隧道端口转发 (nftables, 自动识别隧道类型)
#   5. 首次运行安装到本机，输入 r 打开管理菜单
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
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_valid_port_range() {
    [[ "$1" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]] || return 1
    local first=${1%-*} last=${1#*-}
    is_valid_port "$first" && is_valid_port "$last" && (( 10#$first <= 10#$last ))
}

is_valid_port_spec() {
    is_valid_port "$1" || is_valid_port_range "$1"
}

normalize_port_spec() {
    is_valid_port_spec "$1" || return 1
    if [[ "$1" == *-* ]]; then
        local first=${1%-*} last=${1#*-}
        if (( 10#$first == 10#$last )); then
            printf '%d\n' "$((10#$first))"
        else
            printf '%d-%d\n' "$((10#$first))" "$((10#$last))"
        fi
    else
        printf '%d\n' "$((10#$1))"
    fi
}

is_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local octet parts=()
    IFS=. read -r -a parts <<< "$1"
    for octet in "${parts[@]}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_ipv6() {
    local addr=$1 tail left right group count=0 parts=()
    # IPv4 嵌入地址占两个 16 位分组。
    if [[ "$addr" == *.* ]]; then
        tail=${addr##*:}
        is_valid_ipv4 "$tail" || return 1
        addr="${addr%:*}:0:0"
    fi
    [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    if [[ "$addr" == *::* ]]; then
        left=${addr%%::*}
        right=${addr#*::}
        [[ "$right" != *::* && "$left" != :* && "$left" != *: && "$right" != :* && "$right" != *: ]] || return 1
        for tail in "$left" "$right"; do
            [[ -z "$tail" ]] && continue
            IFS=: read -r -a parts <<< "$tail"
            for group in "${parts[@]}"; do
                [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
                ((count+=1))
            done
        done
        (( count < 8 ))
    else
        [[ "$addr" != :* && "$addr" != *: ]] || return 1
        IFS=: read -r -a parts <<< "$addr"
        [[ ${#parts[@]} -eq 8 ]] || return 1
        for group in "${parts[@]}"; do
            [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        done
    fi
}

is_valid_tunnel_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$ ]] &&
        [[ "$1" != gre0 && "$1" != ip6gre0 && "$1" != ip6tnl0 && "$1" != sit0 ]]
}

is_valid_ipv4_cidr() {
    [[ "$1" == */* ]] || return 1
    local addr=${1%/*} prefix=${1##*/}
    is_valid_ipv4 "$addr" && [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix <= 32 ))
}

prefix_to_netmask() {
    local prefix=$1 mask
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix <= 32 )) || return 1
    mask=$(( (0xffffffff << (32 - 10#$prefix)) & 0xffffffff ))
    printf '%d.%d.%d.%d\n' "$(( (mask >> 24) & 255 ))" "$(( (mask >> 16) & 255 ))" "$(( (mask >> 8) & 255 ))" "$(( mask & 255 ))"
}

enable_ip_forward() {
    # 本脚本转发 IPv4 载荷；GRE 外层使用 IPv6 无需开启全局 IPv6 路由。
    local conf=/etc/sysctl.d/90-tunnel-forward.conf tmp
    echo -e "${cyan}>> 开启 IPv4 转发...${reset}"
    mkdir -p /etc/sysctl.d || return 1
    tmp=$(mktemp "${conf}.XXXXXX") || return 1
    if ! printf 'net.ipv4.ip_forward=1\n' > "$tmp" ||
       ! sysctl -w net.ipv4.ip_forward=1 >/dev/null ||
       ! chmod 644 "$tmp" || ! mv "$tmp" "$conf"; then
        rm -f "$tmp"
        echo -e "${red}错误: 无法开启或保存 IPv4 转发配置${reset}" >&2
        return 1
    fi
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
    ip -d link show "$1" 2>/dev/null | awk '
        $1 == "link/gre6" { print "ip6gre"; found=1; exit }
        $1 == "link/gre" { print "gre"; found=1; exit }
        END { if (!found) print "unknown" }
    '
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
    echo "║          多功能隧道转发管理脚本 v1.1                     ║"
    echo "║                                                         ║"
    echo "║  功能: GRE隧道创建 / 端口转发 / GRE隧道转发             ║"
    echo "║  支持: IPv4 GRE / IPv6 GRE (ip6gre) / iptables / nft   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo -e "  本机 IPv4: ${green}$(get_local_ipv4)${reset}"
    echo -e "  本机 IPv6: ${green}$(get_local_ipv6)${reset}"
    echo -e "  管理命令: ${green}r${reset}（打开本菜单）"

    local tunnels
    tunnels=$(list_gre_tunnels)
    if [ -n "$tunnels" ]; then
        echo -e "  已有隧道: ${yellow}${tunnels//$'\n'/ , }${reset}"
    fi
    echo ""
}

# ======================== 模块1: GRE 隧道管理 ========================

create_ipv4_gre() { create_gre_tunnel gre; }
create_ipv6_gre() { create_gre_tunnel ip6gre; }

create_gre_tunnel() {
    local tun_type=$1 tun_name local_addr remote_addr local_inner mtu_val default_addr tmp
    echo -e "\n${bold}=== 创建 $tun_type 隧道 ===${reset}\n"
    read -r -p "隧道接口名称 [默认: tun-gre]: " tun_name || return 1
    tun_name=${tun_name:-tun-gre}
    if ! is_valid_tunnel_name "$tun_name"; then
        echo -e "${red}错误: 接口名称须为 1-15 位字母、数字、点、下划线或连字符，且不能使用系统默认隧道名${reset}"
        return 1
    fi
    if ip link show "$tun_name" &>/dev/null; then
        echo -e "${red}错误: 接口 $tun_name 已存在${reset}"
        return 1
    fi

    if [[ "$tun_type" == gre ]]; then
        default_addr=$(get_local_ipv4)
    else
        default_addr=$(get_local_ipv6)
    fi
    read -r -p "本机公网地址 [默认: $default_addr]: " local_addr || return 1
    local_addr=${local_addr:-$default_addr}
    read -r -p "对端公网地址: " remote_addr || return 1
    if [[ "$tun_type" == gre ]]; then
        is_valid_ipv4 "$local_addr" && is_valid_ipv4 "$remote_addr" || {
            echo -e "${red}错误: 本机或对端 IPv4 地址无效${reset}"; return 1;
        }
    else
        is_valid_ipv6 "$local_addr" && is_valid_ipv6 "$remote_addr" || {
            echo -e "${red}错误: 本机或对端 IPv6 地址无效${reset}"; return 1;
        }
    fi
    read -r -p "本端隧道内网 IP [默认: 10.10.1.1/24]: " local_inner || return 1
    local_inner=${local_inner:-10.10.1.1/24}
    if ! is_valid_ipv4_cidr "$local_inner"; then
        echo -e "${red}错误: 内网地址须为有效 IPv4/前缀长度，例如 10.10.1.1/30${reset}"
        return 1
    fi
    local_inner="${local_inner%/*}/$((10#${local_inner##*/}))"
    [[ "$tun_type" == gre ]] && mtu_val=1450 || mtu_val=1400
    read -r -p "MTU [默认: $mtu_val]: " tmp || return 1
    mtu_val=${tmp:-$mtu_val}
    if ! [[ "$mtu_val" =~ ^[0-9]{2,5}$ ]] || (( 10#$mtu_val < 68 || 10#$mtu_val > 65535 )); then
        echo -e "${red}错误: IPv4 隧道 MTU 须为 68-65535${reset}"
        return 1
    fi
    mtu_val=$((10#$mtu_val))
    with_forward_lock create_gre_tunnel_unlocked "$tun_type" "$tun_name" "$local_addr" "$remote_addr" "$local_inner" "$mtu_val" || return 1
    echo -e "${green}✓ 隧道已创建: $tun_name ($tun_type), $local_addr → $remote_addr, 内网 $local_inner, MTU $mtu_val${reset}"
    ask_persist_tunnel "$tun_name" "$tun_type" "$local_addr" "$remote_addr" "$local_inner" "$mtu_val" || {
        echo -e "${yellow}隧道当前可用，但持久化未完成${reset}" >&2
        return 1
    }
}

# 调用方持有共享锁，接口检查、创建和记录提交不能与另一个创建或删除交错。
create_gre_tunnel_unlocked() {
    local tun_type=$1 tun_name=$2 local_addr=$3 remote_addr=$4 local_inner=$5 mtu_val=$6 module tmp
    if ip link show "$tun_name" &>/dev/null; then
        echo -e "${red}错误: 接口 $tun_name 已存在${reset}" >&2
        return 1
    fi
    [[ "$tun_type" == gre ]] && module=ip_gre || module=ip6_gre
    modprobe "$module" || { echo -e "${red}错误: 无法加载 $module${reset}"; return 1; }
    if [[ "$tun_type" == gre ]]; then
        ip tunnel add "$tun_name" mode gre remote "$remote_addr" local "$local_addr" ttl 255 || return 1
    else
        ip link add "$tun_name" type ip6gre local "$local_addr" remote "$remote_addr" ttl 255 encaplimit none || return 1
    fi
    if ! ip addr add "$local_inner" dev "$tun_name" || ! ip link set "$tun_name" mtu "$mtu_val" up; then
        echo -e "${red}错误: 配置隧道地址或 MTU 失败，正在撤销新接口${reset}" >&2
        ip link del "$tun_name" || echo "撤销失败，请手动检查接口 $tun_name" >&2
        return 1
    fi

    tmp=$(mktemp "${TUNNEL_CONF}.XXXXXX") || { ip link del "$tun_name"; return 1; }
    if ! awk -F'|' -v name="$tun_name" '$1 != name' "$TUNNEL_CONF" > "$tmp" ||
       ! printf '%s|%s|%s|%s|%s|%s\n' "$tun_name" "$tun_type" "$local_addr" "$remote_addr" "$local_inner" "$mtu_val" >> "$tmp" ||
       ! mv "$tmp" "$TUNNEL_CONF"; then
        rm -f "$tmp"
        ip link del "$tun_name"
        echo -e "${red}错误: 保存隧道记录失败${reset}" >&2
        return 1
    fi
}

render_tunnel_netdev() {
    local tun_name=$1 tun_type=$2 local_addr=$3 remote_addr=$4 mtu_val=$5
    cat <<EOFNETDEV
[NetDev]
Name=$tun_name
Kind=$tun_type
MTUBytes=$mtu_val

[Tunnel]
Independent=yes
Local=$local_addr
Remote=$remote_addr
TTL=255
EOFNETDEV
    [[ "$tun_type" != ip6gre ]] || echo 'EncapsulationLimit=none'
}

render_tunnel_ifupdown() {
    local tun_name=$1 tun_type=$2 local_addr=$3 remote_addr=$4 inner_ip=$5 mtu_val=$6 mask
    mask=$(prefix_to_netmask "${inner_ip##*/}") || return 1
    cat <<EOFIFACE
auto $tun_name
iface $tun_name inet static
    address ${inner_ip%/*}
    netmask $mask
EOFIFACE
    if [[ "$tun_type" == gre ]]; then
        echo "    pre-up ip link show dev $tun_name >/dev/null 2>&1 || ip tunnel add $tun_name mode gre remote $remote_addr local $local_addr ttl 255"
    else
        echo "    pre-up ip link show dev $tun_name >/dev/null 2>&1 || ip link add $tun_name type ip6gre local $local_addr remote $remote_addr ttl 255 encaplimit none"
    fi
    echo "    post-up ip link set dev $tun_name mtu $mtu_val"
    echo "    post-down ip link del $tun_name"
}

ask_persist_tunnel() {
    local tun_name=$1 tun_type=$2 local_addr=$3 remote_addr=$4 inner_ip=$5 mtu_val=$6 persist_choice
    echo -e "${yellow}是否持久化隧道（重启不丢失）？${reset}"
    echo "  1) 使用 systemd-networkd 持久化"
    echo "  2) 使用 ifupdown 持久化"
    echo "  3) 不持久化（重启后丢失）"
    read -r -p "请选择 [默认: 3]: " persist_choice || return 1
    with_forward_lock persist_tunnel_unlocked "$tun_name" "$tun_type" "$local_addr" "$remote_addr" "$inner_ip" "$mtu_val" "${persist_choice:-3}"
}

persist_tunnel_unlocked() {
    local tun_name=$1 tun_type=$2 local_addr=$3 remote_addr=$4 inner_ip=$5 mtu_val=$6 persist_choice=$7
    ip link show "$tun_name" &>/dev/null || { echo "错误: 隧道 $tun_name 已被删除，未保存持久化配置" >&2; return 1; }
    case ${persist_choice:-3} in
    1)
        command -v systemctl >/dev/null && systemctl cat systemd-networkd.service >/dev/null 2>&1 || {
            echo '错误: 系统未安装 systemd-networkd' >&2; return 1;
        }
        local netdev_file="/etc/systemd/network/10-${tun_name}.netdev"
        local network_file="/etc/systemd/network/10-${tun_name}.network" tmp_dir
        if [[ -e "$netdev_file" || -e "$network_file" ]]; then
            echo '错误: 同名 networkd 配置已存在，请先检查，未覆盖原文件' >&2
            return 1
        fi
        mkdir -p /etc/systemd/network || return 1
        tmp_dir=$(mktemp -d /etc/systemd/network/.tunnel-forward.XXXXXX) || return 1
        if ! render_tunnel_netdev "$tun_name" "$tun_type" "$local_addr" "$remote_addr" "$mtu_val" > "$tmp_dir/tunnel.netdev" ||
           ! printf '[Match]\nName=%s\n\n[Network]\nAddress=%s\n' "$tun_name" "$inner_ip" > "$tmp_dir/tunnel.network" ||
           ! chmod 644 "$tmp_dir/tunnel.netdev" "$tmp_dir/tunnel.network" ||
           ! mv "$tmp_dir/tunnel.netdev" "$netdev_file" || ! mv "$tmp_dir/tunnel.network" "$network_file" ||
           ! systemctl enable systemd-networkd; then
            rm -f "$tmp_dir/tunnel.netdev" "$tmp_dir/tunnel.network" "$netdev_file" "$network_file"
            rmdir "$tmp_dir"
            return 1
        fi
        rmdir "$tmp_dir"
        echo -e "${green}✓ networkd 配置已保存，服务已设为开机启动${reset}"
        ;;
    2)
        command -v ifup >/dev/null && [[ -f /etc/network/interfaces ]] || {
            echo '错误: 系统未配置 ifupdown' >&2; return 1;
        }
        local iface_file="/etc/network/interfaces.d/$tun_name" tmp
        [[ ! -e "$iface_file" ]] || { echo '错误: 同名 ifupdown 配置已存在，未覆盖' >&2; return 1; }
        mkdir -p /etc/network/interfaces.d || return 1
        tmp=$(mktemp "${iface_file}.XXXXXX") || return 1
        if ! render_tunnel_ifupdown "$tun_name" "$tun_type" "$local_addr" "$remote_addr" "$inner_ip" "$mtu_val" > "$tmp" ||
           ! chmod 644 "$tmp" || ! mv "$tmp" "$iface_file"; then
            rm -f "$tmp"
            return 1
        fi
        if ! grep -Eq '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*([[:space:]]|$)' /etc/network/interfaces; then
            printf '\nsource /etc/network/interfaces.d/*\n' >> /etc/network/interfaces || { rm -f "$iface_file"; return 1; }
        fi
        echo -e "${green}✓ 已通过 ifupdown 持久化 ($iface_file)${reset}"
        ;;
    3|'') echo -e "${yellow}隧道未持久化，重启后将丢失${reset}" ;;
    *) echo '错误: 无效的持久化选项' >&2; return 1 ;;
    esac
}

delete_tunnel() {
    echo -e "\n${bold}=== 删除 GRE 隧道 ===${reset}\n"
    local tunnels tun ttype tip choice confirm del_tun
    local tun_arr=()
    tunnels=$(list_gre_tunnels)
    [[ -n "$tunnels" ]] || { echo '当前没有 GRE 隧道'; return 0; }
    while IFS= read -r tun; do
        tun_arr+=("$tun")
        ttype=$(get_tunnel_type "$tun"); tip=$(get_tunnel_ip "$tun")
        printf '  %s) %s [类型: %s, 内网IP: %s]\n' "${#tun_arr[@]}" "$tun" "$ttype" "${tip:-无}"
    done <<< "$tunnels"
    read -r -p '请选择要删除的隧道编号: ' choice || return 1
    if ! [[ "$choice" =~ ^[0-9]{1,6}$ ]] || (( 10#$choice < 1 || 10#$choice > ${#tun_arr[@]} )); then
        echo '错误: 无效选择' >&2
        return 1
    fi
    del_tun=${tun_arr[$((10#$choice-1))]}
    is_valid_tunnel_name "$del_tun" || { echo '错误: 接口名称不受支持，请手动处理' >&2; return 1; }
    read -r -p "确认删除隧道 $del_tun 及其转发规则？[y/N]: " confirm || return 1
    [[ "$confirm" == y || "$confirm" == Y ]] || { echo '已取消'; return 0; }

    with_forward_lock delete_selected_tunnel "$del_tun"
}

delete_selected_tunnel() {
    local del_tun=$1 candidate backup records changed=0
    ip link show "$del_tun" &>/dev/null || { echo "错误: 隧道已不存在" >&2; return 1; }
    backup=$(mktemp "$BASE_DIR/.gre-delete-backup.XXXXXX") || return 1
    candidate=$(mktemp "$BASE_DIR/.gre-delete.XXXXXX") || { rm -f "$backup"; return 1; }
    records=$(mktemp "$BASE_DIR/.tunnels-delete.XXXXXX") || { rm -f "$backup" "$candidate"; return 1; }
    if ! cp "$GRE_CONF" "$backup" ||
       ! awk -F'|' -v name="$del_tun" '$4 != name' "$GRE_CONF" > "$candidate" ||
       ! awk -F'|' -v name="$del_tun" '$1 != name' "$TUNNEL_CONF" > "$records"; then
        rm -f "$backup" "$candidate" "$records"
        return 1
    fi
    # 先移除实时与开机转发规则，失败则保留接口和原记录。
    if ! cmp -s "$candidate" "$GRE_CONF"; then
        if ! commit_gre_config_unlocked "$candidate"; then
            rm -f "$backup" "$candidate" "$records"
            return 1
        fi
        changed=1
    fi
    if ! ip link del "$del_tun" || ip link show "$del_tun" &>/dev/null; then
        echo -e "${red}错误: 隧道删除失败，正在恢复其转发规则${reset}" >&2
        if [[ "$changed" == 1 ]]; then
            commit_gre_config_unlocked "$backup" || echo '错误: 恢复转发规则失败，请手动检查' >&2
        fi
        rm -f "$backup" "$candidate" "$records"
        return 1
    fi
    rm -f "$backup" "$candidate"
    if ! rm -f "/etc/systemd/network/10-${del_tun}.netdev" "/etc/systemd/network/10-${del_tun}.network" "/etc/network/interfaces.d/${del_tun}" ||
       ! mv "$records" "$TUNNEL_CONF"; then
        rm -f "$records"
        echo -e "${red}接口已删除，但清理持久化文件失败，请检查 $del_tun 的配置${reset}" >&2
        return 1
    fi
    echo -e "${green}✓ 隧道 $del_tun 及其转发规则已删除${reset}"
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

# 同号范围省略 DNAT 目标端口；偏移范围用 /baseport 保持逐端口偏移。
# 单独的 IP:起点-终点 是端口池，不能用于一一映射。
is_valid_forward_mapping() {
    is_valid_port_spec "$1" && is_valid_port_spec "$2" || return 1
    local localport remoteport local_first local_last remote_first remote_last
    localport=$(normalize_port_spec "$1"); remoteport=$(normalize_port_spec "$2")
    local_first=${localport%-*}; local_last=${localport#*-}
    remote_first=${remoteport%-*}; remote_last=${remoteport#*-}
    (( local_last - local_first == remote_last - remote_first ))
}

is_valid_forward_host() {
    is_valid_ipv4 "$1" && return 0
    [[ "$1" =~ ^[0-9.]+$ ]] && return 1
    local hostname=${1%.} label
    [[ -n "$hostname" && ${#hostname} -le 253 && "$hostname" != *..* ]] || return 1
    local labels=()
    IFS=. read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

resolve_forward_host() {
    local hostname=$1 ip resolver
    if is_valid_ipv4 "$hostname"; then
        printf '%s\n' "$hostname"
        return 0
    fi
    # 按顺序尝试系统解析和可用的 DNS 工具，兼容不支持 ahostsv4 的 getent。
    for resolver in getent dig host; do
        command -v "$resolver" >/dev/null 2>&1 || continue
        while IFS= read -r ip; do
            if is_valid_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done < <(
            if [[ "$resolver" == getent ]]; then
                getent ahostsv4 "$hostname" 2>/dev/null | awk '{print $1}'
            elif [[ "$resolver" == dig ]]; then
                dig +time=3 +tries=1 +short "$hostname" A 2>/dev/null
            else
                host -W 3 -t A "$hostname" 2>/dev/null | awk '/has address/ {print $NF}'
            fi
        )
    done
    return 1
}

# 锁覆盖读取配置、内核更新与保存，防止菜单和后台服务互相覆盖。
with_forward_lock() (
    flock -x 9 || return 1
    "$@"
) 9>"$BASE_DIR/forward.lock"

# 输出当前快照中本模块的规则；不匹配相似名称或他人的 comment。
forward_owned_rules() {
    local snapshot=$1 table=$2
    awk -v wanted="$table" '
        /^\*/ { active = (substr($0, 2) == wanted); next }
        /^COMMIT/ { active = 0 }
        active && /^-A / {
            owned = ($2 == "TF_DNAT" || $2 == "TF_SNAT" || $2 == "TF_FORWARD")
            hook = ($2 == "PREROUTING" || $2 == "POSTROUTING" || $2 == "FORWARD") &&
                ($0 ~ /--comment "?tf:managed"?( |$)/) &&
                ($0 ~ /-j TF_(DNAT|SNAT|FORWARD)( |$)/)
            legacy = wanted == "nat" && ($2 == "PREROUTING" || $2 == "POSTROUTING") &&
                ($0 ~ /--comment "?tf:[0-9]+(-[0-9]+)?"?( |$)/)
            if (owned || hook || legacy) print
        }
    ' "$snapshot"
}

# 只替换本模块的链、入口和旧版 tf:端口 规则；--noflush 保留其它规则和策略。
write_forward_table() {
    local table=$1 current=$2 rules=$3
    printf '*%s\n' "$table"
    if [[ "$table" == nat ]]; then
        printf ':TF_DNAT - [0:0]\n:TF_SNAT - [0:0]\n-F TF_DNAT\n-F TF_SNAT\n'
    else
        printf ':TF_FORWARD - [0:0]\n-F TF_FORWARD\n'
    fi
    forward_owned_rules "$current" "$table" | awk '
        $2 != "TF_DNAT" && $2 != "TF_SNAT" && $2 != "TF_FORWARD" { sub(/^-A /, "-D "); print }
    '
    # 入口放在前面，让本模块的精确放行规则能在已有 DROP 之前生效。
    awk '
        $2 == "PREROUTING" || $2 == "POSTROUTING" || $2 == "FORWARD" {
            if ($0 ~ /--comment "?tf:managed"?( |$)/) {
                sub(/^-A /, "-I "); sub(/^(-I [^ ]+)/, "& 1")
            }
        }
        { print }
    ' "$rules"
    printf 'COMMIT\n'
}

build_forward_rule_files() {
    local state=$1 nat_rules=$2 filter_rules=$3
    local line mapping ip localport target remoteport match_local match_remote proto destination
    : > "$nat_rules"
    : > "$filter_rules"
    printf '%s\n' '-A PREROUTING -m addrtype --dst-type LOCAL -m comment --comment tf:managed -j TF_DNAT' \
        '-A POSTROUTING -m comment --comment tf:managed -j TF_SNAT' >> "$nat_rules"
    printf '%s\n' '-A FORWARD -m comment --comment tf:managed -j TF_FORWARD' >> "$filter_rules"
    while IFS= read -r line; do
        mapping=${line%|*}; ip=${line##*|}
        localport=${mapping%%>*}; target=${mapping#*>}; remoteport=${target##*:}
        match_local=${localport/-/:}; match_remote=${remoteport/-/:}
        destination="$ip:$remoteport"
        if [[ "$localport" == *-* ]]; then
            if [[ "$localport" == "$remoteport" ]]; then
                destination="$ip"
            else
                # Linux >= 4.18: 原端口减去本地区间起点，再加上目标区间起点。
                destination="$ip:$remoteport/${localport%-*}"
            fi
        fi
        for proto in tcp udp; do
            printf -- '-A TF_DNAT -p %s --dport %s -j DNAT --to-destination %s\n' \
                "$proto" "$match_local" "$destination" >> "$nat_rules"
            printf -- '-A TF_SNAT -p %s -d %s --dport %s -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport %s -j MASQUERADE\n' \
                "$proto" "$ip" "$match_remote" "$match_local" >> "$nat_rules"
            printf -- '-A TF_FORWARD -p %s -d %s --dport %s -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport %s -j ACCEPT\n' \
                "$proto" "$ip" "$match_remote" "$match_local" >> "$filter_rules"
            printf -- '-A TF_FORWARD -p %s -s %s --sport %s -m conntrack --ctstate DNAT --ctdir REPLY --ctorigdstport %s -j ACCEPT\n' \
                "$proto" "$ip" "$match_remote" "$match_local" >> "$filter_rules"
        done
    done < "$state"
}

build_forward_state() {
    local conf=$1 state=$2 line localport target hostname remoteport ip previous_start previous_end start end
    local intervals=() interval gre_ports
    : > "$state"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *'>'* && "${line#*>}" == *:* ]] || { echo "错误: 无效转发配置: $line" >&2; return 1; }
        localport=${line%%>*}; target=${line#*>}; hostname=${target%:*}; remoteport=${target##*:}
        if ! is_valid_forward_mapping "$localport" "$remoteport" || ! is_valid_forward_host "$hostname"; then
            echo "错误: 无效转发配置或不支持的端口映射: $line" >&2
            return 1
        fi
        localport=$(normalize_port_spec "$localport"); remoteport=$(normalize_port_spec "$remoteport")
        start=${localport%-*}; end=${localport#*-}
        for interval in "${intervals[@]}"; do
            previous_start=${interval%-*}; previous_end=${interval#*-}
            if (( start <= previous_end && end >= previous_start )); then
                echo "错误: 本地端口范围重叠: $localport 与 $interval" >&2
                return 1
            fi
        done
        intervals+=("$start-$end")
        if [[ -f "$GRE_CONF" ]]; then
            while IFS='|' read -r gre_ports _gre_rest || [[ -n "$gre_ports" ]]; do
                [[ -z "$gre_ports" ]] && continue
                if gre_ports_overlap "$localport" "$gre_ports"; then
                    echo "错误: iptables 端口 $localport 与 GRE 转发端口 $gre_ports 重叠，请先调整已有规则" >&2
                    return 1
                fi
            done < "$GRE_CONF"
        fi
        line="$localport>$hostname:$remoteport"
        ip=$(resolve_forward_host "$hostname") || ip=""
        if [[ -z "$ip" && -f "$BASE_DIR/forward.state" ]]; then
            ip=$(awk -F '|' -v key="$line" '$1 == key {print $2; exit}' "$BASE_DIR/forward.state")
            if is_valid_ipv4 "$ip"; then
                echo "警告: $hostname 暂时解析失败，继续使用上次成功地址 $ip" >&2
            else
                ip=""
            fi
        fi
        [[ -n "$ip" ]] || { echo "错误: 无法解析 $hostname，保留当前转发规则" >&2; return 1; }
        printf '%s|%s\n' "$line" "$ip" >> "$state"
    done < "$conf"
}

# 调用方必须持有 forward.lock。配置和 DNS 缓存只在内核更新成功后提交。
sync_iptables_forward() {
    local source_conf=$1 commit_config=${2:-no} work result=1
    work=$(mktemp -d "$BASE_DIR/.iptables.XXXXXX") || return 1
    if ! cp "$FORWARD_CONF" "$work/config.old" ||
       ! build_forward_state "$source_conf" "$work/state" ||
       ! build_forward_rule_files "$work/state" "$work/nat.new" "$work/filter.new" ||
       ! iptables-save > "$work/before"; then
        rm -rf -- "$work"
        return 1
    fi
    forward_owned_rules "$work/before" nat > "$work/nat.old"
    forward_owned_rules "$work/before" filter > "$work/filter.old"
    # 先同时允许旧、新连接，再切换 NAT，最后收窄过滤；每个表使用一次原子提交。
    cat "$work/filter.new" > "$work/filter.transition"
    awk '$2 == "TF_FORWARD"' "$work/filter.old" >> "$work/filter.transition"
    {
        write_forward_table filter "$work/before" "$work/filter.transition"
        write_forward_table nat "$work/before" "$work/nat.new"
    } > "$work/update"
    # 最后只收窄链内规则，保留第一次提交建立的入口；--test 无须模拟前次提交。
    {
        printf '*filter\n:TF_FORWARD - [0:0]\n-F TF_FORWARD\n'
        awk '$2 == "TF_FORWARD"' "$work/filter.new"
        printf 'COMMIT\n'
    } >> "$work/update"
    if ! iptables-restore --wait 5 --noflush --test < "$work/update"; then
        echo "错误: iptables 配置校验失败，现有规则未改变" >&2
        rm -rf -- "$work"
        return 1
    fi
    if iptables-restore --wait 5 --noflush < "$work/update"; then
        if [[ "$commit_config" != yes ]] || mv "$source_conf" "$FORWARD_CONF"; then
            if mv "$work/state" "$BASE_DIR/forward.state"; then
                result=0
            fi
        fi
    fi
    if (( result != 0 )); then
        echo "错误: 更新失败，正在恢复本模块原有规则和配置" >&2
        if iptables-save > "$work/after"; then
            {
                write_forward_table filter "$work/after" "$work/filter.old"
                write_forward_table nat "$work/after" "$work/nat.old"
            } > "$work/rollback"
            iptables-restore --wait 5 --noflush < "$work/rollback" || echo "严重错误: iptables 回滚失败，请检查系统日志" >&2
        else
            echo "严重错误: 无法读取规则以回滚，请检查 iptables" >&2
        fi
        [[ "$commit_config" != yes ]] || mv "$work/config.old" "$FORWARD_CONF" || echo "严重错误: 恢复配置失败" >&2
    fi
    rm -rf -- "$work"
    return "$result"
}

update_forward_configuration() {
    local operation=$1 localport=$2 hostname=${3:-} remoteport=${4:-} candidate
    candidate=$(mktemp "$BASE_DIR/.forward.conf.XXXXXX") || return 1
    awk -F '>' -v port="$localport" '$1 != port' "$FORWARD_CONF" > "$candidate" || { rm -f -- "$candidate"; return 1; }
    if [[ "$operation" == add ]]; then
        printf '%s>%s:%s\n' "$localport" "$hostname" "$remoteport" >> "$candidate"
    fi
    if sync_iptables_forward "$candidate" yes; then
        return 0
    fi
    rm -f -- "$candidate"
    return 1
}

# 旧版后台进程会按 tf: 注释删除新规则；变更前先停止并升级仍在运行的旧服务。
ensure_forward_service_current() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl is-active --quiet tunnel-forward.service || return 0
    local exec_start
    exec_start=$(systemctl show -p ExecStart --value tunnel-forward.service) || return 1
    if [[ "$exec_start" == *--forward-daemon* ]] &&
       write_forward_service_script | cmp -s - /usr/local/bin/tunnel-forward-dnat.sh; then
        return 0
    fi
    echo "检测到运行中的旧版转发服务，先升级服务以避免旧进程覆盖新规则。"
    setup_forward_service
}

add_iptables_forward() {
    echo ""
    echo -e "${bold}=== 添加 iptables 端口转发规则 (TCP + UDP) ===${reset}"
    echo "范围示例: 本地 1000-65535 → 目标 1000-65535，逐端口保持不变。"
    local localport remoteport remotehost
    read -r -p "本地端口或范围: " localport
    is_valid_port_spec "$localport" || { echo "错误: 请输入 1-65535 的端口或递增范围"; return 1; }
    localport=$(normalize_port_spec "$localport")
    read -r -p "目标 IPv4 / 域名: " remotehost
    is_valid_forward_host "$remotehost" || { echo "错误: 目标 IPv4 / 域名无效"; return 1; }
    read -r -p "目标端口或等长范围 [默认: $localport]: " remoteport
    remoteport=${remoteport:-$localport}
    if ! is_valid_forward_mapping "$localport" "$remoteport"; then
        echo "错误: 本地和目标端口数量必须相同；支持单端口或等长范围映射"
        return 1
    fi
    remoteport=$(normalize_port_spec "$remoteport")
    if [[ "$localport" == *-* && "$localport" != "$remoteport" ]]; then
        echo "提示: 范围偏移需要 Linux 4.18+ 及支持 /baseport 的 iptables；预检失败会保留现有规则。"
    fi
    ensure_forward_service_current || return 1
    enable_ip_forward || return 1
    if with_forward_lock update_forward_configuration add "$localport" "$remotehost" "$remoteport"; then
        if ! setup_forward_service; then
            echo "错误: 规则已保存并在当前系统生效，但开机恢复未完成；请使用菜单 8 重试安装服务。" >&2
            return 1
        fi
        echo -e "${green}✓ 转发规则已保存并生效，已启用开机恢复: $localport → $remotehost:$remoteport (TCP + UDP)${reset}"
    else
        return 1
    fi
}

del_iptables_forward() {
    echo ""
    echo -e "${bold}=== 删除 iptables 端口转发规则 ===${reset}"
    [[ -s "$FORWARD_CONF" ]] || { echo "当前没有转发规则"; return 0; }
    local line choice target_line="" i=1
    local rules=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        printf '  %s) %s\n' "$i" "$line"
        rules+=("$line"); ((i+=1))
    done < "$FORWARD_CONF"
    read -r -p "请输入规则编号，或 p:本地端口/范围 (如 p:1000-65535): " choice
    if [[ "$choice" =~ ^[0-9]{1,6}$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#rules[@]} )); then
        target_line=${rules[$((10#$choice-1))]}
    elif [[ "$choice" == p:* ]] && is_valid_port_spec "${choice#p:}"; then
        choice=$(normalize_port_spec "${choice#p:}")
        target_line=$(awk -F '>' -v port="$choice" '$1 == port {print; exit}' "$FORWARD_CONF")
    fi
    [[ -n "$target_line" ]] || { echo "错误: 未找到匹配的规则"; return 1; }
    # 按持久化规则键重建，不需要重新解析被删除规则的域名。
    ensure_forward_service_current || return 1
    if with_forward_lock update_forward_configuration delete "${target_line%%>*}"; then
        echo -e "${green}✓ 已删除规则: $target_line${reset}"
    else
        return 1
    fi
}

list_iptables_forward() {
    echo ""
    echo -e "${bold}=== 当前 iptables 转发规则 (TCP + UDP) ===${reset}"
    if [[ -s "$FORWARD_CONF" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] || printf '  %s → %s\n' "${line%%>*}" "${line#*>}"
        done < "$FORWARD_CONF"
    else
        echo "当前没有转发规则"
    fi
    iptables -t nat -L TF_DNAT -n --line-numbers 2>/dev/null
}

run_forward_daemon() {
    enable_ip_forward || return 1
    while true; do
        if ! with_forward_lock sync_iptables_forward "$FORWARD_CONF"; then
            echo "[$(date)] 转发更新失败，60 秒后重试" >&2
        fi
        sleep 60
    done
}

# bash <(curl ...) 的源文件是管道；从已加载的定义生成后台脚本，避免再次读取管道。
write_forward_service_script() {
    printf '#!/bin/bash\n' || return 1
    declare -p red green yellow cyan bold reset BASE_DIR FORWARD_CONF GRE_CONF TUNNEL_CONF || return 1
    declare -f || return 1
    cat <<'DAEMONEOF'
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_tunnel_forward "$@"
fi
DAEMONEOF
}

install_local_command() (
    local manager_dir=/usr/local/lib/tunnel-forward launcher=/usr/local/bin/r
    local manager="$manager_dir/manager.sh" existing_command staged_script changed=0
    exec 8>"$BASE_DIR/launcher.lock" || return 1
    flock -x 8 || return 1
    existing_command=$(command -v r) || existing_command=""
    if [[ -n "$existing_command" && "$existing_command" != "$launcher" ]] ||
       { [[ -e "$launcher" || -L "$launcher" ]] &&
         { [[ ! -L "$launcher" ]] || [[ "$(readlink "$launcher")" != "$manager" ]]; }; }; then
        echo "错误: r 命令已被其他程序占用，未覆盖，请先处理已有命令" >&2
        return 1
    fi
    umask 022
    mkdir -p "$manager_dir" /usr/local/bin || return 1
    staged_script=$(mktemp "$manager_dir/.manager.XXXXXX") || return 1
    trap 'rm -f -- "$staged_script"' EXIT
    write_forward_service_script > "$staged_script" &&
        bash -n "$staged_script" && chmod 0755 "$staged_script" || return 1
    if [[ ! -f "$manager" || -L "$manager" ]] || ! cmp -s "$staged_script" "$manager"; then
        mv -f -- "$staged_script" "$manager" || return 1
        changed=1
    fi
    chmod 0755 "$manager" || return 1
    if [[ ! -L "$launcher" ]]; then
        ln -s "$manager" "$launcher" || return 1
        changed=1
    fi
    if [[ "$changed" == 1 ]]; then
        echo -e "${green}✓ 已安装到本机，以后输入 r 即可打开管理菜单${reset}"
    fi
)

restore_forward_service_install() {
    local work=$1 restore_active=$2 enabled_state=$3 enable_attempted=$4 failed=0
    if systemctl is-active --quiet tunnel-forward.service; then
        systemctl stop tunnel-forward.service || failed=1
    fi
    if [[ "$enable_attempted" == 1 ]]; then
        systemctl disable tunnel-forward.service >/dev/null 2>&1 || failed=1
    fi
    if [[ -e "$work/script.old" || -L "$work/script.old" ]]; then
        mv -f -- "$work/script.old" /usr/local/bin/tunnel-forward-dnat.sh || failed=1
    else
        rm -f /usr/local/bin/tunnel-forward-dnat.sh || failed=1
    fi
    if [[ -e "$work/unit.old" || -L "$work/unit.old" ]]; then
        mv -f -- "$work/unit.old" /etc/systemd/system/tunnel-forward.service || failed=1
    else
        rm -f /etc/systemd/system/tunnel-forward.service || failed=1
    fi
    systemctl daemon-reload || failed=1
    if [[ "$enable_attempted" == 1 ]]; then
        case "$enabled_state" in
        enabled) systemctl enable tunnel-forward.service >/dev/null 2>&1 || failed=1 ;;
        enabled-runtime) systemctl enable --runtime tunnel-forward.service >/dev/null 2>&1 || failed=1 ;;
        esac
    fi
    # 旧版无限循环会覆盖新规则，失败时只恢复已知使用锁和自有链的后台版本。
    if [[ "$restore_active" == 1 ]]; then
        systemctl restart tunnel-forward.service && systemctl is-active --quiet tunnel-forward.service || failed=1
    fi
    return "$failed"
}

setup_forward_service() (
    # 在停服务前确认 systemd 可用、安装目录可写并准备完整文件。
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
        echo "错误: systemd 不可用，未修改转发服务或规则" >&2
        return 1
    fi
    local staged_script staged_unit work was_active=0 safe_active=0 enabled_state exec_start
    local rollback_needed=0 enable_attempted=0 install_status=0 keep_work=0
    exec 8>"$BASE_DIR/forward-service.lock" || return 1
    flock -x 8 || return 1
    mkdir -p /usr/local/bin /etc/systemd/system || return 1
    staged_script=$(mktemp /usr/local/bin/.tunnel-forward-dnat.XXXXXX) || return 1
    staged_unit=$(mktemp /etc/systemd/system/.tunnel-forward.XXXXXX) || { rm -f -- "$staged_script"; return 1; }
    work=$(mktemp -d "$BASE_DIR/.forward-service.XXXXXX") || { rm -f -- "$staged_script" "$staged_unit"; return 1; }
    trap 'install_status=$?
        if [[ "$install_status" != 0 && "$rollback_needed" == 1 ]]; then
            if ! restore_forward_service_install "$work" "$safe_active" "$enabled_state" "$enable_attempted"; then
                keep_work=1
                echo "错误: 转发服务恢复失败，备份保留在 $work；请检查 systemctl status tunnel-forward.service" >&2
            fi
            if [[ "$was_active" == 1 && "$safe_active" == 0 ]]; then
                echo "旧版服务保持停止，以免覆盖当前转发规则；请修复后重试安装。" >&2
            fi
        fi
        rm -f -- "$staged_script" "$staged_unit"
        if [[ "$keep_work" == 0 ]]; then rm -rf -- "$work"; fi
        exit "$install_status"' EXIT
    write_forward_service_script > "$staged_script" &&
        bash -n "$staged_script" && chmod 0755 "$staged_script" || return 1
    cat > "$staged_unit" <<'SERVICEEOF' || return 1
[Unit]
Description=Port forwarding with iptables and dynamic DNS
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash /usr/local/bin/tunnel-forward-dnat.sh --forward-daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF
    chmod 0644 "$staged_unit" || return 1
    enable_ip_forward || return 1
    enabled_state=$(systemctl is-enabled tunnel-forward.service 2>/dev/null) || :
    if systemctl is-active --quiet tunnel-forward.service; then
        was_active=1
        exec_start=$(systemctl show -p ExecStart --value tunnel-forward.service) || return 1
        if [[ "$exec_start" == *--forward-daemon* ]] &&
           grep -Eq '^sync_iptables_forward[[:space:]]*\(\)' /usr/local/bin/tunnel-forward-dnat.sh; then
            safe_active=1
        fi
        if [[ "$safe_active" == 1 && "$enabled_state" == enabled ]] &&
           cmp -s "$staged_script" /usr/local/bin/tunnel-forward-dnat.sh &&
           cmp -s "$staged_unit" /etc/systemd/system/tunnel-forward.service; then
            with_forward_lock sync_iptables_forward "$FORWARD_CONF" || return 1
            echo -e "${green}✓ 转发服务已启用并运行，规则已同步${reset}"
            return 0
        fi
    fi
    if [[ -e /usr/local/bin/tunnel-forward-dnat.sh || -L /usr/local/bin/tunnel-forward-dnat.sh ]]; then
        cp -a -- /usr/local/bin/tunnel-forward-dnat.sh "$work/script.old" || return 1
    fi
    if [[ -e /etc/systemd/system/tunnel-forward.service || -L /etc/systemd/system/tunnel-forward.service ]]; then
        cp -a -- /etc/systemd/system/tunnel-forward.service "$work/unit.old" || return 1
    fi
    rollback_needed=1
    if [[ "$was_active" == 1 ]]; then
        systemctl stop tunnel-forward.service || return 1
    fi
    if ! with_forward_lock sync_iptables_forward "$FORWARD_CONF"; then
        echo "错误: 转发规则同步失败，正在恢复安装前的服务状态" >&2
        return 1
    fi
    if mv "$staged_script" /usr/local/bin/tunnel-forward-dnat.sh &&
       mv "$staged_unit" /etc/systemd/system/tunnel-forward.service &&
       systemctl daemon-reload; then
        enable_attempted=1
        if systemctl enable tunnel-forward.service &&
           systemctl restart tunnel-forward.service && systemctl is-active --quiet tunnel-forward.service; then
            echo -e "${green}✓ 转发服务已安装并启动 (域名动态解析，60 秒轮询)${reset}"
            return 0
        fi
    fi
    echo "错误: 转发服务安装或启动失败，正在恢复安装前的服务状态" >&2
    return 1
)

# ======================== 模块3: GRE 隧道端口转发 (nftables) ========================

# GRE 允许逗号分隔的单端口/范围；公共端口函数处理每一项。
normalize_gre_ports() {
    local input="$1" item result="" items=()
    [[ "$input" != ,* && "$input" != *, && "$input" != *,,* ]] || return 1
    IFS=',' read -r -a items <<< "$input"
    [ "${#items[@]}" -gt 0 ] || return 1
    for item in "${items[@]}"; do
        item=$(normalize_port_spec "$item") || return 1
        result="${result:+$result,}$item"
    done
    printf '%s\n' "$result"
}

gre_ports_overlap() {
    awk -v left="$1" -v right="$2" 'BEGIN {
        n = split(left, a, ","); m = split(right, b, ",");
        for (i = 1; i <= n; i++) {
            na = split(a[i], x, "-"); lo = x[1]; hi = (na == 2 ? x[2] : x[1]);
            for (j = 1; j <= m; j++) {
                nb = split(b[j], y, "-"); low = y[1]; high = (nb == 2 ? y[2] : y[1]);
                if (lo + 0 <= high + 0 && low + 0 <= hi + 0) exit 0;
            }
        }
        exit 1;
    }'
}

validate_gre_route() {
    local peer=$1 tun=$2 route_dev
    route_dev=$(ip -4 route get "$peer" 2>/dev/null | awk '
        NR == 1 { for (i=1; i<NF; i++) if ($i == "dev") { print $(i+1); exit } }
    ')
    if [[ "$route_dev" != "$tun" ]]; then
        echo "错误: 到 $peer 的路由出口为 ${route_dev:-不可达}，不是所选隧道 $tun；请先修正隧道网段或对端路由" >&2
        return 1
    fi
}

# ponytail: 菜单配置量小，逐对检查端口区间；大量规则时再改为排序扫描。
validate_gre_config() {
    local config="$1" line port peer proto tun _extra previous_port previous_proto index
    local ports=() protocols=() forward_ports=() forward_line forward_port
    [ -f "$config" ] || return 1
    if [ -f "$FORWARD_CONF" ]; then
        while IFS= read -r forward_line || [ -n "$forward_line" ]; do
            [ -z "$forward_line" ] && continue
            forward_port=$(normalize_port_spec "${forward_line%%>*}") || {
                echo -e "${red}错误: iptables 配置中存在无效本地端口，请先修正${reset}" >&2
                return 1
            }
            forward_ports+=("$forward_port")
        done < "$FORWARD_CONF"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if [ "$(printf '%s\n' "$line" | awk -F'|' '{print NF}')" -ne 4 ]; then
            echo -e "${red}错误: GRE 配置字段数量错误${reset}" >&2
            return 1
        fi
        IFS='|' read -r port peer proto tun _extra <<< "$line"
        port=$(normalize_gre_ports "$port") || {
            echo -e "${red}错误: GRE 端口必须在 1-65535 内，且范围起点不能大于终点${reset}" >&2
            return 1
        }
        if ! is_valid_ipv4 "$peer" || ! is_valid_tunnel_name "$tun" || [[ ! "$proto" =~ ^[123]$ ]]; then
            echo -e "${red}错误: GRE 配置中的对端、协议或隧道名称无效${reset}" >&2
            return 1
        fi
        validate_gre_route "$peer" "$tun" || return 1
        for ((index=0; index<${#ports[@]}; index++)); do
            previous_port="${ports[$index]}"; previous_proto="${protocols[$index]}"
            if { [ "$proto" = 1 ] || [ "$previous_proto" = 1 ] || [ "$proto" = "$previous_proto" ]; } && \
                    gre_ports_overlap "$port" "$previous_port"; then
                echo -e "${red}错误: GRE 转发端口 $port 与已有规则重叠，同一协议的入口端口只能指向一个目标${reset}" >&2
                return 1
            fi
        done
        for forward_port in "${forward_ports[@]}"; do
            if gre_ports_overlap "$port" "$forward_port"; then
                echo -e "${red}错误: GRE 端口 $port 与 iptables 本地端口 $forward_port 重叠${reset}" >&2
                return 1
            fi
        done
        ports+=("$port"); protocols+=("$proto")
    done < "$config"
}

# 候选文件与 GRE_CONF 位于同一目录，成功应用后才提交配置。
commit_gre_config() {
    with_forward_lock commit_gre_config_unlocked "$@"
}

commit_gre_config_unlocked() {
    local candidate="$1"
    rebuild_nftables "$candidate" || return 1
    if ! mv -- "$candidate" "$GRE_CONF"; then
        echo -e "${red}错误: GRE 配置保存失败，正在恢复原规则${reset}" >&2
        rebuild_nftables "$GRE_CONF" || echo -e "${red}错误: 原规则恢复失败，请立即检查防火墙${reset}" >&2
        return 1
    fi
}

# 调用方持有共享锁，在锁内读取最新配置，防止并发菜单覆盖其他更新。
update_gre_configuration() {
    local operation="$1" record="$2" candidate line removed=0
    candidate=$(mktemp "$BASE_DIR/.gre-config.XXXXXX") || return 1
    case "$operation" in
    add)
        if ! cat "$GRE_CONF" > "$candidate" || ! printf '\n%s\n' "$record" >> "$candidate"; then
            rm -f -- "$candidate"
            return 1
        fi
        ;;
    delete)
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$removed" = 0 ] && [ "$line" = "$record" ]; then
                removed=1
            elif ! printf '%s\n' "$line" >> "$candidate"; then
                rm -f -- "$candidate"
                return 1
            fi
        done < "$GRE_CONF"
        if [ "$removed" = 0 ]; then
            echo -e "${red}错误: 所选规则已被其他操作修改或删除，请刷新列表${reset}" >&2
            rm -f -- "$candidate"
            return 1
        fi
        ;;
    *) rm -f -- "$candidate"; return 1 ;;
    esac
    if ! commit_gre_config_unlocked "$candidate"; then
        rm -f -- "$candidate"
        return 1
    fi
}

add_gre_forward() {
    echo ""
    echo -e "${bold}=== 添加 GRE 隧道端口转发 (nftables) ===${reset}"
    local tunnels tun_name tun_type tun choice peer_ip port_input proto_choice
    local tun_arr=()
    tunnels=$(list_gre_tunnels)
    if [ -z "$tunnels" ]; then
        echo -e "${red}错误: 未检测到 GRE 隧道，请先创建隧道${reset}"
        return 1
    fi
    echo "检测到以下 GRE 隧道:"
    while IFS= read -r tun; do
        tun_arr+=("$tun")
        echo -e "  ${bold}${#tun_arr[@]})${reset} $tun  [类型: $(get_tunnel_type "$tun"), 内网IP: $(get_tunnel_ip "$tun")]"
    done <<< "$tunnels"
    if [ "${#tun_arr[@]}" -eq 1 ]; then
        tun_name="${tun_arr[0]}"
        echo -e "  自动选择: ${green}$tun_name${reset}"
    else
        read -r -p "选择隧道编号: " choice
        if [[ ! "$choice" =~ ^[1-9][0-9]*$ ]] || [ "${#choice}" -gt 6 ] || [ "$choice" -gt "${#tun_arr[@]}" ]; then
            echo -e "${red}无效选择${reset}"
            return 1
        fi
        tun_name="${tun_arr[$((choice-1))]}"
    fi
    tun_type=$(get_tunnel_type "$tun_name")
    read -r -p "对端隧道内网 IP [例如 10.10.1.2]: " peer_ip
    if ! is_valid_ipv4 "$peer_ip"; then
        echo -e "${red}错误: 无效的 IPv4 地址${reset}"
        return 1
    fi
    echo "端口格式: 443、10000-20000 或 443,8080,10000-20000"
    read -r -p "转发端口: " port_input
    port_input=$(normalize_gre_ports "$port_input") || {
        echo -e "${red}错误: 端口格式或范围无效${reset}"
        return 1
    }
    echo "转发协议: 1) TCP + UDP [默认]  2) 仅 TCP  3) 仅 UDP"
    read -r -p "选择: " proto_choice
    proto_choice=${proto_choice:-1}
    if [[ ! "$proto_choice" =~ ^[123]$ ]]; then
        echo -e "${red}错误: 协议选择无效${reset}"
        return 1
    fi
    with_forward_lock update_gre_configuration add "$port_input|$peer_ip|$proto_choice|$tun_name" || return 1
    echo -e "${green}✓ GRE 隧道转发规则添加成功${reset}"
    echo "  隧道: $tun_name ($tun_type)"
    echo "  端口: $port_input → $peer_ip（目标端口保持不变）"
}

del_gre_forward() {
    echo ""
    echo -e "${bold}=== 删除 GRE 隧道转发规则 ===${reset}"
    if [ ! -s "$GRE_CONF" ]; then
        echo -e "${yellow}当前没有 GRE 隧道转发规则${reset}"
        return 0
    fi
    local line port peer proto tun_name proto_str choice i=0
    local rules=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        IFS='|' read -r port peer proto tun_name <<< "$line"
        proto_str="TCP+UDP"
        [ "$proto" = 2 ] && proto_str="TCP"
        [ "$proto" = 3 ] && proto_str="UDP"
        i=$((i+1))
        rules+=("$line")
        echo -e "  ${bold}$i)${reset} 端口 $port → $peer [$proto_str] via $tun_name"
    done < "$GRE_CONF"
    read -r -p "请选择要删除的规则编号: " choice
    if [[ ! "$choice" =~ ^[1-9][0-9]*$ ]] || [ "${#choice}" -gt 6 ] || [ "$choice" -gt "$i" ]; then
        echo -e "${red}无效选择${reset}"
        return 1
    fi
    # 以展示时的完整记录定位；锁内重新读取文件，保留选择期间加入的规则。
    with_forward_lock update_gre_configuration delete "${rules[$((choice-1))]}" || return 1
    echo -e "${green}✓ 规则已删除${reset}"
}

list_gre_forward() {
    echo ""
    echo -e "${bold}=== 当前 GRE 隧道转发规则 ===${reset}"
    if [ ! -s "$GRE_CONF" ]; then
        echo -e "${yellow}当前没有 GRE 隧道转发规则${reset}"
        return 0
    fi
    local line port peer proto tun_name proto_str
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        IFS='|' read -r port peer proto tun_name <<< "$line"
        proto_str="TCP+UDP"
        [ "$proto" = 2 ] && proto_str="TCP"
        [ "$proto" = 3 ] && proto_str="UDP"
        echo -e "  端口 ${bold}$port${reset} → $peer [$proto_str] via $tun_name ($(get_tunnel_type "$tun_name" 2>/dev/null))"
    done < "$GRE_CONF"
    echo -e "${cyan}--- 本脚本的 nftables 规则 ---${reset}"
    nft list table ip tunnel_forward 2>/dev/null
    nft list table inet mss_clamp 2>/dev/null
}

setup_gre_nft_service() (
    local loader="$BASE_DIR/load-gre-forward.sh" unit="/etc/systemd/system/tunnel-gre-nft.service"
    local work unit_work was_enabled enable_attempted=0 rollback_failed=0 cleanup=1
    command -v systemctl >/dev/null && systemctl show-environment >/dev/null 2>&1 || {
        echo '错误: systemd 不可用，未修改 GRE 服务' >&2; return 1;
    }
    was_enabled=$(systemctl is-enabled tunnel-gre-nft.service 2>/dev/null) || :
    case "$was_enabled" in
        masked|masked-runtime) echo '错误: GRE 服务已被屏蔽，请先解除屏蔽' >&2; return 1 ;;
    esac
    mkdir -p /etc/systemd/system || return 1
    work=$(mktemp -d "$BASE_DIR/.gre-service.XXXXXX") || return 1
    unit_work=$(mktemp -d /etc/systemd/system/.tunnel-gre-nft.XXXXXX) || { rmdir "$work"; return 1; }
    trap 'if [ "$cleanup" = 1 ]; then rm -rf -- "$work" "$unit_work"; fi' EXIT
    if { [[ -e "$loader" || -L "$loader" ]] && ! cp -a -- "$loader" "$work/loader.old"; } ||
       { [[ -e "$unit" || -L "$unit" ]] && ! cp -a -- "$unit" "$unit_work/unit.old"; }; then
        return 1
    fi
    {
        printf '#!/bin/bash\nset -e\nBASE_DIR=%q\n' "$BASE_DIR"
        cat <<'LOADEREOF'
exec 9>"$BASE_DIR/forward.lock"
flock -x 9
sysctl -w net.ipv4.ip_forward=1 >/dev/null
[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]
nft -f "$BASE_DIR/nftables-gre.conf"
if [ -f "$BASE_DIR/gre-forward-filter.rules" ]; then
    {
        sed '$d' "$BASE_DIR/gre-forward-filter.rules"
        if ! iptables -w 5 -C FORWARD -j TF_GRE_FORWARD 2>/dev/null; then
            printf '%s\n' '-I FORWARD 1 -j TF_GRE_FORWARD'
        fi
        printf '%s\n' COMMIT
    } | iptables-restore -w 5 --noflush
fi
LOADEREOF
    } > "$work/loader.new" || return 1
    bash -n "$work/loader.new" && chmod 700 "$work/loader.new" || return 1
    cat > "$unit_work/unit.new" <<SVCEOF || return 1
[Unit]
Description=加载 GRE 隧道端口转发规则
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $loader
ExecReload=/bin/bash $loader

[Install]
WantedBy=multi-user.target
SVCEOF
    chmod 644 "$unit_work/unit.new" || return 1
    if mv -- "$work/loader.new" "$loader" && mv -- "$unit_work/unit.new" "$unit" && systemctl daemon-reload; then
        enable_attempted=1
        systemctl enable tunnel-gre-nft.service >/dev/null 2>&1 && return 0
    fi

    echo '错误: GRE 服务安装失败，正在恢复原服务' >&2
    if [ "$enable_attempted" = 1 ]; then
        systemctl disable tunnel-gre-nft.service >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ -e "$work/loader.old" || -L "$work/loader.old" ]]; then
        mv -- "$work/loader.old" "$loader" || rollback_failed=1
    else
        rm -f -- "$loader" || rollback_failed=1
    fi
    if [[ -e "$unit_work/unit.old" || -L "$unit_work/unit.old" ]]; then
        mv -- "$unit_work/unit.old" "$unit" || rollback_failed=1
    else
        rm -f -- "$unit" || rollback_failed=1
    fi
    systemctl daemon-reload || rollback_failed=1
    if [ "$enable_attempted" = 1 ]; then
        case "$was_enabled" in
            enabled) systemctl enable tunnel-gre-nft.service >/dev/null 2>&1 || rollback_failed=1 ;;
            enabled-runtime) systemctl enable --runtime tunnel-gre-nft.service >/dev/null 2>&1 || rollback_failed=1 ;;
        esac
    fi
    if [ "$rollback_failed" != 0 ]; then
        cleanup=0
        echo "错误: GRE 服务恢复未完成，请检查 $work 和 $unit_work 中的备份" >&2
    fi
    return 1
)

# 仅恢复本模块两个 nft 表与 TF_GRE_FORWARD 链，不触碰其他规则或默认策略。
restore_gre_snapshot() {
    local work="$1" filter_applied="$2" failed=0
    nft -f "$work/nft.rollback" || failed=1
    if [ "$filter_applied" = 1 ]; then
        iptables-restore -w 5 --noflush < "$work/filter.rollback" || failed=1
    fi
    if [ "$failed" != 0 ]; then
        echo -e "${red}错误: 防火墙回滚失败，请立即检查 GRE 转发规则${reset}" >&2
    fi
    return "$failed"
}

rebuild_nftables() {
    local config="${1:-$GRE_CONF}" work line port peer proto tun port_expr item protocol family table
    local prerouting="" postrouting="" mss="" filter_rules="" protocols items=()
    local filter_exists=0 hook_exists=0 filter_applied=0
    validate_gre_config "$config" || return 1
    command -v nft >/dev/null && command -v iptables >/dev/null && command -v iptables-restore >/dev/null || {
        echo -e "${red}错误: 请先安装 nftables 和 iptables${reset}" >&2
        return 1
    }
    work=$(mktemp -d "$BASE_DIR/.gre-rebuild.XXXXXX") || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        IFS='|' read -r port peer proto tun <<< "$line"
        port=$(normalize_gre_ports "$port") || { rm -rf -- "$work"; return 1; }
        port_expr="$port"
        [[ "$port" == *,* ]] && port_expr="{ $port }"
        protocols="tcp udp"
        [ "$proto" = 2 ] && protocols="tcp"
        [ "$proto" = 3 ] && protocols="udp"
        for protocol in $protocols; do
            prerouting+="        fib daddr type local $protocol dport $port_expr dnat to $peer\n"
            postrouting+="        ct status dnat ip daddr $peer oifname \"$tun\" $protocol dport $port_expr masquerade\n"
            IFS=',' read -r -a items <<< "$port"
            for item in "${items[@]}"; do
                item=${item/-/:}
                filter_rules+="-A TF_GRE_FORWARD -p $protocol -o $tun -d $peer --dport $item -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport $item -j ACCEPT\n"
                filter_rules+="-A TF_GRE_FORWARD -p $protocol -i $tun -s $peer --sport $item -m conntrack --ctstate DNAT --ctdir REPLY --ctorigdstport $item -j ACCEPT\n"
            done
            if [ "$protocol" = tcp ]; then
                mss+="        ct status dnat oifname \"$tun\" ip daddr $peer tcp dport $port_expr tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu\n"
                mss+="        ct status dnat iifname \"$tun\" ip saddr $peer tcp sport $port_expr tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu\n"
            fi
        done
    done < "$config"
    cat > "$work/nft.new" <<NFTEOF || { rm -rf -- "$work"; return 1; }
#!/usr/sbin/nft -f
# 本文件以一个 nft 事务替换脚本自己的表；可重复加载。
add table ip tunnel_forward
delete table ip tunnel_forward
add table inet mss_clamp
delete table inet mss_clamp
table ip tunnel_forward {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
$(printf '%b' "$prerouting")
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
$(printf '%b' "$postrouting")
    }
}
table inet mss_clamp {
    chain forward {
        type filter hook forward priority mangle; policy accept;
$(printf '%b' "$mss")
    }
}
NFTEOF
    {
        printf '%s\n' '*filter' ':TF_GRE_FORWARD - [0:0]' '-F TF_GRE_FORWARD'
        printf '%b' "$filter_rules"
        printf '%s\n' COMMIT
    } > "$work/filter.new"
    # 同一 restore 批次创建链并插入入口；持久化文件不包含入口，服务启动时检查一次。
    sed '$d' "$work/filter.new" > "$work/filter.apply"
    if iptables -w 5 -C FORWARD -j TF_GRE_FORWARD 2>/dev/null; then
        hook_exists=1
    else
        printf '%s\n' '-I FORWARD 1 -j TF_GRE_FORWARD' >> "$work/filter.apply"
    fi
    printf '%s\n' COMMIT >> "$work/filter.apply"
    if ! nft -c -f "$work/nft.new" || ! iptables-restore -w 5 --noflush --test < "$work/filter.apply"; then
        echo -e "${red}错误: GRE 规则校验失败，原规则保持不变${reset}" >&2
        rm -rf -- "$work"
        return 1
    fi
    # 保存内核当前状态，用于跨 nft/iptables 后端或持久化失败时恢复。
    : > "$work/nft.rollback"
    for family in ip inet; do
        table=tunnel_forward; [ "$family" = inet ] && table=mss_clamp
        printf 'add table %s %s\ndelete table %s %s\n' "$family" "$table" "$family" "$table" >> "$work/nft.rollback"
        if nft list table "$family" "$table" > "$work/table.old" 2>/dev/null; then
            cat "$work/table.old" >> "$work/nft.rollback"
        fi
    done
    if iptables -w 5 -S TF_GRE_FORWARD > "$work/filter.old" 2>/dev/null; then
        filter_exists=1
    fi
    {
        printf '%s\n' '*filter' ':TF_GRE_FORWARD - [0:0]' '-F TF_GRE_FORWARD'
        if [ "$filter_exists" = 1 ]; then
            sed -n '/^-A TF_GRE_FORWARD /p' "$work/filter.old"
        fi
        [ "$hook_exists" = 1 ] || printf '%s\n' '-D FORWARD -j TF_GRE_FORWARD'
        [ "$filter_exists" = 1 ] || printf '%s\n' '-X TF_GRE_FORWARD'
        printf '%s\n' COMMIT
    } > "$work/filter.rollback"
    for item in nftables-gre.conf gre-forward-filter.rules; do
        if [ -e "$BASE_DIR/$item" ] && ! cp -p -- "$BASE_DIR/$item" "$work/$item.old"; then
            rm -rf -- "$work"
            return 1
        fi
    done
    if ! enable_ip_forward || ! nft -f "$work/nft.new"; then
        echo -e "${red}错误: GRE 规则应用失败，原规则保持不变${reset}" >&2
        rm -rf -- "$work"
        return 1
    fi
    if ! iptables-restore -w 5 --noflush < "$work/filter.apply"; then
        restore_gre_snapshot "$work" 0
        rm -rf -- "$work"
        return 1
    fi
    filter_applied=1
    if ! mv -- "$work/nft.new" "$BASE_DIR/nftables-gre.conf" || \
            ! mv -- "$work/filter.new" "$BASE_DIR/gre-forward-filter.rules" || ! setup_gre_nft_service; then
        echo -e "${red}错误: GRE 持久化失败，正在恢复原规则${reset}" >&2
        restore_gre_snapshot "$work" "$filter_applied"
        for item in nftables-gre.conf gre-forward-filter.rules; do
            if [ -e "$work/$item.old" ]; then
                cp -p -- "$work/$item.old" "$BASE_DIR/$item" || echo "错误: 无法恢复 $item" >&2
            else
                rm -f -- "$BASE_DIR/$item"
            fi
        done
        rm -rf -- "$work"
        return 1
    fi
    rm -rf -- "$work"
    echo -e "${green}✓ GRE 规则已应用并持久化${reset}"
}

# ======================== 模块4: 一键部署 ========================

one_key_transit() {
    echo ""
    echo -e "${bold}=== 一键部署转发机 (隧道 + 端口转发) ===${reset}"
    echo ""
    echo "此向导将引导你:"
    echo "  1. 创建 GRE 隧道"
    echo "  2. 配置端口转发"
    echo "  3. 根据所选方式保存隧道及转发配置"
    echo ""

    echo -e "${yellow}选择隧道类型:${reset}"
    echo "  1) IPv4 GRE"
    echo "  2) IPv6 GRE (ip6gre)"
    echo -n "选择 [默认: 2]: "; read tun_choice
    tun_choice=${tun_choice:-2}

    case $tun_choice in
    1)  create_ipv4_gre || return 1 ;;
    2)  create_ipv6_gre || return 1 ;;
    *)  echo -e "${red}无效选择${reset}"; return 1 ;;
    esac

    echo ""
    echo -e "${yellow}是否立即配置端口转发？[Y/n]${reset}"; read do_forward
    if [[ "$do_forward" != "n" && "$do_forward" != "N" ]]; then
        while true; do
            add_gre_forward || return 1
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
        echo "    5) 添加转发规则 (单端口 / 等长端口范围)"
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
        echo -n "请输入编号: "; read -r action || return 0

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
        read -r || return 0
    done
}

# ======================== 入口 ========================
initialize() {
    [[ "$(uname -s)" == Linux ]] || { echo '错误: 此脚本仅支持 Linux' >&2; return 1; }
    (( BASH_VERSINFO[0] >= 4 )) || { echo '错误: 需要 Bash 4 或更新版本' >&2; return 1; }
    [[ "$EUID" -eq 0 ]] || { echo '错误: 请以 root 权限运行' >&2; return 1; }
    umask 077
    mkdir -p "$BASE_DIR" || return 1
    touch "$FORWARD_CONF" "$GRE_CONF" "$TUNNEL_CONF" || return 1
    local file
    for file in "$GRE_CONF" "$TUNNEL_CONF"; do
        if grep -q '@NONE' "$file"; then
            sed -i 's/@NONE//g' "$file" || return 1
        fi
    done
    check_and_install iptables iptables iptables || return 1
    check_and_install iptables-save iptables iptables || return 1
    check_and_install iptables-restore iptables iptables || return 1
    check_and_install nft nftables nftables || return 1
    check_and_install ip iproute2 iproute || return 1
    check_and_install flock util-linux util-linux || return 1
    check_and_install modprobe kmod kmod || return 1
}

run_tunnel_forward() {
    case ${1:-} in
    ''|--forward-daemon)
        initialize || return 1
        if [[ ${1:-} == --forward-daemon ]]; then
            run_forward_daemon
        else
            install_local_command || return 1
            main_menu
        fi
        ;;
    *) echo "用法: bash $0 [--forward-daemon]" >&2; return 2 ;;
    esac
}

# source 时只加载函数，便于隔离检查；直接运行才初始化系统。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_tunnel_forward "$@"
fi
