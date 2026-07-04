#!/bin/bash
# setup.sh - 企业网络安全架构拓扑搭建脚本
# 功能：创建6个namespace、5对veth、配置IP和路由
# 特点：可重复运行，包含完整清理逻辑
# 作者：[学号] [姓名]
# 日期：2026-06-29

set -e

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "========================================="
echo "  企业网络安全架构 - 拓扑搭建脚本"
echo "  作者：[学号] [姓名]"
echo "  日期：2026-06-29"
echo "========================================="

# ---------- 1. 清理已有环境 ----------
echo -e "${YELLOW}[1/8] 清理已有环境...${NC}"

# 停止WireGuard接口
echo "  停止WireGuard接口..."
sudo ip netns exec fw wg-quick down wg0 2>/dev/null || true
sudo ip netns exec remote wg-quick down wg0 2>/dev/null || true

# 删除所有namespace
echo "  删除namespace..."
for ns in fw office guest dmz internet remote; do
    sudo ip netns del $ns 2>/dev/null || true
done

# 清理残留veth
echo "  清理残留veth..."
for veth in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet \
             veth-office veth-guest veth-dmz veth-inet; do
    sudo ip link del $veth 2>/dev/null || true
done

# 清理WireGuard配置
sudo rm -rf /etc/wireguard/fw /etc/wireguard/remote 2>/dev/null || true
sudo rm -f fw.key fw.pub remote.key remote.pub 2>/dev/null || true

echo "  清理完成"

# ---------- 2. 创建namespace ----------
echo -e "${YELLOW}[2/8] 创建6个namespace...${NC}"
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
echo "  已创建: fw, office, guest, dmz, internet, remote"

# ---------- 3. 创建veth对 ----------
echo -e "${YELLOW}[3/8] 创建veth对...${NC}"

# office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
echo "  ✓ office连接"

# guest连接
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
echo "  ✓ guest连接"

# dmz连接
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
echo "  ✓ dmz连接"

# internet连接
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
echo "  ✓ internet连接"

# ---------- 4. 配置IP地址 ----------
echo -e "${YELLOW}[4/8] 配置IP地址...${NC}"

# fw接口配置
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
echo "  fw: 10.20.0.1, 10.30.0.1, 10.40.0.1, 203.0.113.1"

# 各主机配置
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
echo "  office: 10.20.0.2, guest: 10.30.0.2, dmz: 10.40.0.2, internet: 203.0.113.10"

# ---------- 5. 启用所有接口 ----------
echo -e "${YELLOW}[5/8] 启用接口和loopback...${NC}"

# fw接口启用
sudo ip netns exec fw ip link set lo up
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec fw ip link set veth-fw-inet up

# 各主机接口启用
for ns in office guest dmz internet remote; do
    sudo ip netns exec $ns ip link set lo up
done

sudo ip netns exec office ip link set veth-office up
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec internet ip link set veth-inet up
echo "  所有接口已启用"

# ---------- 6. 配置路由 ----------
echo -e "${YELLOW}[6/8] 配置默认路由...${NC}"

sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
echo "  默认路由配置完成"

# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "  fw IP转发已开启"

# ---------- 7. 准备WireGuard目录 ----------
echo -e "${YELLOW}[7/8] 准备WireGuard配置目录...${NC}"
sudo mkdir -p /etc/wireguard/fw /etc/wireguard/remote
sudo chmod 700 /etc/wireguard/fw /etc/wireguard/remote
echo "  目录已创建: /etc/wireguard/fw, /etc/wireguard/remote"

# ---------- 8. 验证连通性 ----------
echo -e "${YELLOW}[8/8] 验证连通性...${NC}"

test_ping() {
    local ns=$1
    local target=$2
    local desc=$3
    if sudo ip netns exec $ns ping -c 2 -W 1 $target > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $desc -> $target"
        return 0
    else
        echo -e "  ${RED}✗${NC} $desc -> $target (FAILED)"
        return 1
    fi
}

test_ping office 10.20.0.1 "office->fw"
test_ping guest 10.30.0.1 "guest->fw"
test_ping dmz 10.40.0.1 "dmz->fw"
test_ping internet 203.0.113.1 "internet->fw"

# 额外测试：fw ping各主机
echo ""
echo "  fw ping各主机:"
sudo ip netns exec fw ping -c 1 10.20.0.2 > /dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} fw->office"
sudo ip netns exec fw ping -c 1 10.30.0.2 > /dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} fw->guest"
sudo ip netns exec fw ping -c 1 10.40.0.2 > /dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} fw->dmz"
sudo ip netns exec fw ping -c 1 203.0.113.10 > /dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} fw->internet"

echo ""
echo -e "${GREEN}========================================="
echo "  ✓ 拓扑搭建完成！"
echo "=========================================${NC}"
echo ""
echo "各namespace IP地址:"
echo "  ${BLUE}office${NC}:  10.20.0.2/24     (gw: 10.20.0.1)"
echo "  ${BLUE}guest${NC}:   10.30.0.2/24     (gw: 10.30.0.1)"
echo "  ${BLUE}dmz${NC}:     10.40.0.2/24     (gw: 10.40.0.1)"
echo "  ${BLUE}internet${NC}: 203.0.113.10/24 (gw: 203.0.113.1)"
echo "  ${BLUE}fw${NC}:      多接口网关 (10.20.0.1, 10.30.0.1, 10.40.0.1, 203.0.113.1)"
echo "  ${BLUE}remote${NC}:  暂未配置IP (等待VPN)"
echo ""
echo "下一步: 执行 ./firewall.sh 配置防火墙规则"
