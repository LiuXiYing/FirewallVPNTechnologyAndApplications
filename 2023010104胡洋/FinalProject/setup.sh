#!/bin/bash
set -euo pipefail

# 必须root执行校验
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "错误：请使用 sudo 运行脚本,命令:sudo bash $0" >&2
  exit 1
fi

# 所有网络命名空间列表
NS=(fw office guest dmz internet remote)
# 所有veth网卡对列表，用于清理
VETH_LIST=(
  veth-fw-office veth-office
  veth-fw-guest veth-guest
  veth-fw-dmz veth-dmz
  veth-fw-inet veth-inet
  veth-fw-remote veth-remote
)

# 函数1：清理旧命名空间、进程、虚拟网卡
cleanup_all() {
  # 杀死命名空间内残留进程
  for ns in "${NS[@]}"; do
    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
      ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 || true
      ip netns del "$ns" || true
    fi
  done
  # 删除残留veth网卡（防止重复执行报错device exists）
  for dev in "${VETH_LIST[@]}"; do
    ip link delete "$dev" 2>/dev/null || true
  done
  echo "[清理完成] 旧网络环境已销毁"
}

# 函数2：创建所有网络命名空间并启用本地回环lo
create_ns() {
  for ns in "${NS[@]}"; do
    ip netns add "$ns"
    ip netns exec "$ns" ip link set lo up
  done
  echo "[命名空间创建完成] fw/office/guest/dmz/internet/remote"
}

# 函数3：通用创建veth链路模板
# 参数：区域名 fw端接口 区域端接口 fw端IP/CIDR 区域端IP/CIDR 区域默认网关
create_link() {
  local ns="$1" fw_if="$2" ns_if="$3" fw_ip="$4" ns_ip="$5" gw="$6"
  # 创建veth配对网卡
  ip link add "$fw_if" type veth peer name "$ns_if"
  # 分别划入对应命名空间
  ip link set "$fw_if" netns fw
  ip link set "$ns_if" netns "$ns"
  # 配置防火墙fw侧IP并启用网卡
  ip netns exec fw ip addr add "$fw_ip" dev "$fw_if"
  ip netns exec fw ip link set "$fw_if" up
  # 配置业务主机侧IP并启用网卡
  ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if"
  ip netns exec "$ns" ip link set "$ns_if" up
  # 设置业务主机默认网关（全部指向防火墙fw）
  ip netns exec "$ns" ip route add default via "$gw" || true
  echo "  链路创建成功：fw <-> $ns"
}

# 函数4：批量连通性测试
test_connect() {
  echo -e "\n===== 开始批量连通性Ping测试 ====="
  sudo ip netns exec office   ping -c 2 10.20.0.1
  sudo ip netns exec guest    ping -c 2 10.30.0.1
  sudo ip netns exec dmz      ping -c 2 10.40.0.1
  sudo ip netns exec internet ping -c 2 203.0.113.1
  sudo ip netns exec remote   ping -c 2 192.0.2.1
  echo -e "\n===== Ping测试全部执行完毕 ====="
}

# ========== 主程序执行流程 ==========
# 1. 先清理旧环境
cleanup_all
# 2. 新建全部命名空间
create_ns

# 3. 创建业务网段链路（办公区/访客区/DMZ外网服务区/互联网）
create_link office   veth-fw-office veth-office 10.20.0.1/24    10.20.0.2/24    10.20.0.1
create_link guest    veth-fw-guest  veth-guest  10.30.0.1/24    10.30.0.2/24    10.30.0.1
create_link dmz      veth-fw-dmz    veth-dmz    10.40.0.1/24    10.40.0.2/24    10.40.0.1
create_link internet veth-fw-inet   veth-inet   203.0.113.1/24  203.0.113.10/24 203.0.113.1

# 4. 创建WireGuard底层通信链路（remote客户端 <-> fw防火墙底层UDP通信）
# 底层网段192.0.2.0/24仅用于WG握手，VPN业务隧道网段仍为10.10.10.0/24
create_link remote   veth-fw-remote veth-remote 192.0.2.1/24    192.0.2.2/24    192.0.2.1

# 5. 防火墙开启IP转发，关闭反向路径过滤rp_filter（解决VPN跨网段不通）
ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns exec fw sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
ip netns exec fw sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

# 6. 自动执行连通性测试
test_connect

# 7. 完成提示与后续操作指引
cat <<'MSG'
=============================================
[全部完成] 企业网络拓扑搭建成功！
基础网段规划：
  办公区office:10.20.0.0/24
  访客区guest:10.30.0.0/24
  DMZ服务区:10.40.0.0/24
  互联网外网:203.0.113.0/24
  WireGuard底层通信:192.0.2.0/24
  VPN业务隧道网段:10.10.10.0/24

下一步操作：
  1. 执行防火墙策略脚本:sudo bash firewall.sh
  2. 生成WireGuard公私钥,部署VPN服务端/客户端
  3. 启动DMZ Web测试服务:sudo ip netns exec dmz python3 -m http.server 8080
=============================================
MSG