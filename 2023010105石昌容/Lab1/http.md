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
| 请求方法（Method） |GET|
| 请求路径（URI）    |https://www.yxnu.edu.cn/index.htm|
| 协议版本           |HTTP/1.1|
| Host               |www.yxnu.edu.cn|
| User-Agent         |Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0|

**嵌入截图：**

![请求头截图](req.png)

---

### B. 响应头（Response Headers）

| 字段                  | 你的截图中的值 |
| :-------------------- | :------------- |
| 状态码（Status Code） |200|
| 状态描述              |OK|
| Content-Type          |text/html|
| Server（若可见）      |none|

**嵌入截图：**

![响应头截图](resp.png)

---

### C. 知识问答

1. HTTP 请求报文由哪几部分构成？请按顺序列出：

   > 答：请求方法、请求URI、协议版本、键值对、空行、请求体

2. 状态码 `404` 代表什么含义？状态码 `500` 和 `503` 有什么区别？

   > 答：404代表Not Found，表示服务器无法找到请求的资源（如页面不存在）。
   500：代表 Internal Server Error，表示服务器在处理请求时发生了意外错误（如代码逻辑错误、数据库异常）。
   503：代表 Service Unavailable，表示服务器暂时无法处理请求（如服务器过载、维护中），通常是临时性的。

3. GET 与 POST 方法的主要区别是什么？各适用于什么场景？

   > 答：主要区别：
   数据位置：GET 把参数放在 URL 里，会直接显示在地址栏；POST 把数据放在请求体中，地址栏不可见。
数据长度：GET 受 URL 长度限制（通常只有几 KB），POST 理论上没有长度限制，由服务器配置决定。
安全性：GET 参数暴露在 URL 中，安全性更低，不适合传递敏感信息；POST 数据在请求体里，相对更安全。
缓存与历史：GET 请求会被浏览器缓存，也会被记录在历史记录里；POST 不会被缓存，也不会保留在历史记录中。
幂等性：GET 是幂等的，多次请求结果一致，适合重复获取数据；POST 不是幂等的，多次提交可能产生重复数据。
GET 适用场景：查询数据（如搜索、列表查询）。
POST 适用场景：提交数据（如表单提交、文件上传、修改数据）。

4. HTTP 与 HTTPS 有什么区别？HTTPS 使用了什么机制来保护数据？

   > 答：HTTP 是明文传输，HTTPS 是加密传输。
HTTP 默认端口是 80，HTTPS 默认端口是 443。
HTTPS 需要 CA 证书验证服务器身份，HTTP 不需要。
HTTPS 使用 TLS/SSL 协议，通过 对称加密（传输数据）、非对称加密（交换密钥）、数字证书（验证身份）三者结合，实现数据的机密性、完整性和身份真实性。


5. 既然 HTTPS 已经加密，为什么浏览器开发者工具仍然能看到请求和响应的明文内容？

   > 答：HTTPS 的加密是在 浏览器与服务器之间的传输链路 上进行的，而浏览器开发者工具是在 浏览器本地 捕获请求和响应数据。
浏览器在发送请求前会先将明文加密后再传输，开发者工具会在加密前捕获明文请求。
浏览器收到加密响应后会先解密，开发者工具会在解密后捕获明文响应。
简单来说：加密是 “传输过程” 的保护，而开发者工具是在浏览器 “加密前 / 解密后” 的环节查看数据。

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

