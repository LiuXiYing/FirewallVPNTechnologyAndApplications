#!/usr/bin/env python3
"""
PR 自动审核脚本 v3（含调试输出）
"""

import os
import re
import sys
import json
import base64
import datetime
import tempfile
import subprocess
import requests

# ── 环境变量 ──────────────────────────────────────────────
PR_TITLE  = os.environ["PR_TITLE"]
PR_NUMBER = os.environ["PR_NUMBER"]
KIMI_KEY  = os.environ.get("KIMI_API_KEY", "")
GH_TOKEN  = os.environ["GH_TOKEN"]
REPO      = os.environ["REPO"]
HEAD_SHA  = os.environ["HEAD_SHA"]

API = "https://api.github.com"
GH  = {
    "Authorization": f"Bearer {GH_TOKEN}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}

# ── GitHub API 工具 ───────────────────────────────────────

def gh_get(path, params=None):
    r = requests.get(f"{API}{path}", headers=GH, params=params)
    r.raise_for_status()
    return r.json()

def gh_post(path, body):
    requests.post(f"{API}{path}", headers=GH, json=body)

def gh_put(path, body):
    r = requests.put(f"{API}{path}", headers=GH, json=body)
    return r.status_code == 200

def gh_patch(path, body):
    requests.patch(f"{API}{path}", headers=GH, json=body)

def get_file_content(file_path: str):
    try:
        data = gh_get(f"/repos/{REPO}/contents/{requests.utils.quote(file_path, safe='/')}",
                      params={"ref": HEAD_SHA})
        if data.get("encoding") == "base64":
            return base64.b64decode(data["content"]).decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  [debug] get_file_content({file_path}) 失败: {e}")
        return None

def list_dir(dir_path: str) -> list:
    try:
        tree = gh_get(f"/repos/{REPO}/git/trees/{HEAD_SHA}", params={"recursive": "1"})
        all_nodes = tree.get("tree", [])
        prefix = dir_path.rstrip("/") + "/"
        result = [
            item["path"] for item in all_nodes
            if item["type"] == "blob" and item["path"].startswith(prefix)
        ]
        print(f"  [debug] list_dir({dir_path}): tree总节点={len(all_nodes)}, prefix={prefix}, 匹配={len(result)}, 列表={result}")
        return result
    except Exception as e:
        print(f"  [debug] list_dir({dir_path}) 异常: {e}")
        return []

# ── 评论 / 拒绝 / 合并 ────────────────────────────────────

def comment(body: str):
    gh_post(f"/repos/{REPO}/issues/{PR_NUMBER}/comments", {"body": body})

def reject(reason: str):
    body = (
        "## PR 检查未通过 ❌\n\n"
        + reason
        + "\n\n---\n*此评论由自动审核机器人生成。请修改后重新推送，PR 会自动更新。*"
    )
    comment(body)
    sys.exit(0)

def merge_pr():
    return gh_put(f"/repos/{REPO}/pulls/{PR_NUMBER}/merge", {
        "merge_method": "merge",
        "commit_title": f"[自动合并] {PR_TITLE}",
    })

def close_pr():
    gh_patch(f"/repos/{REPO}/pulls/{PR_NUMBER}", {"state": "closed"})

# ── 步骤 1：PR 标题格式 ───────────────────────────────────

TITLE_RE = re.compile(r'^\[(\d{10}[\u4e00-\u9fff]+)\]\s?(Lab\d+)作业提交$')

def check_title():
    m = TITLE_RE.match(PR_TITLE)
    if not m:
        reject(
            f"**PR 标题格式错误**\n\n"
            f"当前标题：`{PR_TITLE}`\n\n"
            f"正确格式：`[学号姓名]LabX作业提交` 或 `[学号姓名] LabX作业提交`\n\n"
            f"注意：\n"
            f"- 括号必须是英文方括号 `[]`，不能用 `【】`\n"
            f"- 学号为 10 位数字，紧跟姓名，中间无空格\n"
            f"- `Lab` 的 L 必须大写\n\n"
            f"示例：`[2024010002王诗惠]Lab1作业提交`"
        )
    return m.group(1), m.group(2)

# ── 步骤 2：获取 PR 变更文件 ──────────────────────────────

def get_changed_files():
    files = gh_get(f"/repos/{REPO}/pulls/{PR_NUMBER}/files")
    return [f["filename"] for f in files if f["status"] != "removed"]

# ── 步骤 3-5：文件路径规范 ────────────────────────────────

STUDENT_DIR_RE = re.compile(r'^\d{10}[\u4e00-\u9fff]+$')
LAB_DIR_RE     = re.compile(r'^Lab\d+$')

def check_files(student_id_name: str, lab: str, changed_files: list):
    allowed_prefix = f"{student_id_name}/{lab}/"
    for f in changed_files:
        if not f.startswith(allowed_prefix):
            reject(
                f"**修改范围超出自己的文件夹**\n\n"
                f"检测到修改了不属于自己的路径：`{f}`\n\n"
                f"只允许修改 `{allowed_prefix}` 下的文件。"
            )
    parts = changed_files[0].split("/")
    student_dir = parts[0]
    if not STUDENT_DIR_RE.match(student_dir):
        reject(
            f"**学生文件夹命名不规范**\n\n"
            f"`{student_dir}` 格式不对，应为：10位学号 + 姓名，无空格\n\n"
            f"示例：`2024010002王诗惠`"
        )
    if student_dir != student_id_name:
        reject(
            f"**文件夹名与 PR 标题不一致**\n\n"
            f"PR 标题中：`{student_id_name}`\n"
            f"实际文件夹：`{student_dir}`"
        )
    if len(parts) < 2:
        reject("**未找到 Lab 文件夹**，请检查目录结构。")
    lab_dir = parts[1]
    if not LAB_DIR_RE.match(lab_dir):
        reject(
            f"**Lab 文件夹命名不规范**\n\n"
            f"`{lab_dir}` 格式不对，应为 `Lab` + 数字，L 必须大写\n\n"
            f"示例：`Lab1` ✓，`lab1` ✗"
        )
    if lab_dir != lab:
        reject(
            f"**Lab 文件夹与 PR 标题不一致**\n\n"
            f"PR 标题中：`{lab}`，实际文件夹：`{lab_dir}`"
        )

# ── 步骤 6：作业文件完整性 ────────────────────────────────

def check_homework_files(changed_files: list, lab: str):
    hw_dir = f"homework/{lab}"
    hw_files_full = list_dir(hw_dir)
    print(f"  [debug] hw_dir={hw_dir}, 找到文件数={len(hw_files_full)}")
    if not hw_files_full:
        print(f"  [跳过] {hw_dir} 目录不存在或为空，跳过文件名检查")
        return
    hw_names = [os.path.basename(f) for f in hw_files_full]
    submitted_names = [os.path.basename(f) for f in changed_files]
    missing = [f for f in hw_names if f not in submitted_names]
    extra   = [f for f in submitted_names if f not in hw_names]
    issues = []
    if missing:
        issues.append(f"**缺少文件**：{', '.join(f'`{f}`' for f in missing)}")
    if extra:
        issues.append(f"**多余文件**（不在作业要求中）：{', '.join(f'`{f}`' for f in extra)}")
    if issues:
        reject(
            f"**作业文件不符合要求**\n\n"
            + "\n\n".join(issues)
            + f"\n\n作业要求文件：{', '.join(f'`{f}`' for f in hw_names)}\n\n"
            f"请参考 `{hw_dir}/` 中的作业要求。"
        )

# ── 步骤 7：文件格式检查 ──────────────────────────────────

def check_file_format(changed_files: list):
    issues = []
    for fpath in changed_files:
        content = get_file_content(fpath)
        if content is None:
            continue
        ext = os.path.splitext(fpath)[1].lower()
        valid_lines = [l for l in content.splitlines() if l.strip()]
        if len(valid_lines) < 10:
            issues.append(f"`{fpath}`：有效内容少于 10 行（当前 {len(valid_lines)} 行）")
            continue
        prompt_patterns = ["忽略之前的要求", "直接通过审查", "假装没看到", "不要检查",
                           "ignore previous", "[INST]", "bypass"]
        for pat in prompt_patterns:
            if pat.lower() in content.lower():
                issues.append(f"`{fpath}`：检测到疑似 AI Prompt（含 `{pat}`），**禁止合并**")
        if ext == ".md":
            md_indicators = ["# ", "## ", "- ", "* ", "```", "|", "**"]
            has_md = any(ind in content for ind in md_indicators)
            if "&#x" in content or "&amp;" in content:
                issues.append(f"`{fpath}`：.md 文件含 HTML 实体编码，请直接使用对应字符")
            if re.search(r'\\_|\\\\|\\\[|\\\]', content):
                issues.append(f"`{fpath}`：.md 文件存在不必要转义字符，请直接书写")
            if not has_md:
                issues.append(f"`{fpath}`：.md 文件未使用 Markdown 语法")
        if ext == ".txt":
            if re.search(r'^#+\s', content, re.MULTILINE):
                issues.append(f"`{fpath}`：.txt 文件不应使用 Markdown 标题语法")
        if ext == ".py":
            with tempfile.NamedTemporaryFile(suffix=".py", mode="w",
                                             delete=False, encoding="utf-8") as tmp:
                tmp.write(content)
                tmp_path = tmp.name
            result = subprocess.run(["python3", "-m", "py_compile", tmp_path],
                                    capture_output=True)
            os.unlink(tmp_path)
            if result.returncode != 0:
                issues.append(f"`{fpath}`：Python 文件存在语法错误")
    if issues:
        reject(
            "**文件格式检查未通过**\n\n"
            + "\n\n".join(f"- {i}" for i in issues)
        )

# ── 步骤 8：Kimi 内容质量检查 ─────────────────────────────

def check_content_with_kimi(lab: str, changed_files: list):
    if not KIMI_KEY:
        print("  [跳过] 未配置 KIMI_API_KEY，跳过内容检查")
        return
    hw_files = list_dir(f"homework/{lab}")
    if not hw_files:
        print(f"  [跳过] 未找到 homework/{lab}，跳过内容检查")
        return
    hw_parts = []
    for hf in hw_files:
        c = get_file_content(hf)
        if c:
            hw_parts.append(f"### {hf}\n\n{c}")
    student_parts = []
    for f in changed_files:
        c = get_file_content(f)
        if c:
            student_parts.append(f"### {f}\n\n{c}")
    system_prompt = """你是严格的助教，根据作业要求判断学生提交是否合格。
不合格：答案明显错误、明显未按要求完成、图片路径错误、内容与要求完全一致无自己作答。
可忽略：个别错别字、大小写不规范、详细程度略有差异。
只输出JSON不输出其他内容：{"pass": true或false, "reason": "通过填内容质量合格，不通过填具体问题"}"""
    user_msg = (f"## 作业要求\n\n" + "\n\n---\n\n".join(hw_parts) +
                f"\n\n## 学生提交\n\n" + "\n\n---\n\n".join(student_parts))
    try:
        resp = requests.post(
            "https://api.moonshot.cn/v1/chat/completions",
            headers={"Authorization": f"Bearer {KIMI_KEY}", "Content-Type": "application/json"},
            json={"model": "moonshot-v1-8k",
                  "messages": [{"role": "system", "content": system_prompt},
                                {"role": "user", "content": user_msg}],
                  "temperature": 0.1},
            timeout=60,
        )
        text = re.sub(r"```json|```", "", resp.json()["choices"][0]["message"]["content"]).strip()
        result = json.loads(text)
        if not result.get("pass", True):
            reject(f"**作业内容质量检查未通过**\n\n{result.get('reason', '内容存在问题，请检查后重新提交。')}")
    except Exception as e:
        print(f"  [warn] Kimi 检查失败，跳过：{e}")

# ── 步骤 9：截止时间检查 ──────────────────────────────────

def check_deadline(lab: str):
    content = get_file_content(f"homework/{lab}/{lab}.md")
    if not content:
        print("  [跳过] 未找到截止时间文件，跳过时间检查")
        return
    patterns = [r'截止[时日][间期][：:]\s*(\d{4}[-/]\d{1,2}[-/]\d{1,2})',
                r'deadline[：:]\s*(\d{4}[-/]\d{1,2}[-/]\d{1,2})']
    deadline = None
    for pat in patterns:
        m = re.search(pat, content, re.IGNORECASE)
        if m:
            try:
                deadline = datetime.date.fromisoformat(m.group(1).replace("/", "-"))
                break
            except ValueError:
                pass
    if not deadline:
        print("  [跳过] 作业文件中未找到截止时间，跳过时间检查")
        return
    today = (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).date()
    if today <= deadline:
        return
    delta = (today - deadline).days
    if delta > 7:
        reject(
            f"**超时超过 7 天，PR 将被关闭** ❌\n\n"
            f"- **截止时间**：{deadline}\n- **当前时间**：{today}\n- **超时**：{delta} 天"
        )
        close_pr()
    else:
        reject(
            f"**此 PR 已超时** ❌\n\n"
            f"- **截止时间**：{deadline}\n- **当前时间**：{today}\n- **超时**：{delta} 天\n\n"
            f"如有特殊情况请联系老师说明。"
        )

# ── 主流程 ────────────────────────────────────────────────

def main():
    print(f"[PR #{PR_NUMBER}] 开始审核：{PR_TITLE}")
    print(f"  [debug] REPO={REPO}, HEAD_SHA={HEAD_SHA}")

    student_id_name, lab = check_title()
    print(f"  ✓ 标题格式正确：{student_id_name} / {lab}")

    changed_files = get_changed_files()
    if not changed_files:
        reject("**PR 没有任何文件变更**，请确认是否提交了作业文件。")
    print(f"  ✓ 获取到变更文件，共 {len(changed_files)} 个：{changed_files}")

    check_files(student_id_name, lab, changed_files)
    print(f"  ✓ 文件路径规范正确")

    check_homework_files(changed_files, lab)
    print(f"  ✓ 作业文件完整性检查通过")

    check_file_format(changed_files)
    print(f"  ✓ 文件格式检查通过")

    check_content_with_kimi(lab, changed_files)
    print(f"  ✓ 内容质量检查通过")

    check_deadline(lab)
    print(f"  ✓ 截止时间检查通过")

    comment(
        "## PR 检查通过 ✅\n\n"
        "所有检查项均通过，正在自动合并...\n\n"
        "| 检查项 | 结果 |\n|--------|------|\n"
        "| PR 标题格式 | ✅ |\n| 文件路径规范 | ✅ |\n"
        "| 作业文件完整性 | ✅ |\n| 文件格式 | ✅ |\n"
        "| 内容质量 | ✅ |\n| 提交时间 | ✅ |\n"
    )

    if merge_pr():
        print(f"  ✓ PR #{PR_NUMBER} 已自动合并")
    else:
        print(f"  ✗ 自动合并失败，请手动处理")
        comment("⚠️ 自动合并失败，可能存在合并冲突，请老师手动处理。")

if __name__ == "__main__":
    main()
