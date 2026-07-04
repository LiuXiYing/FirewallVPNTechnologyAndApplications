#!/bin/bash
# ============================================================
# setup.sh - 企业网络安全架构拓扑搭建脚本（Kali Linux 版本）
# ============================================================
# 功能：创建6个网络namespace，配置veth对、IP地址、路由、WireGuard VPN
# 要求：可重复运行（先清理再创建）
# ============================================================

set -e

echo "========================================="
echo "  企业网络安全架构 - 拓扑搭建脚本"
echo "  环境：Kali Linux"
echo "========================================="

# ---------- 0. 清理旧的namespace ----------
echo "[0/6] 清理旧的namespace和veth..."
for ns in fw office guest dmz internet remote; do
    sudo ip netns del $ns 2>/dev/null || true
done

# 清理可能残留的veth对（在主namespace中）
for veth in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet veth-remote veth-vpn-fw veth-rem-host; do
    sudo ip link del $veth 2>/dev/null || true
done

echo "  清理完成。"

# ---------- 1. 创建6个namespace ----------
echo "[1/6] 创建6个网络namespace..."
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
echo "  6个namespace创建完成：fw office guest dmz internet remote"

# ---------- 2. 创建6对veth并分配 ----------
echo "[2/6] 创建veth对并分配到各namespace..."

# --- office连接 ---
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

# --- guest连接 ---
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest

# --- dmz连接 ---
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz

# --- internet连接 ---
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet

# --- remote连接（remote通过veth连接到主namespace，模拟互联网连接）---
sudo ip link add veth-remote type veth peer name veth-rem-host
sudo ip link set veth-remote netns remote
# veth-rem-host 留在主namespace，模拟remote侧的互联网网关

# --- VPN专用veth：连接主namespace和fw，让remote能到达fw的WireGuard endpoint ---
# fw端 IP: 198.51.100.1，主namespace端 IP: 198.51.100.2
sudo ip link add veth-vpn-fw type veth peer name veth-vpn-host
sudo ip link set veth-vpn-fw netns fw
# veth-vpn-host 留在主namespace

echo "  6对veth创建并分配完成。"

# ---------- 3. 配置IP地址 ----------
echo "[3/6] 配置各接口IP地址..."

# --- fw端接口 ---
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up

sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up

sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up

sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up

# fw的VPN专用接口（连接主namespace的veth）
sudo ip netns exec fw ip addr add 198.51.100.1/30 dev veth-vpn-fw
sudo ip netns exec fw ip link set veth-vpn-fw up

sudo ip netns exec fw ip link set lo up

# --- office端 ---
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# --- guest端 ---
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# --- dmz端 ---
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# --- internet端 ---
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# --- remote端（外网地址，用于模拟远程员工在互联网上）---
sudo ip netns exec remote ip addr add 192.0.2.10/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

# --- remote的主机端（模拟互联网网关）---
sudo ip addr add 192.0.2.1/24 dev veth-rem-host
sudo ip link set veth-rem-host up

# --- VPN专用veth主机端 ---
sudo ip addr add 198.51.100.2/30 dev veth-vpn-host
sudo ip link set veth-vpn-host up

echo "  IP地址配置完成。"

# ---------- 4. 配置路由 ----------
echo "[4/6] 配置路由..."

# 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1

# internet默认路由指向fw的外网接口
sudo ip netns exec internet ip route add default via 203.0.113.1

# remote默认路由指向主namespace（模拟互联网出口）
sudo ip netns exec remote ip route add default via 192.0.2.1

# 注：veth-vpn-host 配置 198.51.100.2/30 后，内核已自动添加 198.51.100.0/30 的直连路由，无需手动添加

# fw：添加回程路由，让 fw 知道 192.0.2.0/24 网段通过 VPN veth 走主namespace
sudo ip netns exec fw ip route add 192.0.2.0/24 via 198.51.100.2

# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

# 主namespace开启转发
sudo sysctl -w net.ipv4.ip_forward=1

# 主namespace：放通 remote 和 fw 之间的VPN转发（Docker等可能把FORWARD默认设为DROP）
sudo iptables -A FORWARD -i veth-rem-host -o veth-vpn-host -j ACCEPT
sudo iptables -A FORWARD -i veth-vpn-host -o veth-rem-host -j ACCEPT

echo "  路由配置完成。"

# ---------- 5. 配置WireGuard VPN ----------
echo "[5/6] 配置WireGuard VPN隧道..."

# WireGuard密钥（预生成的固定密钥对）
FW_PRIVATE_KEY="iF8yV/afXqu4yO/D10hST0Ot6PbUoQGe0Iz6wFikY1s="
REMOTE_PRIVATE_KEY="4P9aY5tlJuAANPwfnVDD2NNFPOXPecARLpe7KiYQlnI="
REMOTE_PUBLIC_KEY="2RYxFzmdX47S0uva+WSGVE+xeCtE3Vsy9xOS6Y5hEw8="
FW_PUBLIC_KEY="wP+kEw/HTP3+MC/di4G5vT+inKmu7kVJQbYwTCfGt3g="

# 用临时文件传递私钥（避免进程替换在 netns exec 中失效）
echo "$FW_PRIVATE_KEY" | sudo tee /tmp/wg-fw-key > /dev/null
echo "$REMOTE_PRIVATE_KEY" | sudo tee /tmp/wg-remote-key > /dev/null

# --- fw 侧 WireGuard 配置 ---
sudo ip netns exec fw ip link add wg0 type wireguard
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev wg0

# 设置 fw 私钥和监听端口
sudo ip netns exec fw wg set wg0 private-key /tmp/wg-fw-key listen-port 51820

# 添加 remote 对等体
sudo ip netns exec fw wg set wg0 peer "$REMOTE_PUBLIC_KEY" allowed-ips 10.10.10.2/32,192.0.2.0/24 persistent-keepalive 25

sudo ip netns exec fw ip link set wg0 up

# --- remote 侧 WireGuard 配置 ---
sudo ip netns exec remote ip link add wg0 type wireguard
sudo ip netns exec remote ip addr add 10.10.10.2/24 dev wg0

# 设置 remote 私钥
sudo ip netns exec remote wg set wg0 private-key /tmp/wg-remote-key

# 添加 fw 对等体，endpoint = 198.51.100.1（fw的VPN veth接口）
# remote -> 主namespace(192.0.2.1) -> veth-vpn-host -> veth-vpn-fw(198.51.100.1) -> fw
sudo ip netns exec remote wg set wg0 peer "$FW_PUBLIC_KEY" endpoint 198.51.100.1:51820 allowed-ips 10.20.0.0/24,10.40.0.0/24,10.10.10.0/24 persistent-keepalive 25

sudo ip netns exec remote ip link set wg0 up

# 清理临时密钥文件
sudo rm -f /tmp/wg-fw-key /tmp/wg-remote-key

# fw 添加路由：去往 10.10.10.0/24（VPN隧道网段）走 wg0
sudo ip netns exec fw ip route add 10.10.10.0/24 dev wg0 2>/dev/null || true

# remote 添加路由：去往内部网络走 wg0（WireGuard隧道）
sudo ip netns exec remote ip route add 10.20.0.0/24 dev wg0 2>/dev/null || true
sudo ip netns exec remote ip route add 10.40.0.0/24 dev wg0 2>/dev/null || true

echo "  WireGuard VPN 配置完成。"

# ---------- 6. 验证连通性 ----------
echo "[6/6] 验证连通性..."
echo ""

# 测试函数
test_ping() {
    local ns=$1
    local target=$2
    local desc=$3
    echo -n "  [$ns -> $target] $desc ... "
    if sudo ip netns exec $ns ping -c 2 -W 2 $target > /dev/null 2>&1; then
        echo "✓ 通过"
    else
        echo "✗ 失败"
    fi
}

echo "--- 基础连通性 ---"
test_ping office 10.20.0.1 "office ping fw"
test_ping guest 10.30.0.1 "guest ping fw"
test_ping dmz 10.40.0.1 "dmz ping fw"
test_ping internet 203.0.113.1 "internet ping fw"
test_ping remote 192.0.2.1 "remote ping 外网网关"

echo ""
echo "--- VPN隧道连通性 ---"
test_ping remote 198.51.100.1 "remote ping fw VPN接口"
test_ping fw 10.10.10.2 "fw ping remote VPN地址"
test_ping remote 10.10.10.1 "remote ping fw VPN地址"

echo ""
echo "--- 跨VPN访问内部网络 ---"
test_ping remote 10.20.0.2 "remote通过VPN访问office"
test_ping remote 10.40.0.2 "remote通过VPN访问dmz"
test_ping office 10.10.10.2 "office ping remote VPN地址"

echo ""
echo "========================================="
echo "  拓扑搭建完成！"
echo "========================================="
echo ""
echo "地址规划："
echo "  office   : 10.20.0.0/24 (fw:10.20.0.1, host:10.20.0.2)"
echo "  guest    : 10.30.0.0/24 (fw:10.30.0.1, host:10.30.0.2)"
echo "  dmz      : 10.40.0.0/24 (fw:10.40.0.1, host:10.40.0.2)"
echo "  internet : 203.0.113.0/24 (fw:203.0.113.1, host:203.0.113.10)"
echo "  remote   : 192.0.2.0/24 (host:192.0.2.10, gw:192.0.2.1)"
echo "  vpn-link : 198.51.100.0/30 (fw:198.51.100.1, host:198.51.100.2)"
echo "  vpn-tun  : 10.10.10.0/24 (fw:10.10.10.1, remote:10.10.10.2)"
echo ""
echo "下一步：运行 firewall.sh 配置防火墙规则"
