#!/bin/bash

echo "========================================="
echo " Enterprise Network Topology Setup"
echo "========================================="

###############################
# 清理旧环境
###############################

echo "[1/8] Cleaning old topology..."

for ns in fw office guest dmz internet remote
do
    ip netns del $ns 2>/dev/null
done

for dev in \
veth-fw-office \
veth-fw-guest \
veth-fw-dmz \
veth-fw-int \
veth-fw-remote
do
    ip link del $dev 2>/dev/null
done

###############################
# 创建 Namespace
###############################

echo "[2/8] Creating namespaces..."

for ns in fw office guest dmz internet remote
do
    ip netns add $ns
done

###############################
# Office
###############################

echo "[3/8] OFFICE"

ip link add veth-fw-office type veth peer name veth-office

ip link set veth-fw-office netns fw
ip link set veth-office netns office

ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
ip netns exec office ip addr add 10.20.0.2/24 dev veth-office

ip netns exec fw ip link set veth-fw-office up
ip netns exec office ip link set veth-office up

###############################
# Guest
###############################

echo "[4/8] GUEST"

ip link add veth-fw-guest type veth peer name veth-guest

ip link set veth-fw-guest netns fw
ip link set veth-guest netns guest

ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest

ip netns exec fw ip link set veth-fw-guest up
ip netns exec guest ip link set veth-guest up

###############################
# DMZ
###############################

echo "[5/8] DMZ"

ip link add veth-fw-dmz type veth peer name veth-dmz

ip link set veth-fw-dmz netns fw
ip link set veth-dmz netns dmz

ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz

ip netns exec fw ip link set veth-fw-dmz up
ip netns exec dmz ip link set veth-dmz up

###############################
# Internet
###############################

echo "[6/8] INTERNET"

# 注意：名称不能超过15个字符
ip link add veth-fw-int type veth peer name veth-int

ip link set veth-fw-int netns fw
ip link set veth-int netns internet

ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-int
ip netns exec internet ip addr add 203.0.113.10/24 dev veth-int

ip netns exec fw ip link set veth-fw-int up
ip netns exec internet ip link set veth-int up

###############################
# Remote
###############################

echo "[7/8] REMOTE"

ip link add veth-fw-rem type veth peer name veth-rem

ip link set veth-fw-rem netns fw
ip link set veth-rem netns remote

ip netns exec fw ip addr add 10.10.10.1/24 dev veth-fw-rem
ip netns exec remote ip addr add 10.10.10.2/24 dev veth-rem

ip netns exec fw ip link set veth-fw-rem up
ip netns exec remote ip link set veth-rem up

###############################
# Loopback
###############################

for ns in fw office guest dmz internet remote
do
    ip netns exec $ns ip link set lo up
done

###############################
# 默认路由
###############################

ip netns exec office ip route replace default via 10.20.0.1
ip netns exec guest ip route replace default via 10.30.0.1
ip netns exec dmz ip route replace default via 10.40.0.1
ip netns exec internet ip route replace default via 203.0.113.1
ip netns exec remote ip route replace default via 10.10.10.1

###############################
# 开启转发
###############################

ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null

###############################
# 完成
###############################

echo
echo "========================================="
echo "Topology Created Successfully!"
echo "========================================="

echo
echo "Namespaces:"
ip netns ls

echo
echo "Firewall:"
ip netns exec fw ip addr

echo
echo "Office:"
ip netns exec office ip addr

echo
echo "Guest:"
ip netns exec guest ip addr

echo
echo "DMZ:"
ip netns exec dmz ip addr

echo
echo "Internet:"
ip netns exec internet ip addr

echo
echo "Remote:"
ip netns exec remote ip addr

echo
echo "You can now test connectivity."
