# 实测数据

全部在本机实跑得出，不是引用厂商数据。环境：

| 项 | 值 |
|---|---|
| GPU | NVIDIA GeForce RTX 4070 Ti，12282 MiB |
| 驱动 | 617.42 |
| CPU 架构 | x64（AMD64） |
| 系统 | 精简版 Windows（缺 `api-ms-win-crt-*` 转发件，见 TROUBLESHOOTING） |
| 引擎 A（官方） | `PrismML-Eng/llama.cpp` `prism-b12128-d7b2896`，MSVC 19.44 |
| 引擎 B（自编译） | 同 fork `0.7.0-dev (build 1, commit 62c418c)`，MSVC 14.44 / CUDA 13.3，`CMAKE_CUDA_ARCHITECTURES=89` |
| 模型 | `Ternary-Bonsai-2-27B-PTQ1_0.gguf`，5946648928 B，SHA256 `53107f53…f33ee3` |

---

## 1. 显存与上下文

`-fa on -ctk q8_0 -ctv q8_0 -np 1`，空载基线 281 MiB。

| 配置 | 上下文 | 显存占用 | 结论 |
|---|---|---|---|
| PTQ1_0 + 128K | 131072 | **10667 / 10672 / 10674 MiB**（三次测量） | 12 GB 卡可用，余量约 1.6 GB |
| PTQ1_0 + 32K + DFlash2 草稿 | 32768 | **10030 MiB** | 草稿模型额外占约 1 GB |
| 无模型加载 | — | 281 MiB | 关掉后能完整释放 |

`n_ctx_slot = 131072`，`total_slots = 1`。

---

## 2. 吞吐

同一提示词、`max_tokens=160`、温度默认：

| 引擎 | 生成速度 | 备注 |
|---|---|---|
| 官方 `build 12128`（配 cudart 13.3） | **61.5 / 61.8 tok/s** | 两次连续请求 |
| 自编译 `build 1`（静态 CUDA + 系统 cublas） | **61.1 tok/s** | 同条件 |

**结论：用官方新构建没有任何速度损失**，所以本项目不需要自编译产物——这也顺带解决了"只支持 sm_89"的问题。

其他历史记录（同一模型、此前实测，供参考）：

| 场景 | 速度 |
|---|---|
| 中文对话（默认档） | 62.3 tok/s |
| 代码（默认档） | 64.2 tok/s |
| 代码（32K + DFlash2 草稿，接受率 73.7%） | 130.8 tok/s |
| prefill（默认档） | 约 1400 tok/s |

> 短提示 prefill 会测出很低的值（例如 111 tok/s 甚至 48 tok/s），因为 prefill 速度是在毫秒级内算出来的，受首次调度抖动影响极大。**短 prompt 的 prefill 数字没有参考意义**。

---

## 3. 启动器耗时

子进程执行 `.bat` 并捕获输出，不是看代码估的。

| 操作 | 耗时 | 结果 |
|---|---|---|
| `start.bat` 冷启动（页缓存热） | 3 s | 就绪，打印地址与密钥 |
| `start.bat` 冷启动（首轮实测） | 2 s | 同上 |
| `start.bat` 重复执行 | 0.2 s | `[已经在运行]`，不起第二实例 |
| `stop.bat` | 2.5 s | 停 1 个进程，health 000，显存 → 281 MiB |
| `restart.bat` | 4 s | 先提示无实例，再就绪 |
| `status.bat` | 4 s | 一屏输出全部指标 |
| `open-ui.bat`（未运行时） | 0.1 s | 退出码 1 并给提示 |

模型走 mmap，冷加载之所以是"秒级"而不是"分钟级"，是因为权重文件已在系统页缓存里。**首次全新安装后的第一次启动会明显更慢**（要真正从磁盘读 5.95 GB）。

---

## 4. 下载速度（重要）

| 方式 | 速率 | 说明 |
|---|---|---|
| GitHub Release **单连接** | 约 **100–110 KB/s** | 6 GB 要十几个小时，不可用 |
| GitHub Release **16 并发分段** | 曾测到 **约 9 MB/s** | 同一个文件、同一网络 |
| GitHub Release **8 并发**（某次慢链路） | 1.47 MB/s | 372.9 MB 用了 254 秒 |
| ModelScope 直连 | 可达 1–1.5 MB/s | 国内源，模型默认首选 |

**教训：只测"源快不快"没有意义，必须用最终要用的下载方式实测聚合速率。** 同一源单连接和多连接能差 30 倍以上。

另一个坑：**有些反代会无视 `Range` 请求头**，对任意区间都返回完整文件（HTTP 200 而非 206）。这时各段长度全超标，拼出来是坏文件。所以 `tools\download.ps1` 会逐段核对精确长度，不符即清理重试，绝不放行。

---

## 5. 官方预编译包的两个真实障碍

这两个都是实跑踩出来的，直接影响"能不能直接用官方件"的决策：

### 5.1 CUDA 大版本写死在导入表里

`dumpbin /dependents` 结果：

| 构建 | 依赖 |
|---|---|
| 官方 `win-cuda-12.4-x64` 的 `ggml-cuda.dll` | `cudart64_12.dll`、`cublas64_12.dll` |
| 本机自编译版 | `cublas64_13.dll`（CUDA 运行时静态链接进去了） |

本机只装了 CUDA 13.3，所以官方 12.4 版直接报缺 DLL（表现为 `STATUS_DLL_NOT_FOUND`，退出码 `-1073741515`）。**换成官方 13.3 版立刻正常**。这也是 `detect.ps1` 要按驱动版本选资产的原因。

### 5.2 必须用 cudart 包做应用本地加载

官方 Release 的引擎 zip 里**不含** `cudart64_*` / `cublas64_*`，它们是单独的 `cudart-llama-bin-win-cuda-*.zip`（约 373 MB）。

验证方法：把 PATH 里的 CUDA 目录全部去掉后运行

```
PATH="C:\Windows\System32;C:\Windows" runtime\bin\llama-server.exe --version
```

输出正常：

```
version: 0.7.0-dev (build 12128, commit d7b289683)
built with MSVC 19.44.35229.0 for Windows AMD64
```

**说明用户机器不需要安装 CUDA Toolkit** —— 这正是本项目"零依赖"的前提。

---

## 6. 已验证 / 未验证

**已验证**

- 安装器端到端：检测 → 引擎校验跳过 → cudart 真实下载 372.9 MB → SHA256 一致 → 解压 → 模型 6 GB SHA256 校验跳过 → 写配置 → 生成密钥，退出码 0
- 复装幂等（已存在且校验通过则跳过）
- 净化 PATH（无 CUDA Toolkit）下引擎可运行
- `start.bat` 正确读取 `config\ctx.txt`：`n_ctx = 131072`
- 鉴权：`/health` `/` 免鉴权 200；`/props` `/v1/models` `/v1/chat/completions` 无密钥 401、有密钥 200、错密钥 401
- 局域网：`192.168.1.100:8080` 端到端推理通
- `stop.bat` 按路径精确筛选，只杀本项目进程

**未验证**

- `allow-lan-firewall.bat` 的提权分支（会阻塞在 UAC，只做了静态检查）
- `install.bat` 在无 NVIDIA 显卡时的 CPU 分支、驱动 < 550 时的 Vulkan 分支（本机无法构造）
- 8 GB / 24 GB 显存档位的实际占用（按 12 GB 实测线性推算，未实测）
- 模型与 cudart 的"首次完整下载"路径（测试时用已校验文件走了跳过分支；下载代码本身用 cudart 373 MB 验证过）
