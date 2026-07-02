### 场景1：DNAT配置了但外网无法访问
![场景1](19-troubleshoot-dnat.png)
**现象：**
- `internet`访问`203.0.113.1:8080`失败
- `iptables -t nat -L`显示DNAT规则存在
- `dmz`上的服务正常运行
**排查步骤：**
1. 检查FORWARD规则是否放行了DNAT后的流量
删除正确的DNAT规则,8080端口
sudo ip netns exec fw iptables -t nat -D PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080 2>/dev/null
配置错误的DNAT规则，将通行端口改为80
sudo ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:80
查看DNAT规则存在，目标端口为80
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers
2. 检查dmz的默认路由是否指向fw
检查FORWARD规则是否允许到10.40.0.2:8080（fw）
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers
3. 用conntrack观察是否有DNAT映射记录
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:8080/ 2>&1 &
sleep 1
sudo ip netns exec fw conntrack -L 2>/dev/null | grep -E "203.0.113|10.40.0.2" | head -5
4. 在fw的多个接口抓包，找出包在哪里被丢弃
在veth-fw-inet抓包（入口）：
sudo timeout 3 ip netns exec fw tcpdump -ni veth-fw-inet -c 3 2>/dev/null | head -5
在veth-fw-dmz抓包（出口）：
sudo timeout 3 ip netns exec fw tcpdump -ni veth-fw-dmz -c 3 2>/dev/null | head -5
5. 修复并验证
删除错误端口DNAT到10.40.0.2:80
sudo ip netns exec fw iptables -t nat -D PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:80 2>/dev/null
添加正确端口DNAT到10.40.0.2:8080
sudo ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
验证访问
echo "internet访问203.0.113.1:8080："
sudo ip netns exec internet curl -s --max-time 3 http://203.0.113.1:8080/ | head -10，经修改后验证访问成功
根本原因：DNAT规则配置错误，目标端口改为了80，实际服务在8080且FORWARD规则无法匹配修改后的目标端口，导致丢包


### 场景2：VPN隧道握手正常但业务访问失败
![场景2](20-troubleshoot-vpn.png)
**现象：**
- `wg show`显示`latest handshake`正常
- `remote ping 10.40.0.2`失败
- `fw`上没有相关日志

**可能原因：**
1. `AllowedIPs`配置错误
2. FORWARD规则拒绝了VPN流量

**提交要求：**
- 至少重现2个可能原因
1. `AllowedIPs`配置错误
修改AllowedIPs（去掉10.40.0.0/24） 
sudo cp /etc/wireguard/remote/wg0.conf /etc/wireguard/remote/wg0.conf.bak
sudo sed -i 's/10.20.0.0\/24,10.40.0.0\/24/10.20.0.0\/24/' /etc/wireguard/remote/wg0.conf
重启WireGuard 
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf 2>/dev/null
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
sleep 2
测试访问dmz:8080
echo "因为AllowedIPs不包含10.40.0.0/24，流量不走VPN"
sudo ip netns exec remote curl -v --max-time 3 http://10.40.0.2:8080/ 2>&1 | head -10经测试后，访问失败
修复： 恢复配置
sudo cp /etc/wireguard/remote/wg0.conf.bak /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf 2>/dev/null
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
验证
sudo ip netns exec remote curl -s --max-time 3 http://10.40.0.2:8080/ | head -5，访问成功
2. FORWARD规则拒绝了VPN流量
删除VPN允许规则 
sudo ip netns exec fw iptables -D FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null
测试访问dmz:8080
sudo ip netns exec remote curl -v --max-time 3 http://10.40.0.2:8080/ 2>&1 | head -10，经过测试，显示连接失败
修复： 恢复VPN规则 
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
验证
sudo ip netns exec remote curl -s --max-time 3 http://10.40.0.2:8080/ | head -5，访问成功

- 说明如何快速定位是哪个问题
检查remote路由表
命令：sudo ip netns exec remote ip route | grep 10.40.0看10.40.0.0/24是否走wg0，如果不走wg0则是AllowedIPs配置错误
检查fw FORWARD规则
命令：sudo ip netns exec fw iptables -L FORWARD -n -v | grep wg0，看是否有从wg0到dmz的ACCEPT规则，如果没有则是FORWARD规则缺失

### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败
![场景3](21-troubleshoot-tcp.png)
**现象：**
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

**排查步骤：**
1. 在fw上抓包，观察双向流量
删除状态检测规则
sudo ip netns exec fw iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
测试访问
sudo ip netns exec remote curl -v --max-time 5 http://10.40.0.2:8080/ 2>&1
同时在fw的wg0抓包
sudo timeout 3 ip netns exec fw tcpdump -ni wg0 -c 3 2>/dev/null | head -5经过运行能看到SYN出去
在fw的veth-fw-dmz抓包
sudo timeout 3 ip netns exec fw tcpdump -ni veth-fw-dmz -c 3 2>/dev/null | head -5经过运行看不到SYN-ACK返回
2. 用conntrack观察连接状态
查看conntrack
sudo ip netns exec fw conntrack -L 2>/dev/null | grep -E "10.10.10.2|10.40.0.2" | head -3显然没有状态检测，conntrack不会记录ESTABLISHED状态
3. 理解状态检测的作用
TCP 是双向有状态协议，仅放行新建请求包会阻断所有响应流量；但是ESTABLISHED/RELATED会统一放行所有会话回程报文，无需为每条业务规则配置双向放行，可以大幅度简化防火墙策略，是企业边界必备核心规则。