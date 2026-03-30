# Lab1：又见面了， HTTP/HTTPS！

## 实验背景

HTTP（HyperText Transfer Protocol，超文本传输协议）是应用层最核心的协议之一。每次打开网页，浏览器与服务器之间就在用 HTTP"对话"。

一次典型的 HTTP 交互分为两部分：

```
浏览器 ──── HTTP 请求 ────▶ 服务器
浏览器 ◀─── HTTP 响应 ──── 服务器
```

**请求报文**结构示例：

```http
GET /index.html HTTP/1.1
Host: www.example.com
User-Agent: Mozilla/5.0
Accept: text/html
```

**响应报文**结构示例：

```http
HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: 1234

<html>...</html>
```

HTTPS 在 HTTP 基础上加入了 TLS 加密，报文内容在传输过程中无法被直接读取。但**浏览器开发者工具**运行在加密之前，可以看到完整的明文请求和响应，是分析 HTTP/HTTPS 协议最方便的入门工具。

---

## 实验任务

1. 用 Chrome 或 Edge 浏览器访问任意 **HTTPS** 站点，例如 `https://www.yxnu.edu.cn/`。
2. 按 `F12`（macOS 用 `Command + Option + I`）打开**开发者工具**，切换到 **Network（网络）** 面板。
3. 刷新页面，等待请求列表加载完成。
4. 点击列表中第一条请求（通常是页面本身），在右侧查看 **Headers** 标签页，找到 Request Headers 和 Response Headers。
5. 对请求头区域和响应头区域分别**截图**，并按规范命名（见下方截图要求）。
6. 根据截图，完成下方的知识填空。

> **提示**：开发者工具打开路径：浏览器右上角菜单 → 更多工具 → 开发者工具，或直接右键页面空白处 → 检查。

---

## 截图要求

- 截图须清晰显示开发者工具 Network 面板中的 **Headers** 区域，能看到具体字段名和值。
- 截图文件与本 `http.md` 放在**同一目录**下。
- 命名规范：

| 截图内容                       | 文件名                                 |
| :----------------------------- | :------------------------------------- |
| Request Headers（请求头）截图  | `req.png`    ( jpg 或 jpeg 格式也可以) |
| Response Headers（响应头）截图 | `resp.png`  ( jpg或 jpeg 格式也可以)   |

截图示例位置（填写时直接在下方嵌入）：

```markdown
![请求头截图](req.png)
![响应头截图](resp.png)
```

---

## 知识填空

> 根据你的截图，填写以下空白处。不确定的字段请写"截图中未见"，**不得留空不填**。

### A. 请求头（Request Headers）

| 字段               | 你的截图中的值 |
| :----------------- | :------------- |
| 请求方法（Method） |    GET          |
| 请求路径（URI）    |        /        |
| 协议版本           |    HTTP/1.1    |
| Host               | www.yxnu.edu.cn  |
| User-Agent         |  Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0              |

**嵌入截图：**

![请求头截图](req.png)

---

### B. 响应头（Response Headers）

| 字段                  | 你的截图中的值 |
| :-------------------- | :------------- |
| 状态码（Status Code） |      200          |
| 状态描述              |     OK           |
| Content-Type          |    text/html            |
| Server（若可见）      |      none          |

**嵌入截图：**

![响应头截图](resp.png)

---

### C. 知识问答

1. HTTP 请求报文由哪几部分构成？请按顺序列出：

   > 答：请求行，请求头，空行，请求体

2. 状态码 `404` 代表什么含义？状态码 `500` 和 `503` 有什么区别？

   > 答：404 Not Found：表示服务器无法找到请求的资源，通常是 URI 输入错误、资源已删除或路径不存在。
500 Internal Server Error：服务器在处理请求时发生了未知错误，属于服务器端代码或配置异常。
503 Service Unavailable：服务器当前无法处理请求，通常是临时过载、维护中或资源耗尽。

3. GET 与 POST 方法的主要区别是什么？各适用于什么场景？

   > 答：参数位置：GET 参数在 URL 中可见，POST 参数在请求体中隐藏。
数据长度：GET 受 URL 长度限制（约 2KB~8KB），POST 理论无长度限制。
安全性：GET 参数易泄露，不适合敏感数据；POST 更隐蔽，需配合 HTTPS 保障安全。
缓存与幂等：GET 可缓存、幂等（多次请求结果一致）；POST 默认不缓存、非幂等。
语义：GET 用于获取资源，POST 用于提交 / 修改资源。
GET：查询数据、获取页面、资源检索
POST：提交表单、上传文件、修改数据

4. HTTP 与 HTTPS 有什么区别？HTTPS 使用了什么机制来保护数据？

   > 答：传输方式：HTTP 以明文传输，数据易被窃听、篡改；HTTPS 以加密方式传输，数据更安全。
端口：HTTP 默认端口 80，HTTPS 默认端口 443。
证书：HTTPS 需要 CA 颁发的 SSL/TLS 证书，用于验证服务器身份，HTTP 无需证书。
性能：HTTPS 因加密 / 解密过程，性能略低于 HTTP
身份认证：通过数字证书验证服务器身份，防止中间人攻击。
数据加密：使用对称加密加密传输数据，保证数据机密性。
完整性校验：通过哈希算法生成消息摘要，防止数据被篡改。
密钥交换：通过非对称加密安全交换对称加密密钥，避免密钥泄露。

5. 既然 HTTPS 已经加密，为什么浏览器开发者工具仍然能看到请求和响应的明文内容？

   > 答：HTTPS 的加密是端到端传输加密，保护的是客户端与服务器之间的网络传输链路，而非客户端本地

---

## 提交要求

在自己的文件夹下新建 `Lab1/` 目录，提交以下文件：

```
学号姓名/
└── Lab1/
    ├── http.md     # 本文件（填写完整）
    ├── req.png       # HTTP 请求截图 (除 png 外，使用 jpg 或者 jpeg 格式也可以)
    └── resp.png      # HTTP 响应截图 (除 png 外，使用 jpg 或者 jpeg 格式也可以) 
```

---

## 截止时间

2026-3-26，届时关于 Lab1 的 PR 请求将不会被合并。

---

## 参考资料

- [HTTP - MDN Web Docs](https://developer.mozilla.org/zh-CN/docs/Web/HTTP)
- [HTTP 状态码列表 - MDN](https://developer.mozilla.org/zh-CN/docs/Web/HTTP/Status)

