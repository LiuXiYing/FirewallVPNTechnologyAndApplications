# 攻防演练分析报告

## 一、攻击方演练分析

### 攻击1：扫描office网段

**攻击命令：**
```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**攻击结果：**
```
10.20.0.1 is up
PING 10.20.0.2: Destination Port Unreachable
PING 10.20.0.3: Destination Port Unreachable
...
```

**攻击分析：**

攻击者从guest区域（10.30.0.0/24）发起ICMP扫描，探测office网段（10.20.0.0/24）的存活主机。

扫描结果分析：
- `10.20.0.1`（fw）可达 → 防火墙的guest侧接口暴露
- `10.20.0.2`（office）不可达 → 返回`Destination Port Unreachable`
- `10.20.0.3~10`不可达 → 被REJECT或超时

**防御分析：**

防火墙成功拦截了扫描行为：
- 第10行REJECT规则：`guest → office` 拒绝所有流量
- 第9行LOG规则：记录所有guest访问office的尝试
- 包计数：guest→office规则有4 packets，证明拦截生效

**安全建议：**
- 对外部网络应使用DROP而非REJECT，减少信息泄露
- 部署IDS/IPS检测扫描行为
- 限制ICMP流量，减少探测风险

---

### 攻击2：尝试绕过防火墙访问dmz:22

**攻击命令：**
```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**攻击结果：**
```
curl: (28) Connection timed out after 2040 milliseconds
curl: (28) Connection timed out after 2040 milliseconds
```

**攻击分析：**

攻击者试图通过改变源端口（80、443）绕过防火墙对dmz:22的访问限制。这种攻击假设防火墙规则基于源端口过滤，但本实验的防火墙基于目标端口（22）过滤。

**防御分析：**

防火墙成功防御：
- 第14行REJECT规则：`internet → dmz:22` 拒绝所有SSH访问
- 规则不关心源端口，只匹配目标端口22
- 改变源端口无法绕过基于目标端口的过滤

**安全启示：**
- 防火墙规则应基于目标端口而非源端口
- 最小权限原则：只放行必要的服务端口
- 结合状态检测防止绕过攻击

---

### 攻击3：尝试伪造VPN流量

**攻击命令：**
```bash
sudo ip netns exec guest ping -c 1 -I 10.10.10.2 10.20.0.2 2>&1
sudo ip netns exec guest curl --interface 10.10.10.2 --max-time 2 http://10.20.0.2:8000/ 2>&1
```

**攻击结果：**
```
ping: bind: 无法分配被请求的地址
curl: (45) Failed to connect ... Failed binding local connection end
```

**攻击分析：**

攻击者试图伪造VPN源IP（10.10.10.2），以VPN用户身份访问内网资源。这是典型的IP欺骗攻击。

**防御分析：**

攻击在操作系统层面被阻止：
- guest命名空间没有10.10.10.2这个IP地址
- Linux内核禁止绑定不属于本机的IP地址

即使通过其他方式伪造，防火墙的状态检测（conntrack）也会拦截：
- 伪造的包没有建立过连接记录
- 状态检测会识别为非法包并丢弃

**安全启示：**
- 操作系统层面的IP绑定限制是第一道防线
- conntrack状态检测是第二道防线
- 多层防御确保VPN流量无法被伪造

---

### REJECT vs DROP 分析

| 响应类型 | 攻击者观察 | 信息泄露 | 安全性 |
|:---------|:-----------|:---------|:-------|
| REJECT | 收到ICMP不可达/TCP RST | 确认目标存在 | 低 |
| DROP | 无响应/超时 | 无法判断目标状态 | 高 |

**安全建议：**
- 对外部网络（internet方向）：使用DROP
- 对内部网络（guest方向）：使用REJECT便于排错

---

## 二、防御方日志分析

### 日志攻击特征识别

**1. guest攻击特征：**

| 日志字段 | 值 | 安全含义 |
|:---------|:-----|:---------|
| `IN` | fw-guest | 流量来源：guest区域 |
| `SRC` | 10.30.0.0/24 | 源地址：guest网段 |
| `OUT` | fw-office | 目标出口：office区域 |
| `DST` | 10.20.0.0/24 | 目标地址：office网段 |
| `PROTO` | ICMP/TCP | 攻击类型：扫描/连接 |

**2. VPN攻击特征：**

| 日志字段 | 值 | 安全含义 |
|:---------|:-----|:---------|
| `IN` | wg0 | 流量来源：VPN隧道 |
| `SRC` | 10.10.10.2 | 源地址：VPN用户 |
| `OUT` | fw-dmz | 目标出口：DMZ区域 |
| `DST` | 10.40.0.2:22 | 目标：DMZ SSH服务 |

### 规则防御效果分析

**关键防御规则：**

| 规则 | 作用 | 防御效果 |
|:-----|:-----|:---------|
| `guest→office REJECT` | 阻止guest访问office | ✅ 有效拦截扫描 |
| `guest→dmz REJECT` | 阻止guest访问dmz | ✅ 有效拦截 |
| `internet→dmz:22 REJECT` | 阻止外网SSH | ✅ 有效拦截 |
| `VPN→dmz:22 REJECT` | 阻止VPN SSH | ✅ 有效拦截 |
| `ESTABLISHED,RELATED ACCEPT` | 状态检测 | ✅ 保证合法连接 |

**规则计数器分析：**

| 规则 | 包计数 | 说明 |
|:-----|:-------|:-----|
| `INET-TO-OFFICE` | 12 | 外网访问办公网被拦截 |
| `GUEST-TO-OFFICE` | 4 | guest扫描office被拦截 |
| `GUEST-TO-DMZ` | 6 | guest访问dmz被拦截 |
| `VPN-TO-DMZ-SSH` | 3 | VPN SSH尝试被拦截 |

---

## 三、边界测试与改进方案

### 测试结果

| 测试项 | 结果 | 说明 |
|:-------|:-----|:-----|
| 单个连接 | ✅ 成功 | 返回HTML内容 |
| 4个并发连接 | 3成功1拒绝 | connlimit触发 |
| connlimit计数 | pkts>0 | 规则生效 |

### 改进效果

connlimit规则成功限制了单IP的并发连接数，有效防御DDoS攻击。测试中4个并发连接只有3个成功，超过限制的连接被拒绝。

---

## 四、总结

### 攻防演练核心发现

1. **防火墙规则有效拦截了所有攻击**：扫描、绕过、伪造均失败
2. **日志提供了完整的安全信息**：可追踪攻击来源、目标、类型
3. **规则计数器验证了防御效果**：包计数显示规则被触发
4. **改进方案提升了安全性**：connlimit有效防御DDoS

### 安全建议

1. 对外部网络使用DROP而非REJECT
2. 定期审查防火墙规则和日志
3. 部署连接数限制防止资源耗尽
4. 监控异常流量模式，及时响应


