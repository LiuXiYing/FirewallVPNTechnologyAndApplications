#!/bin/bash
# 清理旧环境
sudo ip netns del fw 2>/dev/null
sudo ip netns del office 2>/dev/null
sudo ip netns del guest 2>/dev/null
sudo ip netns del dmz 2>/dev/null
sudo ip netns del internet 2>/dev/null
sudo ip netns del remote 2>/dev/null
sudo ip link del veth-fw-office 2>/dev/null
sudo ip link del veth-fw-guest 2>/dev/null
sudo ip link del veth-fw-dmz 2>/dev/null
sudo ip link del veth-fw-inet 2>/dev/null
sudo ip link del veth-remote 2>/dev/null
sudo ip link del veth-internet 2>/dev/null

# 创建命名空间
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# 创建 veth 对并配置
# office
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# dmz
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# internet
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# remote 与 internet 的连接（用于 VPN 握手）
sudo ip link add veth-remote type veth peer name veth-internet
sudo ip link set veth-remote netns remote
sudo ip link set veth-internet netns internet
sudo ip netns exec remote ip addr add 203.0.113.12/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up
sudo ip netns exec internet ip addr add 203.0.113.11/24 dev veth-internet
sudo ip netns exec internet ip link set veth-internet up

# 默认路由
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 203.0.113.11
sudo ip netns exec internet ip route add 203.0.113.12/32 dev veth-internet  # 确保 internet 可达 remote

# fw 开启转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec internet sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec internet iptables -P FORWARD ACCEPT
sudo ip netns exec internet sysctl -w net.ipv4.conf.all.rp_filter=0
sudo ip netns exec internet sysctl -w net.ipv4.conf.veth-internet.rp_filter=0
sudo ip netns exec internet sysctl -w net.ipv4.conf.veth-inet.rp_filter=0

# fw 添加路由到 remote 端点
sudo ip netns exec fw ip route add 203.0.113.12/32 via 203.0.113.10

echo "Setup completed."
