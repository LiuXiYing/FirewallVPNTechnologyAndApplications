#!/bin/bash
# setup.sh - CentOS Stream 10 网络命名空间拓扑搭建
set -e

echo "====== CentOS 10 网络拓扑搭建 ======"

# ====================== 1. 清理旧环境 ======================
# 循环删除所有业务网络命名空间，不存在则忽略报错
for ns in fw office guest dmz internet remote; do
    ip netns del $ns 2>/dev/null || true
done
# 全局删除系统残留的veth虚拟网卡，避免重复创建冲突
ip link | grep veth | awk '{print $2}' | sed 's/://' | xargs -I {} ip link del {} 2>/dev/null

# ====================== 2. 创建6个独立网络命名空间 ======================
# fw：边界防火墙+WireGuard VPN网关
ip netns add fw
# office：企业内网办公主机
ip netns add office
# guest：访客隔离网段主机
ip netns add guest
# dmz：对外业务服务器区域
ip netns add dmz
# internet：模拟互联网外网客户端
ip netns add internet
# remote：异地远程员工终端
ip netns add remote

# ====================== 3. 创建veth虚拟网线，两端绑定至对应命名空间 ======================
# office网段veth对：fw侧veth-fw-office，办公主机侧veth-office
ip link add veth-fw-office type veth peer name veth-office
ip link set veth-fw-office netns fw
ip link set veth-office netns office

# guest访客网段veth对
ip link add veth-fw-guest type veth peer name veth-guest
ip link set veth-fw-guest netns fw
ip link set veth-guest netns guest

# DMZ服务区veth对
ip link add veth-fw-dmz type veth peer name veth-dmz
ip link set veth-fw-dmz netns fw
ip link set veth-dmz netns dmz

# internet外网模拟网段veth对
ip link add veth-fw-inet type veth peer name veth-inet
ip link set veth-fw-inet netns fw
ip link set veth-inet netns internet

# remote远程主机底层通信veth对，承载WireGuard公网报文传输
ip link add veth-fw-remote type veth peer name veth-remote
ip link set veth-fw-remote netns fw
ip link set veth-remote netns remote

# ====================== 4. 配置防火墙fw所有接口IP地址并启用网卡 ======================
# office网关接口配置
ip netns exec fw ip addr flush dev veth-fw-office
ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
ip netns exec fw ip link set veth-fw-office up

# guest网关接口配置
ip netns exec fw ip addr flush dev veth-fw-guest
ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
ip netns exec fw ip link set veth-fw-guest up

# DMZ网关接口配置
ip netns exec fw ip addr flush dev veth-fw-dmz
ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
ip netns exec fw ip link set veth-fw-dmz up

# 外网公网接口配置
ip netns exec fw ip addr flush dev veth-fw-inet
ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
ip netns exec fw ip link set veth-fw-inet up

# remote底层通信网关接口配置
ip netns exec fw ip addr flush dev veth-fw-remote
ip netns exec fw ip addr add 192.168.200.1/30 dev veth-fw-remote
ip netns exec fw ip link set veth-fw-remote up

# 启用防火墙命名空间回环网卡，本地通信依赖lo
ip netns exec fw ip link set lo up

# ====================== 5. 各终端主机IP、回环、默认路由配置 ======================
# office内网主机
ip netns exec office ip addr flush dev veth-office
ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
ip netns exec office ip link set veth-office up
ip netns exec office ip link set lo up
ip netns exec office ip route del default 2>/dev/null || true
# 所有内网流量默认转发至防火墙网关
ip netns exec office ip route add default via 10.20.0.1

# guest访客主机
ip netns exec guest ip addr flush dev veth-guest
ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
ip netns exec guest ip link set veth-guest up
ip netns exec guest ip link set lo up
ip netns exec guest ip route del default 2>/dev/null || true
ip netns exec guest ip route add default via 10.30.0.1

# dmz业务服务器
ip netns exec dmz ip addr flush dev veth-dmz
ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
ip netns exec dmz ip link set veth-dmz up
ip netns exec dmz ip link set lo up
ip netns exec dmz ip route del default 2>/dev/null || true
ip netns exec dmz ip route add default via 10.40.0.1

# internet外网客户端
ip netns exec internet ip addr flush dev veth-inet
ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
ip netns exec internet ip link set veth-inet up
ip netns exec internet ip link set lo up
ip netns exec internet ip route del default 2>/dev/null || true
ip netns exec internet ip route add default via 203.0.113.1

# remote远程员工物理终端
ip netns exec remote ip addr flush dev veth-remote
ip netns exec remote ip addr add 192.168.200.2/30 dev veth-remote
ip netns exec remote ip link set veth-remote up
ip netns exec remote ip link set lo up
ip netns exec remote ip route del default 2>/dev/null || true
ip netns exec remote ip route add default via 192.168.200.1

# ====================== 6. 开启防火墙内核IP转发功能 ======================
# 开启IPv4数据包转发，实现跨网段流量互通
ip netns exec fw sysctl -w net.ipv4.ip_forward=1
# 全局接口转发开关同步开启
ip netns exec fw sysctl -w net.ipv4.conf.all.forwarding=1

# ====================== 7. 自动化连通性检测，用于验证拓扑基础通信 ======================
echo -e "\n====== 连通性测试开始 ======"
ip netns exec office ping -c 2 10.20.0.1 && echo "✓ office -> fw 连通正常" || echo "✗ office -> fw 连通失败"
ip netns exec guest ping -c 2 10.30.0.1 && echo "✓ guest -> fw 连通正常" || echo "✗ guest -> fw 连通失败"
ip netns exec dmz ping -c 2 10.40.0.1 && echo "✓ dmz -> fw 连通正常" || echo "✗ dmz -> fw 连通失败"
ip netns exec internet ping -c 2 203.0.113.1 && echo "✓ internet -> fw 连通正常" || echo "✗ internet -> fw 连通失败"
ip netns exec remote ping -c 2 192.168.200.1 && echo "✓ remote -> fw 底层链路连通正常" || echo "✗ remote -> fw 底层链路连通失败"

echo -e "\n====== 企业网络拓扑全部搭建完成 ======"
echo "网段规划说明："
echo "办公区office：10.20.0.0/24  | 访客guest：10.30.0.0/24"
echo "DMZ服务区：10.40.0.0/24    | 模拟外网internet：203.0.113.0/24"
echo "remote底层WireGuard通信：192.168.200.0/30 | VPN加密业务隧道：10.10.10.0/24"
