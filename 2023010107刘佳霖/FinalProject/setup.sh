#!/bin/bash
# FinalProject/setup.sh 拓扑一键搭建脚本
# 必须先加载wireguard内核模块
sudo modprobe wireguard 2>/dev/null || echo "警告: wireguard模块未加载，请执行: sudo modprobe wireguard"
# 1. 清理旧环境
sudo ip netns del fw 2>/dev/null
sudo ip netns del office 2>/dev/null
sudo ip netns del guest 2>/dev/null
sudo ip netns del dmz 2>/dev/null
sudo ip netns del internet 2>/dev/null
sudo ip netns del remote 2>/dev/null
# 删除残留veth
sudo ip link del veth-fw-office 2>/dev/null
sudo ip link del veth-office 2>/dev/null
sudo ip link del veth-fw-guest 2>/dev/null
sudo ip link del veth-guest 2>/dev/null
sudo ip link del veth-fw-dmz 2>/dev/null
sudo ip link del veth-dmz 2>/dev/null
sudo ip link del veth-fw-inet 2>/dev/null
sudo ip link del veth-inet 2>/dev/null
# 删除remote网桥veth
sudo ip link del veth-rem 2>/dev/null
sudo ip link del veth-rem-peer 2>/dev/null

# 2. 创建6个网络命名空间
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# 3. 搭建office veth对
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
# fw侧配置
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
# office主机配置
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up
sudo ip netns exec office ip route add default via 10.20.0.1

# 4. guest区域
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up
sudo ip netns exec guest ip route add default via 10.30.0.1

# 5. DMZ区域
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up
sudo ip netns exec dmz ip route add default via 10.40.0.1

# 6. internet外网区域
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up
sudo ip netns exec internet ip route add default via 203.0.113.1

# 7. fw开启内核IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
# 关闭宿主机防火墙干扰
sudo iptables -F
sudo iptables -t nat -F

# 8. remote通过internet桥接访问外网
# 在internet中创建桥接br0，将veth-inet和veth-rem桥接
sudo ip netns exec internet ip link add br0 type bridge 2>/dev/null
sudo ip netns exec internet ip link set br0 up
sudo ip link add veth-rem type veth peer name veth-rem-peer 2>/dev/null
sudo ip link set veth-rem netns internet
sudo ip link set veth-rem-peer netns remote
sudo ip netns exec internet ip link set veth-inet master br0
sudo ip netns exec internet ip link set veth-rem master br0
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set veth-rem up
sudo ip netns exec internet ip addr del 203.0.113.10/24 dev veth-inet 2>/dev/null
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev br0
sudo ip netns exec internet ip route del default via 203.0.113.1 dev veth-inet 2>/dev/null
sudo ip netns exec internet ip route add default via 203.0.113.1 dev br0
# 配置remote
sudo ip netns exec remote ip addr add 203.0.113.100/24 dev veth-rem-peer
sudo ip netns exec remote ip link set veth-rem-peer up
sudo ip netns exec remote ip link set lo up
sudo ip netns exec remote ip route add default via 203.0.113.1

# 9. WireGuard VPN 接口配置
# 注意：wireguard内核模块需提前加载（sudo modprobe wireguard）
# 以下配置依赖已生成的 vpn-fw.conf 和 vpn-remote.conf
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 创建 WireGuard 虚拟接口（wg setconf 前必须先创建接口）
sudo ip netns exec fw ip link add wg0 type wireguard 2>/dev/null
sudo ip netns exec remote ip link add wg0 type wireguard 2>/dev/null

sudo ip netns exec fw wg setconf wg0 "$SCRIPT_DIR/vpn-fw.conf" 2>/dev/null
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev wg0 2>/dev/null
sudo ip netns exec fw ip link set wg0 up
sudo ip netns exec remote wg setconf wg0 "$SCRIPT_DIR/vpn-remote.conf" 2>/dev/null
sudo ip netns exec remote ip addr add 10.10.10.2/24 dev wg0 2>/dev/null
sudo ip netns exec remote ip link set wg0 up

echo "===== 拓扑搭建完成，连通性测试命令 ====="
echo "sudo ip netns exec office ping -c 2 10.20.0.1"
echo "sudo ip netns exec guest ping -c 2 10.30.0.1"
echo "sudo ip netns exec dmz ping -c 2 10.40.0.1"
echo "sudo ip netns exec internet ping -c 2 203.0.113.1"
echo "sudo ip netns exec remote ping -c 2 203.0.113.1"
echo "sudo ip netns exec remote ping -c 2 10.40.0.2"
echo ""
echo "===== 请执行以下命令完成配置 ====="
echo "bash \"$SCRIPT_DIR/firewall.sh\"   # 加载防火墙规则"
