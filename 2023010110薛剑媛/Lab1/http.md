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
| 请求路径（URI）    |https://www.yxnu.edu.cn/|
| 协议版本           |HTTP/1.1|
| Host               |www.yxnu.edu.cn|
| User-Agent         |Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Mobile Safari/537.36 Edg/146.0.0.0|

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

   > 答：请求行：方法、协议、版本；请求头：Host、Cookie、Accept-Language、User-Agent等17个键值对。

2. 状态码 `404` 代表什么含义？状态码 `500` 和 `503` 有什么区别？

   > 答：`404`代表Not Found，意味着服务器无法找到请求的资源。`500`代表Internal Server Error，服务器遇到了不知道如何处理的情况。`503`代表Service Unavailable，服务器没有准备好处理请求。常见原因是服务器因维护或重载而停机。

3. GET 与 POST 方法的主要区别是什么？各适用于什么场景？

   > 答：GET 用于从服务器获取资源，是安全的（只读操作）、幂等的（多次请求结果相同）。GET：适用于书签、分享链接、搜索引擎查询等只需获取数据的操作。POST 用于向服务器提交数据以创建或更新资源，既不安全也不幂等。POST：适用于登录、表单提交、文件上传、注册、发表评论等会改变服务器状态的操作。

4. HTTP 与 HTTPS 有什么区别？HTTPS 使用了什么机制来保护数据？

   > 答：（1）HTTP是明文传输，HTTPS是加密传输。(2)端口不一样，HTTP使用80端口，HTTPS使用443端口。HTTPS使用了TLS来对数据进行加密，还通过数字证书验证通信方的真实身份，防止中间人攻击，并确保数据在传输过程中未被篡改。

5. 既然 HTTPS 已经加密，为什么浏览器开发者工具仍然能看到请求和响应的明文内容？

   > 答：开发者工具是浏览器内置的调试工具，它在浏览器内部工作：
发送请求时：浏览器先准备好明文请求（包括URL、头部、Cookie等），然后才交给TLS层加密。开发者工具在加密前就已经捕获了这个请求。
接收响应时：浏览器收到加密数据后，先由TLS层解密成明文，然后才交给渲染引擎处理。开发者工具在解密后捕获这个响应。
开发者工具是在“加密之前”和“解密之后”看内容，所以看到的是明文。

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

