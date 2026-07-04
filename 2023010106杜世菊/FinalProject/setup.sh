#!/bin/bash
# ============================================================
# 网络拓扑搭建脚本 
# 功能：创建6个namespace，配置5对veth，设置IP及路由
# ============================================================

# 清理旧环境
sudo ip netns exec fw wg-quick down /etc/wireguard/fw/wg0.conf 2>/dev/null
sudo ip netns del office 2>/dev/null
sudo ip netns del guest 2>/dev/null
sudo ip netns del dmz 2>/dev/null
sudo ip netns del internet 2>/dev/null
sudo ip netns del fw 2>/dev/null
sudo ip netns del remote 2>/dev/null

# 清理所有veth设备（确保不残留）
sudo ip link del veth-fw-office 2>/dev/null
sudo ip link del veth-office 2>/dev/null
sudo ip link del veth-fw-guest 2>/dev/null
sudo ip link del veth-guest 2>/dev/null
sudo ip link del veth-fw-dmz 2>/dev/null
sudo ip link del veth-dmz 2>/dev/null
sudo ip link del veth-fw-inet 2>/dev/null
sudo ip link del veth-inet 2>/dev/null
sudo ip link del veth-fw-remote 2>/dev/null   # 新增VPN清理
sudo ip link del veth-remote 2>/dev/null

# 创建6个网络命名空间，模拟6台独立主机/网关设备
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add fw
sudo ip netns add remote

# 创建veth虚拟网线，两两配对，用来把主机连到防火墙上（5对）
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link add veth-fw-remote type veth peer name veth-remote   # VPN区域

# 将网线两端分别分配到网关fw和对应主机的命名空间中
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote

# =========== 配置网关fw各网卡IP并启用 ===========
## office网段网关
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
## guest网段网关
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
## dmz服务区网关
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
## internet外网网关
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
## VPN网关
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
## 开启本机回环网卡
sudo ip netns exec fw ip link set lo up

# =========== 配置各主机IP并启用网卡 ===========
## office办公主机
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

## guest访客主机
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

## dmz服务器主机
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

## internet外网主机
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

## remote远程VPN客户端
sudo ip netns exec remote ip addr add 10.10.10.2/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

# =========== 配置所有主机默认网关 ===========
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 10.10.10.1   # VPN路由

# =========== 开启防火墙IP转发 ===========
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 

# =========== 连通性自检（验证所有区域） ===========
echo "==== office 能 ping 通 fw  ===="
sudo ip netns exec office ping -c 2 10.20.0.1
echo "==== guest 能 ping 通 fw ===="
sudo ip netns exec guest ping -c 2 10.30.0.1
echo "==== dmz 能 ping 通 fw ===="
sudo ip netns exec dmz ping -c 2 10.40.0.1
echo "==== internet 能 ping 通 fw ===="
sudo ip netns exec internet ping -c 2 203.0.113.1
echo "==== remote 能 ping 通 fw (VPN) ===="
sudo ip netns exec remote ping -c 2 10.10.10.1