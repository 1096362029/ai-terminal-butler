# AI 终端助手 使用说明

一个小小的终端命令行 AI 小工具，只要配置好 API Key，就可以让ai帮你做些事情。

适合 1GB 内存 ARMv7 低配服务器的 AI 命令行助手。纯 Python 标准库实现，无第三方依赖。

- 支持：DeepSeek / Kimi / OpenAI / 本地模型（llama.cpp 等兼容 OpenAI 格式的服务）
- 特性：多轮对话、命令建议、一键确认执行、高危命令拦截、执行日志

## 一、安装

将安装脚本上传到服务器后执行（需要 root 权限，会写入 `/usr/local/bin/ai`）：

```bash
bash ai-terminal-butler-install.sh
```

## 二、配置 API Key

助手支持三种服务商的 API Key，对应的环境变量如下：

| 服务商   | 环境变量           |
| -------- | ------------------ |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Kimi     | `KIMI_API_KEY`     |
| OpenAI   | `OPENAI_API_KEY`   |

> 下文所有示例均以 DeepSeek 为例。使用其他服务商时，把示例中的变量名替换为上表对应值即可，同时记得按第五节切换 `API_PROVIDER`。

### 方式一：直接临时导出（最快）

```bash
export DEEPSEEK_API_KEY=sk-aaaaaaaa
ai
```

一行搞定，立即生效，无需改任何文件。但要注意：

- **只对当前 SSH 会话有效**，断开重连后需要重新 export
- 命令会留在 shell 历史里（`~/.bash_history`），Key 可能被泄露
- 用 `echo $DEEPSEEK_API_KEY` 或 `env` 能直接看到明文 Key

适合临时测试、个人玩票使用。**不建议在生产服务器中使用本工具**——它就是个图省事的 AI 小工具，不是经过严格验证的运维软件；个人服务器随便用，生产环境请三思。

> 补充技巧：export 后如果不想让 Key 留在历史记录，可先执行 `export HISTCONTROL=ignorespace`，然后在 export 命令前加一个空格输入，该条命令就不会被记录（bash 默认支持）。

### 方式二：密钥文件 + bashrc（推荐，永久生效）

#### 1. 创建密钥文件

```bash
nano ~/.env
```

写入你的 API Key（按实际使用的服务商填写）：

```bash
DEEPSEEK_API_KEY=sk-你的Key
```

保存退出（Ctrl+O 回车保存，Ctrl+X 退出）。

#### 2. 收紧文件权限

```bash
chmod 600 ~/.env
```

只有当前用户可读写，避免 Key 泄露。

#### 3. 当前会话立即生效

```bash
export $(cat ~/.env | xargs)
```

#### 4. 永久生效（写入 bashrc）

```bash
echo 'export $(cat ~/.env | xargs)' >> ~/.bashrc
source ~/.bashrc
```

这样每次登录服务器都会自动加载 `~/.env` 里的环境变量，之后直接运行 `ai` 即可。

> 换用其他服务商时，在 `~/.env` 中写对应的变量名：
>
> - Kimi：`KIMI_API_KEY=你的Key`
> - OpenAI：`OPENAI_API_KEY=你的Key`
>
> 注意：切换服务商还需要修改脚本内的 `API_PROVIDER` 配置（见第五节）。

### 方式三：本地模型（无需 API Key）

如果你在局域网或本机上用 llama.cpp 的 `llama-server`（或 vLLM、ollama 等任何兼容 OpenAI chat completions 格式的服务）部署了模型（如 MiniCPM、Qwen 等），可以让助手直接调用本地模型，**无需 API Key、不联网、零费用**。

先在服务器上启动 llama.cpp 服务（示例）：

```bash
# 默认监听 8080 端口，提供 /v1/chat/completions 接口
./llama-server -m 你的模型.gguf --port 8080
```

然后在 `~/.env` 中追加服务地址（llama.cpp 默认端口是 8080，按实际修改）：

```bash
LOCAL_API_BASE=http://127.0.0.1:8080
# 可选：指定模型名，llama.cpp 不校验该值，仅作展示
LOCAL_MODEL=MiniCPM
```

重新加载环境变量 `source ~/.bashrc`，并把 `API_PROVIDER` 改为 `"local"`（见第五节）即可。

> 说明：
>
> - llama.cpp 默认不校验 API Key，无需配置；如果服务开了 `--api-key`，再配置 `LOCAL_API_KEY=你的Key` 即可
> - 本地模型推理较慢（尤其低配 ARM 设备），脚本已自动把超时放宽到 300 秒，"AI 思考中..." 等久一点属正常现象
> - 小模型（如 1~3B）对复杂命令的理解不如 DeepSeek 等大模型，建议仍然留意高危命令警告

## 三、使用

```bash
ai
```

启动后进入交互界面：

```
🤖 AI 助手已启动 (Provider: deepseek)
   输入问题让 AI 帮忙，输入 exit 退出
   AI 给出的命令会询问你是否执行
--------------------------------------------------

你 > 查看磁盘占用情况
```

### 交互流程

1. 直接输入问题（如"nginx 起不来了帮我排查"），AI 会给出分析和命令。
2. AI 回复中的代码块命令会被提取出来，询问是否执行：
   - `Y` 或直接回车：执行
   - `n`：取消
   - `s`：跳过（不执行，继续对话）
3. 命令执行后，输出结果会自动反馈给 AI 继续分析，形成排查闭环。

### 退出方式

输入 `exit`、`quit`、`q`，或按 `Ctrl+C` / `Ctrl+D` 退出。

## 四、高危命令保护

以下类型的命令会触发红色高危警告，必须**手动输入 `yes`** 才会执行，其它任意输入都会取消：

- `rm` 删除文件/目录
- `mkfs` 格式化文件系统
- `dd` 直接写入磁盘设备
- `shutdown` / `reboot` / `poweroff` / `halt` / `init 0|6` 关机重启
- `chmod -R 777 /` 根目录全盘开放权限
- 覆盖写磁盘设备（`> /dev/sd*` 等）
- fork 炸弹

## 五、切换服务商

**方式一：启动时用环境变量临时切换（推荐，不改文件）**

```bash
# 临时用本地模型启动一次
AI_PROVIDER=local ai

# 临时用 Kimi 启动一次
AI_PROVIDER=kimi ai
```

只对当次启动生效，退出后下次仍是默认服务商。

**方式二：改默认值**

编辑 `/usr/local/bin/ai` 第 26 行：

```python
API_PROVIDER = os.environ.get("AI_PROVIDER", "deepseek").lower()   # 可选: deepseek / kimi / openai / local
```

把 `"deepseek"` 改成 `kimi`、`openai` 或 `local` 即可永久生效。也可以把 `AI_PROVIDER=local` 写进 `~/.env`（配合第二节的方式二），登录后自动生效。

无论哪种方式，都要确保对应的环境变量已配置（本地模型需配置 `LOCAL_API_BASE`）。

### 自定义 API 地址、模型 ID 和 Key

想用第三方中转、私有部署网关，或指定其它模型 ID / Key 时，不用改代码，通过三个环境变量覆盖当前服务商的默认值：

| 环境变量      | 作用            | 示例                         |
| ------------- | --------------- | ---------------------------- |
| `AI_API_BASE` | 自定义 API 地址 | `https://api.example.com/v1` |
| `AI_MODEL`    | 自定义模型 ID   | `deepseek-r1` / `gpt-4o` 等  |
| `AI_API_KEY`  | 自定义 API Key  | `sk-xxxx`                    |

```bash
# 临时使用（对当前服务商生效）
AI_API_BASE=https://api.example.com/v1 AI_MODEL=my-model AI_API_KEY=sk-xxxx ai

# 永久使用：写入 ~/.env 后 source ~/.bashrc
AI_API_BASE=https://api.example.com/v1
AI_MODEL=my-model
AI_API_KEY=sk-xxxx
```

说明：

- `AI_API_BASE` 只需填到 `/v1` 即可，程序会自动补全 `/chat/completions`；填了完整地址则原样使用。
- 三个变量都是可选的，只设置其中一个就只覆盖那一项。
- `AI_API_KEY` 设置后优先于 `DEEPSEEK_API_KEY` / `KIMI_API_KEY` / `OPENAI_API_KEY`；不设置则仍使用当前服务商对应的 Key。
- 不知道该挂到哪个服务商名下时，保持默认 `AI_PROVIDER=deepseek`，三个 `AI_*` 变量全设置即可，效果等同于直接使用自定义接口。

## 六、执行日志

每次确认执行的命令及其输出，会按天记录到家目录下：

```
~/.ai-log/ai-YYYY-MM-DD.log
```

方便事后审计 AI 到底执行了什么。注意：目录在第一次确认执行命令时才会创建，只聊天不执行命令是看不到日志的。

## 七、常见问题

**提示"请先设置 API Key 环境变量"**

环境变量没加载。执行 `export $(cat ~/.env | xargs)`，或检查 `~/.bashrc` 中是否已追加该行并 `source ~/.bashrc`。

**`~/.env` 能写多个变量吗？**

可以，每行一个 `KEY=VALUE`，`export $(cat ~/.env | xargs)` 会全部导出。注意值中不要包含空格。

**退格键显示 `^H`？**

脚本启动时已自动执行 `stty erase ^h` 修复串口终端的退格问题，无需手动处理。

**卸载**

上传项目中的 `uninstall.sh` 到服务器后执行：

```bash
bash uninstall.sh
```

脚本会自动删除主程序 `/usr/local/bin/ai`、清理 `~/.bashrc` 配置和日志目录 `~/.ai-log`；`~/.env` 中的 API Key（DeepSeek / Kimi / OpenAI 三种）会询问后再删除，只删 Key 行、保留文件里的其它内容。

## 八、免责声明

本项目只是一个方便个人使用的 AI 命令行小工具，按"现状"提供，不作任何明示或默示的保证：

1. **AI 生成的命令不保证正确**。即使有高危命令拦截，也不能覆盖所有危险场景。执行任何命令前请自行判断后果，确认执行即代表你接受相应风险。
2. **数据与系统安全自负**。因使用本工具执行命令导致的任何数据丢失、服务中断、系统损坏或其他损失，由使用者自行承担。
3. **API Key 安全自负**。请妥善保管 API Key，避免泄露；因 Key 泄露产生的费用或损失与本项目无关。
4. **不建议在生产环境使用**。生产服务器请使用成熟的、经过验证的运维方案。
5. 使用本项目即表示你已阅读、理解并同意上述条款。
