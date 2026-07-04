#!/bin/bash
# 清理旧环境
sudo ip netns del fw
sudo ip netns del office
sudo ip netns del guest
sudo ip netns del dmz
sudo ip netns del internet
sudo ip netns del remote

# 重建6个网络命名空间
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# 开启fw内核IPv4转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

# ========== office网段 10.20.0.0/24 ==========
sudo ip link add veth-fw-office type veth peer veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up

sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up
sudo ip netns exec office ip route add default via 10.20.0.1

# ========== guest网段 10.30.0.0/24 ==========
sudo ip link add veth-fw-guest type veth peer veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest

sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up

sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up
sudo ip netns exec guest ip route add default via 10.30.0.1

# ========== dmz网段 10.40.0.0/24 ==========
sudo ip link add veth-fw-dmz type veth peer veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz

sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up

sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up
sudo ip netns exec dmz ip route add default via 10.40.0.1

# ========== internet外网网段 203.0.113.0/24 ==========
sudo ip link add veth-fw-inet type veth peer veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet

sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up

sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up
sudo ip netns exec internet ip route add default via 203.0.113.1

# remote仅开启本地回环，VPN后续自动生成wg0接口
sudo ip netns exec remote ip link set lo up
