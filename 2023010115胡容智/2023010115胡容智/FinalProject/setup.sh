#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# 脚本名称: setup.sh
# 脚本功能: 自动化构建五大安全域物理隔离拓扑、L2网桥重构及三层路由转发控制

set -euo pipefail

# 1. 基础清理：确保环境中无残留命名空间及网桥
echo "[*] 正在清理旧有虚拟拓扑环境..."
ip netns list | awk '{print $1}' | xargs -I {} sudo ip netns del {} 2>/dev/null || true
sudo ip link del br0 2>/dev/null || true

echo "[*] 开始构建核心虚拟安全域空间..."
# 2. 创建五大独立安全域命名空间
for ns in internal public server external remote fw; do
    sudo ip netns add "$ns"
    echo " -> 成功创建命名空间: $ns"
done

# 3. 启用各命名空间的本地环回接口 (Loopback)
for ns in internal public server external remote fw; do
    sudo ip netns exec "$ns" ip link set lo up
done

echo "[*] 开始构建二三层虚拟网络链路..."

# --- 3.1 划分内网、公共区与核心服务区链路 (VETH-Pair) ---
# 信任内网 (Internal) <--> 防火墙 (FW)
sudo ip link add veth-internal type veth peer name veth-fw-internal
sudo ip link set veth-internal netns internal
sudo ip link set veth-fw-internal netns fw

# 公共服务区 (Public) <--> 防火墙 (FW)
sudo ip link add veth-public type veth peer name veth-fw-public
sudo ip link set veth-public netns public
sudo ip link set veth-fw-public netns fw

# 核心服务区 (Server) <--> 防火墙 (FW)
sudo ip link add veth-server type veth peer name veth-fw-server
sudo ip link set veth-server netns server
sudo ip link set veth-fw-server netns fw

# --- 3.2 利用 Linux Bridge 重构非信任外网二层广播域 ---
# 在 external 空间中建立虚拟二层网桥 br0
sudo ip netns exec external ip link add br0 type bridge
sudo ip netns exec external ip link set br0 up

# 将 防火墙公网口 (fw) 桥接至 external 的 br0
sudo ip link add veth-fw-pub type veth peer name veth-ext-fw
sudo ip link set veth-fw-pub netns fw
sudo ip link set veth-ext-fw netns external
sudo ip netns exec external ip link set veth-ext-fw master br0
sudo ip netns exec external ip link set veth-ext-fw up

# 将 远程办公端 (remote) 桥接至 external 的 br0
sudo ip link add veth-remote type veth peer name veth-ext-rm
sudo ip link set veth-remote netns remote
sudo ip link set veth-ext-rm netns external
sudo ip netns exec external ip link set veth-ext-rm master br0
sudo ip netns exec external ip link set veth-ext-rm up

echo "[*] 开始配置各安全域网络地址与接口起速..."

# --- 4.1 接口激活与 IP 地址分配 ---
# 信任内网域
sudo ip netns exec internal ip addr add 172.16.10.2/24 dev veth-internal
sudo ip netns exec internal ip link set veth-internal up

# 公共服务域
sudo ip netns exec public ip addr add 172.16.20.2/24 dev veth-public
sudo ip netns exec public ip link set veth-public up

# 核心服务域
sudo ip netns exec server ip addr add 172.16.30.2/24 dev veth-server
sudo ip netns exec server ip link set veth-server up

# 防火墙网关内网侧三接口
sudo ip netns exec fw ip addr add 172.16.10.1/24 dev veth-fw-internal
sudo ip netns exec fw ip addr add 172.16.20.1/24 dev veth-fw-public
sudo ip netns exec fw ip addr add 172.16.30.1/24 dev veth-fw-server
sudo ip netns exec fw ip link set veth-fw-internal up
sudo ip netns exec fw ip link set veth-fw-public up
sudo ip netns exec fw ip link set veth-fw-server up

# 外网互联侧 (FW公网口与Remote点对点域)
sudo ip netns exec fw ip addr add 198.51.100.1/24 dev veth-fw-pub
sudo ip netns exec fw ip link set veth-fw-pub up

sudo ip netns exec remote ip addr add 198.51.100.100/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up

# --- 4.2 默认网关与路由收敛配置 ---
echo "[*] 正在为终端域灌入静态路由与默认网关..."
sudo ip netns exec internal ip route add default via 172.16.10.1
sudo ip netns exec public ip route add default via 172.16.20.1
sudo ip netns exec server ip route add default via 172.16.30.1
sudo ip netns exec remote ip route add default via 198.51.100.1

# --- 4.3 开启边界网关核心转发引擎 ---
echo "[*] 激活边界网关内核有状态 IPv4 转发开关..."
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "[✓] 虚拟实验安全拓扑网络环境全部构建成功！"