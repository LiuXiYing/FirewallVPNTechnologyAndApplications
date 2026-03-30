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
| 请求方法（Method） |post            |
| 请求路径（URI）    |截图中未见                |
| 协议版本           |截图中未见                |
| Host               |mbd.baidu.com   |
| User-Agent         |Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0|

**嵌入截图：**

请求图截图![alt text](req.png)
---


### B. 响应头（Response Headers）

| 字段                  | 你的截图中的值 |
| :-------------------- | :------------- |
| 状态码（Status Code） |200 OK                |
| 状态描述              |截图中未见                |
| Content-Type          |application/json; charset=utf-8     |
| Server（若可见）      |截图中未见           |

**嵌入截图：**

响应头截图![alt text](resp.png)

---

### C. 知识问答

1. HTTP 请求报文由哪几部分构成？请按顺序列出：

   > 答：请求行->请求头->请求体
请求行：请求方法 POST、请求路径：URL,协议版本没有直接显示出来等
请求头（Request Headers）
请求体（Request Body）截图中没有显示

2. 状态码 `404` 代表什么含义？状态码 `500` 和 `503` 有什么区别？

   > 答：状态码 404，含义：Not Found（资源未找到）
   状态码500，含义：Internal Server Error（服务器内部错误：服务器在执行请求时遇到意外情况）
   状态码503，含义：Service Unavailabl（服务不可用：服务器暂时无法处理请求）

3. GET 与 POST 方法的主要区别是什么？各适用于什么场景？

   > 答：主要区别：GET 是获取资源的安全、幂等操作；POST 是操作资源的非安全、非幂等操作。
   GET：用于获取 / 查询资源，无敏感信息的数据，可被缓存 / 分享的数据。
   POST：用于提交 / 修改数据，用于敏感数据传输、大数据量请求、非幂等操作。

4. HTTP 与 HTTPS 有什么区别？HTTPS 使用了什么机制来保护数据？

   > 答：区别：安全性不同：HTTP是明文传输，无加密，不安全，但HTTPS是加密传输，安全可靠
   加密方式不同：HTTP是不加密的，而HTTPS是基于 SSL/TLS 加密的
   默认端口不同：HTTP的默认端口是80，HTTPS的默认端口是443
   HTTPS 安全机制：SSL/TLS + 非对称加密 + 对称加密 + 数字证书 + 完整性校验

5. 既然 HTTPS 已经加密，为什么浏览器开发者工具仍然能看到请求和响应的明文内容？

   > 答：因为 HTTPS 加密的是网络传输过程，浏览器作为 HTTPS 通信的一端，持有解密密钥。开发者工具查看的是浏览器内部处理后的明文数据，而非网络上加密的数据包，因此可以直接看到请求与响应内容。

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

