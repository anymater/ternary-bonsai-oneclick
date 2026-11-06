# 常见问题

按报错原文检索。

---

## 启动就报缺 DLL

### `api-ms-win-crt-heap-l1-1-0.dll is missing` / 退出码 `-1073741515`（0xC0000135）

系统缺 Universal C Runtime 的 API-set 转发件。装一次微软官方运行库即可：

- 搜 "Visual C++ 2015-2022 Redistributable x64"（`vc_redist.x64.exe`），装完重启终端。
- 注意：`C:\Windows\System32\ucrtbase.dll` 存在**不代表**没问题。部分 Windows 镜像会缺 `api-ms-win-crt-*` 这一组转发 DLL，`llama-server` 是 MSVC 构建，导入表里点名要它们。

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

实测（本机、GitHub Release）：**单连接约 100–110 KB/s**，多连接能到 4.5–9 MB/s，差 30 倍以上。本项目默认 12 个连接，觉得慢可以加：

```
install.bat --parts 16
```

`--parts` 是**同时进行的连接数**，不是把文件切成几段——文件会被切成 `连接数 × 8` 块排队，所以加到 16 是"16 条连接持续干活"，不是"16 段各干各的"。加太多反而互相挤占，一般 8–24 之间最划算。

另外模型默认优先走 **ModelScope**（国内），失败自动切 HuggingFace。

### `分段校验失败` 或下载完 SHA256 不符

某些反向代理/CDN 会无视 `Range` 请求头，对任意区间都返回**整个文件**（还回 HTTP 200 而不是 206）。后果是各段长度全部超标、拼出来的文件是坏的。

脚本已经逐段核对长度并在不符时清理临时文件，不会留下坏文件。遇到时：

1. 减少并发重试：`install.bat --parts 4`
2. 换网络环境或换源（改 `manifest.json` 里的 `sources` 顺序）
3. **不要**用会篡改响应的下载加速器

### 中断了怎么办

直接重跑 `install.bat`。已存在且 SHA256 校验通过的文件会跳过；**下到一半的文件也能接着下** —— 完成的块保留在 `<文件名>.parts\`，下次启动会打印

```
[续传] 已有 12 块完整（96.0 MB），还需下 12 块，另有 2 块有半截、从断点接着下
```

带"半截"的那几块会从已有字节数继续请求 `Range`，不会从头再来。`.parts\` 和 `.plan` 只在同一 URL + 同一大小时才复用；换了源或版本号，旧块会自动作废重下（不会把两个源的字节拼在一起）。

如果上次是被强杀的，`.parts\` 里可能还有 `.new` 临时文件——重跑时会先并回块文件再续传，不用手删。

### 进度条一直不动 / 卡在某一百分比

下载器有卡死检测：某块 45 秒没有新字节就杀掉重排。如果整体几十秒完全不动，多半是网络断了或代理掉线；`Ctrl-C` 掉重跑即可，不会白下。想确认是"慢"还是"死"，看日志里的瞬时速率那一列：`0 B/s` 且块数不涨超过 45 秒就是死连接。

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

### 服务跑着跑着自己没了，日志停在 `listening on` 之后再无内容

**没有任何报错、没有崩溃记录、日志正好断在 `listening on http://0.0.0.0:8080`** —— 这说明进程是被外部终止的，不是自己退出的。

最常见的原因：**把 `llama-server.exe` 当成了某个终端/脚本的子进程直接启动**（例如在别的程序里 `./llama-server ... &`、在 CI/代理里 `subprocess.run` 起一个、在远程会话里挂后台）。父进程或那个会话结束时，子进程会被连带回收，而它自己没有机会写任何日志。

正确做法：双击 `start.bat`。它内部用 `start "Bonsai2-128K" /min ...` 把服务放进**独立控制台**，不再挂在你当前终端上，终端关掉服务继续跑。

排查这类问题看两处就够：

```bat
curl -sf --noproxy "*" http://127.0.0.1:8080/health   :: 通了就是活着
launcher\status.bat                                    :: 进程数、PID、显存、上下文一屏
```

如果 `status.bat` 里进程数 = 0 而日志停在 `listening on`，就是被外部终止了，直接 `start.bat` 重开即可。

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

## 客户端报超长 prompt / 上下文压缩失败

客户端里的上下文窗口必须和服务端 `-c`（`config\ctx.txt`）一致。改了一边忘了另一边就会这样。

如果客户端自己也做上下文压缩，窗口给小了（比如 65536）还可能算不出压缩余量、直接拒绝切换模型。把窗口开到 131072，或调低客户端的压缩预留（headroom）参数。

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
