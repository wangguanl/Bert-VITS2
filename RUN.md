# 运行命令

- 项目：Bert-VITS2
- 生成时间：2026-09-07
- 运行方式：直接运行（`.venv` + Gradio）
- 硬件评估：**满足（推理）** / **有压力（训练）**
  - 项目：单卡 CUDA TTS；官方预处理 UI 建议 16GB 下 `batch_size≈8`（24GB 可用 12）
  - 本机：RTX 4080 / 16376 MiB；评估时已用约 7697 MiB、空闲约 8352 MiB
  - 推理 `webui.py`（加载 `G_6000.pth` + BERT）通常数 GB 级，空闲显存够用 → **满足**
  - 训练 `train_ms.py` 在已有 ~7.7GB 占卡时偏紧 → **有压力**，训前建议先清其它占卡进程
  - 内存约 31.8GB（评估时空闲约 4.8GB）；磁盘 C≈68GB / E≈710GB 空闲 → 够用

## 环境准备

已有 `.venv`（Python 3.10.11 + `torch 2.6.0+cu124`），一般无需重装。新机器可参考：

```powershell
cd E:\AI\local-voice\Bert-VITS2
uv venv .venv --python 3.10.11
.\.venv\Scripts\python.exe -m pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

模型目录（本机已就位）：

- `bert/chinese-roberta-wwm-ext-large` 等
- `slm/wavlm-base-plus`
- 推理权重：`Data/models/G_6000.pth`，配置：`Data/configs/config.json`

Hugging Face 拉取慢时可先：`$env:HF_ENDPOINT='https://hf-mirror.com'`

全局：`pwsh`、ffmpeg=`E:\Programs\ffmpeg-master-latest-win64-gpl\bin`（由 `start.ps1` 注入 PATH）

## 启动

- 推荐：`pwsh -NoProfile -File .\start.ps1`
- 说明：启动后按提示选择服务（可单开或同开多个）；**不要默认全开**。默认选项为 **infer**（日常推理 WebUI）。
- 服务菜单：`infer` / `preprocess` / `server`
- 自动化（跳过菜单，非日常用法）：`-Service infer|preprocess|server`；单服务时可加 `-Port <起点>`（占用则 +1）

等价手动命令：

```powershell
cd E:\AI\local-voice\Bert-VITS2
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;$env:Path"
# infer
.\.venv\Scripts\python.exe webui.py
# preprocess
.\.venv\Scripts\python.exe webui_preprocess.py
# server
.\.venv\Scripts\python.exe hiyoriUI.py
```

默认推理端口来自 `config.yml` → `webui.port`（当前 **47801**）。预处理脚本写死 **7860**；`start.ps1` 会探测并在占用时顺延（预处理通过临时脚本副本改端口）。server 端口以 `config.yml` 的 `server.port` 为准。

## 验证

- 推理：浏览器打开日志中的 `http://127.0.0.1:<端口>`，页面含「输入文本内容 / Speaker」；或 `Invoke-WebRequest http://127.0.0.1:<端口>` 返回 200
- 预处理：页面含「Bert-VITS2 数据预处理」与「生成配置文件」等步骤
- 日志出现 `推理页面已开启!` / Gradio `Running on local URL`

## 备注

- 必须用 `.venv` 的 Python，勿直接 `.\webui.py`（会落到系统 Python 3.14）
- 无 Docker；官方为纯 Python
- 旧文档 `运行说明.md` 仍可用；本文件为 `wanggang-run-oss` 标准交付物
- 端口不写死：以 `start.ps1` 探测结果为准
- 当前 GPU 已有其它占用时，优先跑推理；训练前先看 `nvidia-smi`
