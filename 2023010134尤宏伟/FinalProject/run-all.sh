#!/bin/bash
# ============================================================
# run-all.sh — WSL2 一键运行完整实验
# 功能：清理 → 安装依赖 → 搭建网络 → 防火墙 → VPN → 测试
# 运行环境：WSL2 Ubuntu，需要 sudo
# ============================================================

# 不用 set -e，让各步骤自行处理错误

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${BLUE}============================================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}============================================================${NC}"; }

if [ "$EUID" -ne 0 ]; then
  error "请使用 sudo 运行此脚本"
  exit 1
fi

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORK_DIR"

# ---- 0. 清理旧环境 ----
step "步骤 0/6: 清理旧环境"
bash "$WORK_DIR/cleanup.sh" || warn "清理有部分失败，继续..."

# ---- 1. 检查关键依赖 ----
step "步骤 1/6: 检查关键依赖"
MISSING=0
for cmd in ip iptables wg python3 curl tcpdump; do
    if ! command -v $cmd &>/dev/null; then
        error "缺少命令: $cmd"
        MISSING=1
    else
        info "$cmd ✓"
    fi
done

if [ "$MISSING" -eq 1 ]; then
    error "有依赖缺失，请先运行: sudo bash wsl2-install.sh"
    exit 1
fi

# ---- 2. 切换 iptables 到 legacy 后端（WSL2 兼容）----
info "切换 iptables 到 legacy 后端..."
update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || warn "iptables-legacy 切换失败或已是 legacy"
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || warn "ip6tables-legacy 切换失败或已是 legacy"

# ---- 3. 搭建网络 ----
step "步骤 2/6: 搭建网络环境"
bash "$WORK_DIR/setup.sh"

# ---- 4. 配置防火墙 ----
step "步骤 3/6: 配置防火墙"
bash "$WORK_DIR/firewall.sh"

# ---- 5. 配置 VPN ----
step "步骤 4/6: 配置 WireGuard VPN"
bash "$WORK_DIR/vpn-setup.sh"

# ---- 6. 运行测试 ----
step "步骤 5/6: 运行完整测试"
bash "$WORK_DIR/test.sh"

# ---- 7. 完成提示 ----
step "步骤 6/6: 完成"
info "全部步骤已执行完毕"
info "请按照 screenshots/截图清单.md 截取 20 张截图"
info "如需重新运行，请先: sudo bash cleanup.sh"
info "如需清理环境，请: sudo bash cleanup.sh"
