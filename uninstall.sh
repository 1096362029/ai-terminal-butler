#!/bin/bash
# AI 终端助手 卸载脚本
# 用法: bash uninstall.sh

echo "=== AI 终端助手 卸载 ==="

# 1. 删除主程序
if [ -f /usr/local/bin/ai ]; then
    rm -f /usr/local/bin/ai
    echo "已删除主程序 /usr/local/bin/ai"
else
    echo "未找到 /usr/local/bin/ai，跳过"
fi

# 2. 清理 ~/.bashrc 中的环境变量加载行
if grep -q 'export $(cat ~/.env | xargs)' ~/.bashrc 2>/dev/null; then
    sed -i '\#export \$(cat ~/\.env | xargs)\#d' ~/.bashrc
    echo "已清理 ~/.bashrc 中的加载配置"
else
    echo "~/.bashrc 中没有相关配置，跳过"
fi

# 3. 删除日志目录
if [ -d ~/.ai-log ]; then
    rm -rf ~/.ai-log
    echo "已删除日志目录 ~/.ai-log"
fi

# 4. 询问是否删除 API Key（只删 Key 那几行，保留文件里的其它内容）
if [ -f ~/.env ] && grep -qE '^(DEEPSEEK|KIMI|OPENAI)_API_KEY=' ~/.env; then
    read -p "是否删除 ~/.env 中的 API Key? [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        sed -i -E '/^(DEEPSEEK|KIMI|OPENAI)_API_KEY=/d' ~/.env
        echo "已删除 ~/.env 中的 API Key（DEEPSEEK / KIMI / OPENAI）"
        if [ ! -s ~/.env ]; then
            rm -f ~/.env
            echo "~/.env 已为空，一并删除"
        fi
    else
        echo "已保留 ~/.env 中的 API Key"
    fi
fi

# 5. 提示清理当前会话残留的环境变量
if [ -n "$DEEPSEEK_API_KEY" ] || [ -n "$KIMI_API_KEY" ] || [ -n "$OPENAI_API_KEY" ]; then
    echo "提示: 当前会话仍残留 API Key 环境变量，可执行以下命令清除："
    echo "  unset DEEPSEEK_API_KEY KIMI_API_KEY OPENAI_API_KEY"
fi

echo "卸载完成。"
