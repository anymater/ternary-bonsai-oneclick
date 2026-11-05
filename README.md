# Ternary Bonsai 2 27B · Windows 一键整合包

把 [Ternary Bonsai 2 27B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)（1.75 bpw 三值量化，5.95 GB，262K 原生上下文）在 Windows 上变成**双击就能用**的本地服务：

```
双击 install.bat   →  自动检测显卡、下载官方引擎与模型、校验、写配置
双击 start.bat     →  加载模型、打开 Web 界面、打印局域网地址与访问密钥
```

不需要 Python、不需要 CUDA Toolkit、不需要编译、不需要科学上网（国内走 ModelScope）。

---

## 这是一个"薄壳"整合包，不是 7.7 GB 的压缩包

这点先说清楚，因为它决定了这个项目值不值得用：

| 做法 | 问题 |
|---|---|
| 把引擎 + 模型打成一个包（约 7.7 GB） | 单个文件远超 GitHub Release 的 2 GB 上限；模型一更新整包作废；只能传网盘，用户还得再下一遍 |
| **安装时从官方源拉取 + SHA256 校验**（本项目） | 仓库只有 ~50 KB；模型/引擎永远是最新的官方件；断点续传、可重复执行 |

所以本仓库**不包含任何权重和二进制**，只包含：

1. **安装器**：检测硬件 → 选对版本 → 双源下载 → SHA256 校验 → 解压 → 写配置
2. **启动器层**（这才是本项目真正的价值）：中文 Windows 双击即用、API 密钥、局域网共享、状态诊断、DSH/OpenAI 客户端接入

官方已经有 [`Bonsai-demo`](https://github.com/PrismML-Eng/Bonsai-demo)（`setup.sh` 自动拉取权重和二进制）。本项目不重复造它，补的是它在 Windows 上缺的那一层：

| 能力 | 官方 Bonsai-demo | 本项目 |
|---|---|---|
| Windows 一键安装 | 部分（零散 `.ps1`） | `install.bat` 双击 |
| 自动选对 CUDA 版本 | 有 | 有（按驱动版本判定） |
| **API 密钥** | 无（默认无鉴权） | 自动生成，`/v1/*` 强制 Bearer |
| **局域网 / 手机访问** | 需手动改 host，且无鉴权 | 一条防火墙命令 + 密钥 |
| **中文界面的状态诊断** | 无 | `status.bat` 一屏看完 |
| **功能菜单** | 无 | `menu.bat` 选编号 |
| 一键关闭 / 释放显存 | 无 | `stop.bat`，按路径精确筛选，不误杀 LM Studio |

---

## 快速开始

1. 下载本仓库（`Code` → `Download ZIP`，或 `git clone`）。
2. 解压到一个**路径不含中文**的目录，例如 `D:\Bonsai`。
3. 双击 **`install.bat`**。首次安装约需下载 **0.6 ~ 0.8 GB 引擎 + 5.95 GB 模型**，取决于你的显卡。
4. 安装完成后双击 **`start.bat`**。几秒内会打印访问地址和密钥，并自动打开 Web 界面。

想先只装引擎、模型自己放：`install.bat --skip-model`。
想连图片输入一起装：`install.bat --vision`（多下载 0.63 GB 视觉投影器）。
下载慢想加并发：`install.bat --parts 16`。

> 安装可重复执行。已存在且 SHA256 校验通过的文件会被跳过，中断了直接重跑即可。

---

## 硬件要求与自动选型

`install.bat` 会读 `nvidia-smi` 判断该用哪个版本，规则写在 `tools/detect.ps1` 里，逻辑透明可改：

| 检测到 | 选用 | 依据 |
|---|---|---|
| 驱动 ≥ 580 | `win-cuda-13.3-x64`（198 MB） | CUDA 13 要求驱动 580+ |
| 驱动 550–579 | `win-cuda-12.4-x64`（355 MB） | CUDA 12.4 要求驱动 550+ |
| 驱动 < 550 | `win-vulkan-x64`（29 MB） | 驱动太老，CUDA 版加载不了 |
| 没有 NVIDIA 显卡 | `win-cpu-x64`（21 MB） | 能跑但很慢，27B 建议至少 8 GB 显存 |

模型档与上下文：

| 显存 | 模型档 | 上下文 | 说明 |
|---|---|---|---|
| ≥ 20 GB | `PQ2_0`（7.21 GB） | 按下面规则 | prefill 更快，值得多占 1.3 GB |
| < 20 GB | `PTQ1_0`（5.95 GB） | 按下面规则 | 最省显存，默认选择 |
| ≥ 11 GB | — | 131072 | 实测 12 GB 卡开 128K 占 10.67 GB |
| ≥ 9 GB | — | 65536 | |
| ≥ 7 GB | — | 32768 | |
| < 7 GB | — | 16384 | 权重本身 5.95 GB，很紧 |

CUDA 运行时是通过官方 Release 附带的 `cudart` 包解压到 `runtime\bin\` 实现**应用本地加载**的，所以**用户机器不需要安装 CUDA Toolkit**。这一点是实测验证过的：把 PATH 里的 CUDA 目录全部去掉后 `llama-server.exe --version` 仍正常。

---

## 功能模块

根目录三个入口，真正实现在 `launcher\`。下表耗时都是在这台机器（RTX 4070 Ti 12 GB / 驱动 617.42）上实跑测出来的。

| 双击 | 作用 | 实测 |
|---|---|---|
| `install.bat` | 一键安装：检测 → 下载 → 校验 → 解压 → 写配置 | 复装幂等；引擎/模型已存在时靠 SHA256 跳过 |
| `start.bat` | **一键启动**：加载模型 → 打印地址与密钥 → 打开 Web 界面 | 冷启动 3 秒（mmap + 页缓存热）；已在运行时 0.2 秒返回，不起第二实例 |
| `stop.bat` | **一键关闭**：只杀本目录启动的进程，释放显存 | 2.5 秒，显存 10667 → 281 MiB |
| `menu.bat` | 功能菜单，1–6 选编号 | — |
| `launcher\status.bat` | 状态诊断：健康码 / 进程与路径 / 真实上下文 / 槽位 / 显存 / 防火墙 / 局域网 IP | 4 秒一屏 |
| `launcher\restart.bat` | 停 + 起 | 4 秒 |
| `launcher\open-ui.bat` | 只开浏览器，不启动模型 | 未运行时给提示，不静默失败 |
| `launcher\allow-lan-firewall.bat` | 放行 TCP 8080（仅专用/域网络），自动提权 | 只跑一次；`remove` 撤销、`status` 查看 |

**就绪判定用 `curl -sf`，不是 `curl -s`**：`llama-server` 加载权重期间 `/health` 返回 **503**，而 `curl -s` 对 503 的退出码仍是 0，会误判"已就绪"。这是本项目从实际故障里改出来的，`status.bat` 还做了 200/503/其他 三态区分。

---

## 接入 DSH / 任何 OpenAI 兼容客户端

服务是标准 OpenAI 接口，`baseURL` 填 `http://127.0.0.1:8080/v1`，模型名 `ternary-bonsai-2-27b`（= 启动参数 `-a`），密钥是 `config\keys.txt` 里那一行。

DSH（DeepSeek Harness）的配置写法，在 `~/.dsh/profiles/desktop/cordis.patch.yml`：

```yaml
providers:
  bonsai-local:
    displayName: bonsai-local
    api: openai-completions
    baseURL: http://127.0.0.1:8080/v1
    apiKeyEnv: BONSAI_API_KEY
    models:
      - id: ternary-bonsai-2-27b
        name: Ternary-Bonsai-2-27B
        contextWindow: 131072      # 必须与服务端 -c 一致
        input: [text]
```

密钥放在 `~/.dsh/.credentials.yaml` 的 `refs` 下，`BONSAI_API_KEY: <config\keys.txt 内容>`。

> **两个必看的前提**
> 1. `contextWindow` 必须等于服务端 `-c`。不一致会发超长 prompt 报错。
> 2. 如果 `contextWindow` 是 65536，且 `compaction-basic` 的 `headroomTokens` 也是默认 65536，则 `pressureBudget = 65536 - 0 - 65536 = 0`，切换模型会报 `context compaction failed`。要么把窗口开到 128K，要么把 `headroomTokens` 降下来（本机采用前者 + `headroomTokens: 8192` 补丁）。

鉴权范围（实测）：`/health` 与 `/` 静态页面免鉴权（方便启动器轮询和探活）；`/props`、`/v1/models`、`/v1/chat/completions` 无密钥一律 **401**。**本机也没有豁免**。

---

## 手机 / 局域网访问

1. 跑一次 `launcher\allow-lan-firewall.bat`，UAC 点"是"。
2. `start.bat` 会打印形如 `http://192.168.1.100:8080/` 的地址。
3. 手机连同一个 Wi-Fi 打开，Web UI 设置里填 `config\keys.txt` 的内容（填一次浏览器会记住）。

跨公网访问（类似 LM Studio 的 LM Link 远端层）不在本项目范围内：`cloudflared` 的 QUIC 与 HTTP/2 在受限网络下都连不通，Tailscale 的 DERP 也常不可达。要做的话建议自备 Tailscale 账号或用自签证书 + 可信内网。

---

## 目录结构

```
.
  install.bat            一键安装（薄壳，逻辑在 tools\install.ps1）
  start.bat / stop.bat / menu.bat    根目录入口，转发到 launcher\
  manifest.json          版本 / URL / 大小 / SHA256 清单（唯一需要更新的文件）
  launcher\
    _env.bat             公共变量；根目录由脚本位置推导，整个目录可随意搬家
    start.bat            启动
    stop.bat             关闭（按可执行文件路径精确筛选）
    restart.bat          重启
    open-ui.bat          只开界面
    status.bat           状态诊断
    allow-lan-firewall.bat
    menu.bat             功能菜单
  tools\
    detect.ps1           硬件检测与选型
    download.ps1         多连接分段下载 + SHA256 + 断点续传
    install.ps1          安装编排
  docs\
    TROUBLESHOOTING.md   常见问题
  # 以下是安装后才出现、已被 .gitignore 忽略的：
  runtime\bin\           引擎与 CUDA 运行时（应用本地 DLL）
  models\                GGUF 权重
  config\                keys.txt / model.txt / ctx.txt / ngl.txt
  _cache\                下载缓存（可删，重装会重新下载）
  logs\
```

模型文件名、上下文、GPU 层数都由安装器写进 `config\`，`launcher\_env.bat` 启动时读取。**换档或改上下文不需要改任何脚本**，改那三个小文本文件即可。

---

## 为什么模型和引擎不放进仓库

- **模型 `Ternary Bonsai 2 27B` 是 Apache-2.0**，允许商用与再分发（含 NOTICE 要求）。
- **引擎 `PrismML-Eng/llama.cpp` 是 MIT**。
- 本仓库自己的脚本是 **MIT**（见 `LICENSE`）。

许可上都允许打包，但打包没有好处：单个 5.95 GB 文件超出 GitHub Release 的单文件上限，且模型更新后整包作废。所以本仓库只**引用**官方发布物，并用 SHA256 钉死版本 —— 这也让"你拿到的东西到底是什么"可验证。

`PTQ1_0` 是 PrismML 的私有张量类型（ggml type **143**，超出官方枚举上限 44），**只有 PrismML 的 fork 能加载**。LM Studio、官方 llama.cpp、ollama 都不行。要跑通用引擎，得换 `Q2_0` 档（官方 llama.cpp b11556+ 支持）。

---

## 已知限制

- **只支持 64 位 Windows**。macOS / Linux 请直接用官方 `Bonsai-demo`。
- 不提供 MTP / DFlash2 草稿模型的下载（它们不在官方 GGUF 模型仓库里）。需要投机解码请自行准备草稿模型并在 `launcher\start.bat` 里加参数。
- 安装器不改系统环境（不装 Python、不装 CUDA、不写注册表、不改 PATH），因此也不会自动帮你装 Visual C++ 运行库 —— 缺的话见 `docs\TROUBLESHOOTING.md`。
- 未做代码签名，Windows SmartScreen 可能提示"未知发布者"。

---

## 参考与致谢

- 模型：[prism-ml/Ternary-Bonsai-2-27B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)（Apache-2.0）
- 引擎：[PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp)（MIT）
- 官方演示：[PrismML-Eng/Bonsai-demo](https://github.com/PrismML-Eng/Bonsai-demo)
- 上游：[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)

许可全文见 `LICENSE`（本项目）与 `NOTICE`（第三方归因）。
