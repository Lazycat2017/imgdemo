#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="tcp_tuning.sh"

# managed files
TUNE_SYSCTL_FILE="/etc/sysctl.d/99-dmit-tcp-tune.conf"

# colors
c_reset="\033[0m"
c_green="\033[32m"
c_yellow="\033[33m"
c_cyan="\033[36m"
c_white="\033[37m"
c_bold="\033[1m"
c_dim="\033[2m"

ok()   { echo -e "${c_green}✔${c_reset} $*"; }
info() { echo -e "${c_cyan}➜${c_reset} $*"; }
warn() { echo -e "${c_yellow}⚠${c_reset} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    warn "请用 root 运行：sudo ./${SCRIPT_NAME}"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

write_file() {
  local path="$1"
  local content="$2"
  umask 022
  mkdir -p "$(dirname "$path")"
  printf "%s\n" "$content" > "$path"
}

sysctl_apply_all() { sysctl --system >/dev/null 2>&1 || true; }

# ---------------- BBR / TCP 调优 ----------------
bbr_check() {
  echo "================ BBR 检测 ================"
  echo "kernel=$(uname -r)"
  local avail cur
  avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")"
  cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")"
  echo "当前=${cur}"
  echo "可用=${avail:-N/A}"
  if echo " $avail " | grep -q " bbr "; then
    ok "支持 bbr"
  else
    warn "未看到 bbr（可能内核不含/模块不可用）"
  fi
  echo "=========================================="
}

tcp_tune_apply() {
  info "TCP：一键调优（BBR + FQ + 常用参数）"
  have_cmd modprobe && modprobe tcp_bbr >/dev/null 2>&1 || true
  write_file "$TUNE_SYSCTL_FILE" \
"net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.netdev_max_backlog=16384
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192

net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1"
  sysctl_apply_all
  ok "已应用 TCP 调优"
  bbr_check
}

tcp_restore_default() {
  info "TCP：恢复系统默认（CUBIC + pfifo_fast）"
  rm -f "$TUNE_SYSCTL_FILE" || true
  sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl_apply_all
  ok "已恢复 TCP 默认"
}

# ---------------- 主菜单 ----------------
menu() {
  while true; do
    echo
    echo -e "${c_bold}${c_white}TCP/BBR 调优工具${c_reset}"
    echo -e "  ${c_cyan}1${c_reset}) 一键 TCP 调优（BBR+FQ）"
    echo -e "  ${c_cyan}2${c_reset}) 恢复 TCP 默认（CUBIC）"
    echo -e "  ${c_cyan}3${c_reset}) 检测系统是否支持 BBR"
    echo -e "  ${c_cyan}0${c_reset}) 退出"
    echo
    read -r -p "选择> " choice
    case "$choice" in
      1) tcp_tune_apply ;;
      2) tcp_restore_default ;;
      3) bbr_check ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
    echo
    read -r -p "按回车继续..." _
  done
}

main() {
  need_root
  menu
}

main "$@"
