cat > /usr/local/bin/ai << 'SCRIPT'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AI 助手 - 适合 1GB ARMv7 低内存服务器
支持：DeepSeek / Kimi / OpenAI
特性：多轮对话、命令建议、一键确认执行
"""

import datetime
import json
import os
import re
import socket
import subprocess
import sys
import urllib.request

# 让 input() 支持退格、方向键、历史记录（部分精简版 Python 没编译 readline）
try:
    import readline
except ImportError:
    pass

# ==================== 配置 ====================
# 服务商可用环境变量 AI_PROVIDER 临时切换（如 AI_PROVIDER=local ai），也可直接改这里的默认值
API_PROVIDER = os.environ.get("AI_PROVIDER", "deepseek").lower()   # 可选: deepseek / kimi / openai / local

# 本地模型配置（llama.cpp / vllm / ollama 等兼容 OpenAI 格式的服务）
# 用法: export LOCAL_API_BASE=http://127.0.0.1:8080 并以 AI_PROVIDER=local 启动
LOCAL_API_BASE = os.environ.get("LOCAL_API_BASE", "http://127.0.0.1:8080").rstrip("/")
LOCAL_MODEL = os.environ.get("LOCAL_MODEL", "local-model")

API_CONFIG = {
    "deepseek": {
        "url": "https://api.deepseek.com/chat/completions",
        "model": "deepseek-v4-flash",
        "key": os.environ.get("DEEPSEEK_API_KEY", "")
    },
    "kimi": {
        "url": "https://api.moonshot.cn/v1/chat/completions",
        "model": "kimi-latest",
        "key": os.environ.get("KIMI_API_KEY", "")
    },
    "openai": {
        "url": "https://api.openai.com/v1/chat/completions",
        "model": "gpt-4o-mini",
        "key": os.environ.get("OPENAI_API_KEY", "")
    },
    "local": {
        "url": f"{LOCAL_API_BASE}/v1/chat/completions",
        "model": LOCAL_MODEL,
        # llama.cpp 默认不校验 key，随便填一个占位即可
        "key": os.environ.get("LOCAL_API_KEY", "local-no-key")
    }
}

# 自定义 API 地址、模型 ID 和 Key（可选，对当前服务商生效，优先级最高）
# 用法: AI_API_BASE=https://api.example.com/v1 AI_MODEL=my-model AI_API_KEY=sk-xxx ai
# AI_API_BASE 只需填到 /v1 即可，程序自动补全 /chat/completions；填完整地址则原样使用
# AI_API_KEY 设置后优先于 DEEPSEEK_API_KEY / KIMI_API_KEY / OPENAI_API_KEY 使用
CUSTOM_API_BASE = os.environ.get("AI_API_BASE", "").strip()
CUSTOM_MODEL = os.environ.get("AI_MODEL", "").strip()
CUSTOM_API_KEY = os.environ.get("AI_API_KEY", "").strip()
if CUSTOM_API_BASE:
    _base = CUSTOM_API_BASE.rstrip("/")
    API_CONFIG[API_PROVIDER]["url"] = _base if _base.endswith("/chat/completions") else _base + "/chat/completions"
if CUSTOM_MODEL:
    API_CONFIG[API_PROVIDER]["model"] = CUSTOM_MODEL
if CUSTOM_API_KEY:
    API_CONFIG[API_PROVIDER]["key"] = CUSTOM_API_KEY

# 本地模型推理较慢（尤其低配 ARM 设备），超时给更长；可用 AI_API_TIMEOUT 自定义（秒）
API_TIMEOUT = int(os.environ.get("AI_API_TIMEOUT", 300 if API_PROVIDER == "local" else 120))

# 系统信息模板（让 AI 了解环境）
SYS_INFO = f"""你是 Linux 系统管理员助手。
当前服务器信息：
- CPU: {os.popen("grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2").read().strip() or 'Unknown'}
- 架构: {os.popen('uname -m').read().strip()}
- 内核: {os.popen('uname -r').read().strip()}
- 内存: {os.popen("free -h | grep Mem | awk '{print $2}'").read().strip()}
- 系统: {os.popen('grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | xargs').read().strip() or 'Unknown'}
- 当前用户: {os.popen('whoami').read().strip()}
- 当前目录: {os.getcwd()}

回答要简洁。如果需要执行命令，请用 ```bash 代码块包裹。用户确认后会自动执行。"""

# ==================== 核心函数 ====================

def call_api(messages):
    """调用大模型 API"""
    cfg = API_CONFIG[API_PROVIDER]
    
    data = json.dumps({
        "model": cfg["model"],
        "messages": messages,
        "temperature": 0.3
    }).encode('utf-8')
    
    req = urllib.request.Request(
        cfg["url"],
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cfg['key']}"
        },
        method="POST"
    )
    
    last_err = None
    for attempt in range(2):  # 超时自动重试一次，网络抖动时不至于直接失败
        try:
            with urllib.request.urlopen(req, timeout=API_TIMEOUT) as resp:
                result = json.loads(resp.read().decode('utf-8'))
                return result['choices'][0]['message']['content']
        except (socket.timeout, TimeoutError) as e:
            last_err = e
            if attempt == 0:
                print(f"\033[33mAPI 响应超时，重试中...\033[0m")
        except Exception as e:
            return f"API 调用失败: {e}"
    return f"API 调用失败: {last_err}"

def extract_commands(text):
    """从 AI 回复中提取 bash 命令块"""
    # 匹配任意语言标签的代码块（bash/sh/shell/console/无标签等）
    pattern = r'```[a-zA-Z0-9_-]*[ \t]*\r?\n(.*?)\r?\n[ \t]*```'
    matches = re.findall(pattern, text, re.DOTALL)
    return [cmd.strip() for cmd in matches if cmd.strip()]

# 高危命令特征：(正则, 风险说明)
DANGEROUS_PATTERNS = [
    (r'\brm\b', "删除文件或目录 (rm)"),
    (r'\bmkfs(\.\w+)?\b', "格式化文件系统 (mkfs)"),
    (r'\bdd\b[^|;&]*of=/dev/', "直接写入磁盘设备 (dd)"),
    (r'\b(shutdown|reboot|poweroff|halt)\b', "关机或重启"),
    (r'\binit\s+[06]\b', "关机或重启 (init 0/6)"),
    (r'chmod\s+(-\w+\s+)*-R\s+777\s+/\s*$', "根目录全盘开放权限 (chmod -R 777 /)"),
    (r'>\s*/dev/(sd|hd|nvme|mmcblk|vd)', "覆盖磁盘设备"),
    (r':\(\)\s*\{\s*:\|:\s*&\s*\}\s*;\s*:', "fork 炸弹"),
]

def check_dangerous(cmd):
    """返回命中的高危项列表，空列表表示无高危特征"""
    risks = []
    for pat, desc in DANGEROUS_PATTERNS:
        if re.search(pat, cmd):
            risks.append(desc)
    return risks

LOG_DIR = os.path.expanduser("~/.ai-log")

def log_command(cmd, output=None):
    """按日记录命令执行日志: ~/.ai-log/ai-YYYY-MM-DD.log"""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        logfile = os.path.join(LOG_DIR, "ai-%s.log" % datetime.date.today().isoformat())
        with open(logfile, "a", encoding="utf-8") as f:
            now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            f.write("[%s] 执行: %s\n" % (now, cmd))
            if output is not None:
                f.write("--- 输出 ---\n%s\n--- 结束 ---\n" % output)
    except Exception:
        pass  # 日志失败不影响主流程

def execute_command(cmd):
    """执行命令并返回输出"""
    print(f"\n\033[33m[执行] {cmd}\033[0m")
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=300
        )
        output = result.stdout + result.stderr
        if not output.strip():
            output = "(命令执行成功，无输出)"
        return output
    except subprocess.TimeoutExpired:
        return "(命令执行超时)"
    except Exception as e:
        return f"(执行失败: {e})"

def confirm_and_execute(messages, reply, max_rounds=5):
    """显示回复、提取命令并询问执行；执行结果反馈 AI 后，新建议里的命令同样走确认流程"""
    current = reply
    for _ in range(max_rounds):  # 限制轮数，防止 AI 无限追加命令
        print(f"\n\033[32mAI >\033[0m {current}")

        commands = extract_commands(current)
        executed = False
        for cmd in commands:
            risks = check_dangerous(cmd)
            try:
                if risks:
                    print(f"\n\033[41;37m *** 高危命令警告 ***\033[0m")
                    print(f"\033[1;31m 命令: {cmd}\033[0m")
                    for r in risks:
                        print(f"\033[1;31m  ⚠ {r}\033[0m")
                    confirm = input("\033[1;31m此命令可能造成不可逆的破坏! 请输入 yes 确认执行，其它任意内容取消: \033[0m").strip().lower()
                else:
                    confirm = input(f"\n\033[33m是否执行命令: {cmd}\n[Y/n/s(跳过)] \033[0m").strip().lower()
            except (EOFError, KeyboardInterrupt):
                confirm = "n"

            if risks:
                confirmed = (confirm == "yes")
            else:
                confirmed = confirm in ("", "y", "yes")

            if confirmed:
                output = execute_command(cmd)
                print(f"\033[90m{output}\033[0m")
                log_command(cmd, output)
                # 把执行结果反馈给 AI，方便继续排查
                messages.append({"role": "user", "content": f"命令执行结果:\n{output}"})
                executed = True
            elif confirm == "s":
                print("已跳过")
            else:
                print("已取消执行")

        # 没有执行任何命令，或 AI 没有后续建议，结束本轮
        if not executed:
            break

        print("\n\033[35mAI 分析结果中...\033[0m")
        current = call_api(messages)
        messages.append({"role": "assistant", "content": current})
        # 若跟进回复里没有新命令，打印后自然结束
        if not extract_commands(current):
            print(f"\n\033[32mAI >\033[0m {current}")
            break

def main():
    # 修复串口/终端退格键显示 ^H 的问题（把 tty 擦除符设为 ^H）
    os.system("stty erase ^h 2>/dev/null")

    # 检查服务商名是否有效（防止 AI_PROVIDER 写错）
    if API_PROVIDER not in API_CONFIG:
        print(f"错误: 未知的服务商 '{API_PROVIDER}'，可选: deepseek / kimi / openai / local")
        sys.exit(1)

    # 检查 API Key（通过环境变量传入；local 模式无需 Key，只检查服务地址）
    cfg = API_CONFIG[API_PROVIDER]
    if API_PROVIDER == "local":
        print(f"本地模型服务: {cfg['url']} (模型: {cfg['model']})")
    else:
        env_name = {"deepseek": "DEEPSEEK_API_KEY", "kimi": "KIMI_API_KEY", "openai": "OPENAI_API_KEY"}[API_PROVIDER]
        if not cfg["key"]:
            print("错误: 请先设置 API Key 环境变量")
            print(f"  export AI_API_KEY=sk-你的Key          # 通用 Key，对当前服务商生效")
            print(f"  export {env_name}=sk-你的Key   # 或用该服务商专用的 Key")
            sys.exit(1)
    
    # 初始化对话
    messages = [{"role": "system", "content": SYS_INFO}]
    
    print(f"🤖 AI 助手已启动 (Provider: {API_PROVIDER} | 模型: {cfg['model']})")
    print("   输入问题让 AI 帮忙，输入 exit 退出")
    print("   AI 给出的命令会询问你是否执行")
    print("-" * 50)
    
    while True:
        try:
            user_input = input("\n\033[36m你 >\033[0m ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n再见!")
            break
        
        if user_input.lower() in ("exit", "quit", "q"):
            print("再见!")
            break
        if not user_input:
            continue
        
        # 发送请求
        messages.append({"role": "user", "content": user_input})
        print("\n\033[35mAI 思考中...\033[0m")
        reply = call_api(messages)
        messages.append({"role": "assistant", "content": reply})
        
        # 显示回复、提取命令并询问是否执行（跟进建议同样走确认流程）
        confirm_and_execute(messages, reply)

if __name__ == "__main__":
    main()
SCRIPT

chmod +x /usr/local/bin/ai