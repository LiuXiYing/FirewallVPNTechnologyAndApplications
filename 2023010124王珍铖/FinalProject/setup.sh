#!/bin/bash
# setup.sh - 企业网络安全架构拓扑搭建脚本
# 可重复运行，包含错误处理
# 学号：2022010124  姓名：王珍铖

set -e

# ============================================
# 颜色定义（使输出更美观）
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  企业网络安全架构 - 拓扑搭建脚本${NC}"
echo -e "${BLUE}=========================================${NC}"

# ============================================
# 第一部分：清理旧环境
# ============================================
echo ""
echo -e "${YELLOW}[1/7] 清理现有环境...${NC}"

# 停止 WireGuard 隧道
echo "  - 停止 WireGuard 隧道..."
sudo ip netns exec fw wg-quick down wg0 2>/dev/null || true
sudo ip netns exec remote wg-quick down wg0 2>/dev/null || true

# 停止 Python HTTP 服务
echo "  - 停止 HTTP 服务..."
sudo pkill -f "python3 -m http.server" 2>/dev/null || true

# 删除所有 namespace
echo "  - 删除旧的 namespace..."
for ns in fw office guest dmz internet remote; do
    sudo ip netns del $ns 2>/dev/null || true
done

# 删除可能残留的 veth 接口
echo "  - 清理残留 veth 接口..."
for veth in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet veth-fw-remote \
            veth-office veth-guest veth-dmz veth-inet veth-remote; do
    sudo ip link del $veth 2>/dev/null || true
done

sleep 1
echo -e "  ${GREEN}✅ 清理完成${NC}"

# ============================================
# 第二部分：创建 namespace
# ============================================
echo ""
echo -e "${YELLOW}[2/7] 创建 6 个 network namespace...${NC}"

for ns in fw office guest dmz internet remote; do
    sudo ip netns add $ns
    echo -e "  ${GREEN}✅ 创建 $ns${NC}"
done

echo -e "  ${GREEN}✅ 所有 namespace 创建完成${NC}"

# ============================================
# 第三部分：创建 veth 对并配置
# ============================================
echo ""
echo -e "${YELLOW}[3/7] 创建 veth 对并配置 IP 地址...${NC}"

# 3.1 office 连接 (10.20.0.0/24)
echo -e "  - ${BLUE}配置 office 网段 (10.20.0.0/24)...${NC}"
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# 3.2 guest 连接 (10.30.0.0/24)
echo -e "  - ${BLUE}配置 guest 网段 (10.30.0.0/24)...${NC}"
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# 3.3 dmz 连接 (10.40.0.0/24)
echo -e "  - ${BLUE}配置 dmz 网段 (10.40.0.0/24)...${NC}"
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# 3.4 internet 连接 (203.0.113.0/24)
echo -e "  - ${BLUE}配置 internet 网段 (203.0.113.0/24)...${NC}"
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# 3.5 fw-remote 连接（用于 VPN 跨命名空间通信）
echo -e "  - ${BLUE}配置 fw-remote 连接 (10.100.0.0/24)...${NC}"
sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote
sudo ip netns exec fw ip addr add 10.100.0.1/24 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
sudo ip netns exec remote ip addr add 10.100.0.2/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

echo -e "  ${GREEN}✅ 所有 veth 对配置完成${NC}"

# ============================================
# 第四部分：配置路由
# ============================================
echo ""
echo -e "${YELLOW}[4/7] 配置路由...${NC}"

sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
# remote 添加路由，使 10.10.10.1 可通过 veth-remote 到达
sudo ip netns exec remote ip route add 10.10.10.1/32 via 10.100.0.1

echo -e "  ${GREEN}✅ 路由配置完成${NC}"

# ============================================
# 第五部分：开启 IP 转发
# ============================================
echo ""
echo -e "${YELLOW}[5/7] 开启 IP 转发...${NC}"

sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo -e "  ${GREEN}✅ IP 转发已开启${NC}"

# ============================================
# 第六部分：验证连通性
# ============================================
echo ""
echo -e "${YELLOW}[6/7] 验证连通性...${NC}"

test_ping() {
    local ns=$1
    local target=$2
    local name=$3
    echo -n "  - $name -> $target: "
    if sudo ip netns exec $ns ping -c 2 $target > /dev/null 2>&1; then
        echo -e "${GREEN}✅ 成功${NC}"
    else
        echo -e "${RED}❌ 失败${NC}"
    fi
}

test_ping office 10.20.0.1 "office"
test_ping guest 10.30.0.1 "guest"
test_ping dmz 10.40.0.1 "dmz"
test_ping internet 203.0.113.1 "internet"
test_ping remote 10.100.0.1 "remote"

# ============================================
# 第七部分：显示配置信息
# ============================================
echo ""
echo -e "${YELLOW}[7/7] 配置信息汇总${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "${BLUE}📋 地址规划表：${NC}"
echo "  ┌─────────────┬───────────────┬───────────────┐"
echo "  │ 区域        │ fw 侧地址     │ 主机地址      │"
echo "  ├─────────────┼───────────────┼───────────────┤"
echo "  │ office      │ 10.20.0.1/24  │ 10.20.0.2/24  │"
echo "  │ guest       │ 10.30.0.1/24  │ 10.30.0.2/24  │"
echo "  │ dmz         │ 10.40.0.1/24  │ 10.40.0.2/24  │"
echo "  │ internet    │ 203.0.113.1/24│ 203.0.113.10/24│"
echo "  │ vpn         │ 10.10.10.1/24 │ 10.10.10.2/24 │"
echo "  │ fw-remote   │ 10.100.0.1/24 │ 10.100.0.2/24 │"
echo "  └─────────────┴───────────────┴───────────────┘"
echo ""
echo -e "${BLUE}📌 namespace 列表：${NC}"
sudo ip netns list
echo ""
echo -e "${BLUE}📌 veth 接口列表（fw 端）：${NC}"
sudo ip netns exec fw ip link show | grep -E "veth-fw|wg0" || echo "  暂无 wg0 接口"
echo ""
echo -e "${BLUE}📌 路由表（fw）：${NC}"
sudo ip netns exec fw ip route
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  ✅ 拓扑搭建完成！${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "提示："
echo "  - 下一步请运行 firewall.sh 配置防火墙规则"
echo "  - 查看连通性测试结果请参考 01-topology.png"
