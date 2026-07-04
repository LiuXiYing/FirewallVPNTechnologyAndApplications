NS=fw

# 清空fw内原有iptables规则，无残留叠加
sudo ip netns exec $NS iptables -F FORWARD
sudo ip netns exec $NS iptables -t nat -F
sudo ip netns exec $NS iptables -X
sudo ip netns exec $NS iptables -t nat -X

# 默认转发全部拒绝（原有逻辑不变）
sudo ip netns exec $NS iptables -P FORWARD DROP

# 状态检测规则置顶（顺序不变）
sudo ip netns exec $NS iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 1. office -> dmz:8080 允许
sudo ip netns exec $NS iptables -A FORWARD -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 8080 -j ACCEPT

# 2. office -> dmz:22 拒绝，仅新增--log-level 7，拦截逻辑不变
sudo ip netns exec $NS iptables -A FORWARD -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -j LOG --log-prefix "OFFICE_SSH_DMZ_DENY:" --log-level 7
sudo ip netns exec $NS iptables -A FORWARD -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -j REJECT

# 3. office访问外网允许
sudo ip netns exec $NS iptables -A FORWARD -s 10.20.0.0/24 -o veth-fw-inet -j ACCEPT

# 4. guest访问外网允许
sudo ip netns exec $NS iptables -A FORWARD -s 10.30.0.0/24 -o veth-fw-inet -j ACCEPT

# 5. guest访问office拒绝
sudo ip netns exec $NS iptables -A FORWARD -s 10.30.0.0/24 -d 10.20.0.0/24 -j LOG --log-prefix "GUEST_ACCESS_OFFICE_DENY:" --log-level 7
sudo ip netns exec $NS iptables -A FORWARD -s 10.30.0.0/24 -d 10.20.0.0/24 -j REJECT

# 6. guest访问dmz拒绝
sudo ip netns exec $NS iptables -A FORWARD -s 10.30.0.0/24 -d 10.40.0.0/24 -j LOG --log-prefix "GUEST_ACCESS_DMZ_DENY:" --log-level 7
sudo ip netns exec $NS iptables -A FORWARD -s 10.30.0.0/24 -d 10.40.0.0/24 -j REJECT

# 7. dmz访问外网允许
sudo ip netns exec $NS iptables -A FORWARD -s 10.40.0.0/24 -o veth-fw-inet -j ACCEPT

# 8. 外网访问dmz 8080允许
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.40.0.2 -p tcp --dport 8080 -j ACCEPT

# 9. 外网访问dmz 22拒绝
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "INET_SSH_DMZ_DENY:" --log-level 7
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# 10. 外网访问office拒绝
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.20.0.0/24 -j LOG --log-prefix "INET_ACCESS_OFFICE_DENY:" --log-level 7
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.20.0.0/24 -j REJECT

# 11. 外网访问guest拒绝
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.30.0.0/24 -j LOG --log-prefix "INET_ACCESS_GUEST_DENY:" --log-level 7
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -d 10.30.0.0/24 -j REJECT

# SNAT 内网上网规则完全原样保留
sudo ip netns exec $NS iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec $NS iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec $NS iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT端口映射原样保留
sudo ip netns exec $NS iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080


