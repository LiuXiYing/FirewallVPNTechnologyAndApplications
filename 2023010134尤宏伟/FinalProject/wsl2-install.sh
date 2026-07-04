#!/bin/bash
# ============================================================
# wsl2-install.sh — WSL2 Ubuntu 26.04 环境依赖安装脚本
# 功能：自动安装 iproute2、iptables、wireguard-tools、conntrack 等依赖
# 运行环境：WSL2 + Ubuntu 26.04 LTS
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  error "请使用 sudo 运行此脚本"
  exit 1
fi

info "当前系统信息:"
cat /etc/os-release | head -5
uname -r

info "更新 apt 源..."
apt update

info "启用 universe 仓库..."
apt install -y software-properties-common
add-apt-repository universe -y
apt update

info "安装基础依赖..."
apt install -y \
  iproute2 \
  iptables \
  python3 \
  curl \
  tcpdump \
  resolvconf

info "安装 WireGuard 工具..."
# WSL2 常见情况：内核模块不可用，需要 wireguard-go 用户态实现
# 因此同时安装 wireguard-tools 和 wireguard-go，确保两套方案都可用
if apt-cache show wireguard-tools >/dev/null 2>&1; then
    apt install -y wireguard-tools
fi
if apt-cache show wireguard >/dev/null 2>&1; then
    apt install -y wireguard
fi
# wireguard-go 是 WSL2 没有内核模块时的关键 fallback
if apt-cache show wireguard-go >/dev/null 2>&1; then
    apt install -y wireguard-go
else
    warn "未找到 wireguard-go 包，如果内核模块也不可用则 VPN 无法建立"
fi

info "安装 conntrack..."
if apt-cache show conntrack >/dev/null 2>&1; then
    apt install -y conntrack
elif apt-cache show conntrack-tools >/dev/null 2>&1; then
    apt install -y conntrack-tools
else
    warn "未找到 conntrack 包，跳过（仅影响 conntrack 命令，不影响 iptables）"
fi

info "检查是否启用 systemd..."
if systemctl --version >/dev/null 2>&1; then
    info "systemd 已启用，journalctl 可用"
else
    warn "systemd 未启用。如需 journalctl 查看日志，请在 /etc/wsl.conf 中设置 [boot] systemd=true"
fi

info "验证安装..."
for cmd in ip iptables wg python3 curl tcpdump; do
    if command -v $cmd &>/dev/null; then
        info "  $cmd: $(command -v $cmd)"
    else
        warn "  $cmd: 未安装"
    fi
done

info "检查 WireGuard 内核模块..."
if modprobe wireguard 2>/dev/null; then
    info "  WireGuard 内核模块可用"
else
    warn "  WireGuard 内核模块不可用，将依赖 wireguard-go 用户态实现"
    if ! command -v wireguard-go &>/dev/null; then
        error "  wireguard-go 也未安装，VPN 可能无法建立"
        exit 1
    fi
fi

info "切换 iptables 到 legacy 后端（兼容 WSL2）..."
if command -v update-alternatives &>/dev/null; then
    # iptables-legacy 在 WSL2 中更稳定，避免 nftables 后端的兼容性问题
    update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || \
        warn "  iptables-legacy 不可用，保持当前后端"
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || \
        warn "  ip6tables-legacy 不可用，保持当前后端"
    info "  iptables 后端: $(iptables --version)"
else
    warn "  update-alternatives 不可用，跳过 iptables 后端切换"
fi

info "依赖安装完成！"
