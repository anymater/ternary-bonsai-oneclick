# 常见问题

按报错原文检索。

---

## 启动就报缺 DLL

### `api-ms-win-crt-heap-l1-1-0.dll is missing` / 退出码 `-1073741515`（0xC0000135）

系统缺 Universal C Runtime 的 API-set 转发件。装一次微软官方运行库即可：

- 搜 "Visual C++ 2015-2022 Redistributable x64"（`vc_redist.x64.exe`），装完重启终端。
- 注意：`C:\Windows\System32\ucrtbase.dll` 存在**不代表**没问题。精简版 Windows 镜像常缺 `api-ms-win-crt-*` 这一组转发 DLL，`llama-server` 是 MSVC 构建，导入表里点名要它们。

### `cudart64_12.dll` / `cublas64_12.dll` / `cudart64_13.dll` 找不到

CUDA 大版本不匹配。引擎是按 CUDA 版本编译的，**导入表里写死了版本号**，装的是 CUDA 13 就跑不了 12.4 版二进制，反之亦然。

处理顺序：

1. 删掉 `runtime\` 后重跑 `install.bat`，让它按你的驱动重新选版本（判定规则见 `tools\detect.ps1`）。
2. 或从同一个 GitHub Release 手动下对应的 `cudart-llama-bin-win-cuda-<版本>-x64.zip`，解压**覆盖到** `runtime\bin\`（和 `llama-server.exe` 同目录，应用本地加载即可生效，不需要装 CUDA Toolkit）。
3. 驱动太老（< 550）就换 Vulkan 版：删 `runtime\`，手动跑 `install.bat` 后把 `config\env.txt` 里的 `ASSET=win-vulkan-x64` 改掉再装一次。

### `tensor 'output.weight' has invalid ggml type 143. should be in [0, 44)`

你用的引擎不是 PrismML 的 fork。`PTQ1_0` 是私有张量类型（编号 143，超出官方枚举上限 44），**官方 llama.cpp、LM Studio、ollama 都加载不了**。

- 用本项目的 `install.bat`（它下的就是 fork 的官方 Release）；
- 或者换成 `Q2_0` 档（官方 llama.cpp b11556+ 支持），改 `config\model.txt` 与 `install.ps1 -Packing Q2_0`。

---

## 下载相关

### 下载很慢

实测（本机、8 并发）：GitHub Release 单连接约 100–110 KB/s，多连接能到 1.5–9 MB/s，差 30 倍以上。本项目默认 12 并发，觉得慢可以加：

```
install.bat --parts 16
```

另外模型默认优先走 **ModelScope**（国内），失败自动切 HuggingFace。

### `分段校验失败` 或下载完 SHA256 不符

某些反向代理/CDN 会无视 `Range` 请求头，对任意区间都返回**整个文件**（还回 HTTP 200 而不是 206）。后果是各段长度全部超标、拼出来的文件是坏的。

脚本已经逐段核对长度并在不符时清理临时文件，不会留下坏文件。遇到时：

1. 减少并发重试：`install.bat --parts 4`
2. 换网络环境或换源（改 `manifest.json` 里的 `sources` 顺序）
3. **不要**用会篡改响应的下载加速器

### 中断了怎么办

直接重跑 `install.bat`。已存在且 SHA256 校验通过的文件会跳过，只有不完整/不匹配的会重下。

### `_cache\` 占空间

里面是已校验的原始 zip，删掉不影响已安装的 `runtime\` 和 `models\`，只是重装时会重新下载。

---

## 运行相关

### 加载超时（120 秒没就绪）

最可能是显存不够。跑 `launcher\status.bat` 看 `--- 4. 显存 ---` 当前占用。

降低显存的几种办法，按性价比排序：

1. 关掉别的吃显存的程序（浏览器硬件加速、游戏、其他模型服务）。
2. 把上下文改小：编辑 `config\ctx.txt`，例如从 `131072` 改成 `65536` 或 `32768`。
3. 用更小的模型档：`PTQ1_0`（5.95 GB）已是最省，`PQ2_0` 更大但 prefill 更快，按需求取舍。
4. 部分卸载到 CPU：编辑 `config\ngl.txt`，从 `99` 改成 `40` 之类（会明显变慢）。

参考实测：`PTQ1_0` + 128K 上下文在 12 GB 卡上占 **10.67 GB**；32K 上下文约 7 GB 出头。

### 端口 8080 被占用

`start.bat` 会先探 `/health`：能通就认为"已经在运行"并直接打开界面，不通才启动。如果 8080 被**别的程序**（不是 llama-server）占着，会一直等到超时。改端口：编辑 `launcher\_env.bat` 里的 `set "PORT=8080"`。

### 两个实例抢显存

不会。同一端口上再双击 `start.bat` 会走"已经在运行"分支，不启动第二个进程。

### `stop.bat` 会不会杀掉 LM Studio 的 llama-server

不会。它按**进程可执行文件的完整路径**是否位于本项目目录下来筛选，LM Studio 自带的是另一个路径，不会被误杀。这也是不用 `taskkill /IM llama-server.exe` 的原因。

### Web UI 显示 `Access denied` / `Server Connection Error`

服务启用了 API 密钥鉴权。在 Web UI 的设置里填 `config\keys.txt` 那一行（填一次浏览器会记住，存在 `localStorage`）。

用命令行验证密钥对不对：

```bat
curl -H "Authorization: Bearer <你的密钥>" http://127.0.0.1:8080/v1/models
```

无密钥时 `/props`、`/v1/models`、`/v1/chat/completions` 一律返回 401；`/health` 和 `/` 静态页免鉴权（这是为了让启动器轮询不需要密钥）。**本机也没有豁免**。

### 模型回答里没有 `content`，只有 `reasoning_content`

这是推理模型，默认会先输出思维链。`max_tokens` 给小了（比如 24）会全被思维链吃掉，`content` 就是空的。要么加大 `max_tokens`，要么在客户端用 `thinking_budget` / `reasoning_effort` 限制思考长度。

---

## 接入 DSH 相关

### `Cannot switch to ...: context compaction failed: ... reserves 0 completion tokens and 65536 headroom tokens of its 65536-token context window, leaving no pressure budget`

`compaction-basic` 的 `headroomTokens` 默认就是 **65536**。如果你的 `contextWindow` 也写 65536，则：

```
pressureBudget = (65536 - 0) - 65536 = 0   ->  抛 TargetPressureConfigError
```

两条修法，选一：

1. **把窗口开大**（本项目默认路线）：服务端 `-c 131072` + DSH `contextWindow: 131072`，此时 `pressureBudget = 131072 - 65536 = 65536 > 0`，算术上必然成立。
2. **把 headroom 降下来**：在 DSH 的 patch 里加 `headroomTokens: 8192`（可配 `modelPolicies` 只对本模型生效）。

### DSH 发超长 prompt 报错

DSH 的 `contextWindow` 是写死在 provider 里的，必须和服务端 `-c`（也就是 `config\ctx.txt`）一致。改了一边忘了另一边就会这样。

---

## 改脚本的人注意

### `.bat` 必须是 GBK + CRLF，且带 `chcp 936`

按 UTF-8 保存会让 `cmd` 以 936 代码页去读：三字节汉字错位后，个别字节被当成 `&` `|` `"`，命令行被截断，报出像代码 bug 的怪错，例如：

```
'0.0.0' 不是内部或外部命令
'dressFamily' 不是内部或外部命令      （AddressFamily 被劈开）
```

### `.ps1` 必须是 UTF-8 **带 BOM**

PowerShell 5.1 读无 BOM 的 UTF-8 文件会按 ANSI（GBK）解释，中文全变乱码。

### 不要用 `timeout /t N` 等待

stdin 被重定向时它会立刻报错退出。脚本里统一用 `ping -n N 127.0.0.1 >nul`。

### 判断服务就绪要用 `curl -sf`，不要用 `curl -s`

`/health` 在模型加载期间返回 **503**，而 `curl -s` 对 503 的退出码仍然是 0 —— 会把"还在加载"当成"已就绪"。`-f`（`--fail`）才会对 HTTP ≥ 400 返回非零。

### 菜单里 `if ... & goto` 会被无条件执行

```bat
REM 错：无论条件是否成立，goto after 都会执行
if "%C%"=="1" call start.bat & goto after

REM 对：用括号把整段包成 if 的执行体
if "%C%"=="1" ( call start.bat & goto after )
```

---

## 还是不行

提 issue 时请附上：

1. `launcher\status.bat` 的完整输出
2. `install.bat` 的完整输出
3. `nvidia-smi` 输出
4. `runtime\bin\llama-server.exe --version` 输出
5. 那个最小化的黑色窗口（llama-server 控制台）里的报错
