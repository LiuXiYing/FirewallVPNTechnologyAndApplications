#!/bin/bash
# 仅拓扑搭建，不含iptables防火墙规则，可重复运行

# ====================== 清理旧环境 ======================
sudo ip link del veth-fw-office 2>/dev/null
sudo ip link del veth-fw-guest 2>/dev/null
sudo ip link del veth-fw-dmz 2>/dev/null
sudo ip link del veth-fw-inet 2>/dev/null
sudo ip link del veth-fw-vpn 2>/dev/null

sudo ip netns del fw 2>/dev/null
sudo ip netns del office 2>/dev/null
sudo ip netns del guest 2>/dev/null
sudo ip netns del dmz 2>/dev/null
sudo ip netns del internet 2>/dev/null
sudo ip netns del vpn 2>/dev/null

# ====================== 1. 创建命名空间 ======================
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add vpn

# ====================== 2. 创建5组veth ======================
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link add veth-fw-vpn type veth peer name veth-vpn

# ====================== 3. 移入对应netns ======================
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest

sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz

sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet

sudo ip link set veth-fw-vpn netns fw
sudo ip link set veth-vpn netns vpn

# ====================== 4. 配置IP并启用接口 ======================
# fw
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev veth-fw-vpn
sudo ip netns exec fw ip link set lo up
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec fw ip link set veth-fw-vpn up

# office
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set lo up
sudo ip netns exec office ip link set veth-office up

# guest
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set lo up
sudo ip netns exec guest ip link set veth-guest up

# dmz
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set lo up
sudo ip netns exec dmz ip link set veth-dmz up

# internet
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set lo up
sudo ip netns exec internet ip link set veth-inet up

# vpn
sudo ip netns exec vpn ip addr add 10.10.10.2/24 dev veth-vpn
sudo ip netns exec vpn ip link set lo up
sudo ip netns exec vpn ip link set veth-vpn up

# ====================== 5. 配置默认路由 ======================
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec vpn ip route add default via 10.10.10.1

# ====================== 6. 开启防火墙转发 ======================
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

# ====================== 7. 连通性自动ping测试 ======================
echo "===== office ping fw 10.20.0.1 ====="
sudo ip netns exec office ping -c 2 10.20.0.1

echo -e "\n===== guest ping fw 10.30.0.1 ====="
sudo ip netns exec guest ping -c 2 10.30.0.1

echo -e "\n===== dmz ping fw 10.40.0.1 ====="
sudo ip netns exec dmz ping -c 2 10.40.0.1

echo -e "\n===== internet ping fw 203.0.113.1 ====="
sudo ip netns exec internet ping -c 2 203.0.113.1