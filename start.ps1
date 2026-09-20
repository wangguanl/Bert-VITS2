#Requires -Version 5.0
<#
.SYNOPSIS
    启动 Bert-VITS2（由 wanggang-run-oss 生成）。实际逻辑按 PowerShell 7 执行。
.DESCRIPTION
    主路径：无参运行后交互选择 infer / preprocess / server。
.PARAMETER Mode
    direct = 本机直接运行；docker = 本项目不支持。
.PARAMETER Port
    仅当最终只启动一个需端口的服务时，作为该服务的端口搜索起点。
.PARAMETER Service
    内部用：跳过菜单，直接启动指定 Id（infer / preprocess / server）。
#>
[CmdletBinding()]
param(
    [ValidateSet('direct', 'docker')]
    [string]$Mode = 'direct',

    [int]$Port = 0,

    [string]$Service = ''
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '未找到 PowerShell 7 (pwsh)。请先全局安装：winget install --id Microsoft.PowerShell -e'
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $val = $PSBoundParameters[$key]
        if ($val -isnot [System.Management.Automation.SwitchParameter]) {
            $argList += [string]$val
        }
    }
    & $pwsh.Source @argList
    exit $LASTEXITCODE
}

Set-Location $PSScriptRoot

$FfmpegBin = 'E:\Programs\ffmpeg-master-latest-win64-gpl\bin'
if (Test-Path $FfmpegBin) {
    $env:Path = "$FfmpegBin;$env:Path"
} else {
    Write-Warning "未找到本机 ffmpeg：$FfmpegBin"
}

function Show-GpuStatus {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Warning '未检测到 nvidia-smi，跳过 GPU 检查。'
        return
    }
    Write-Host '=== GPU 状态 ===' -ForegroundColor Cyan
    & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
}

function Test-PortBusy {
    param([int]$TargetPort)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $TargetPort)
        $listener.Start()
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-FreePort {
    param(
        [int]$StartPort,
        [int]$MaxTries = 50
    )
    if ($StartPort -lt 1) { $StartPort = 1024 }
    $end = $StartPort + $MaxTries - 1
    if ($end -gt 65535) { $end = 65535 }
    $p = $StartPort
    while ($p -le $end) {
        if (-not (Test-PortBusy -TargetPort $p)) {
            if ($p -ne $StartPort) {
                Write-Host "端口 $StartPort 已占用，顺延到 $p" -ForegroundColor Yellow
            }
            return $p
        }
        $p++
    }
    throw "从 $StartPort 起连续探测均被占用，放弃。"
}

function Select-ServicesInteractive {
    param([object[]]$AllServices)

    if ($AllServices.Count -eq 0) {
        throw '未配置 $Services，请按项目改写模板。'
    }
    if ($AllServices.Count -eq 1) {
        Write-Host "仅一个服务，直接启动：$($AllServices[0].Label)" -ForegroundColor Cyan
        return @($AllServices[0])
    }

    Write-Host ''
    Write-Host '=== 启动哪些服务？===' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllServices.Count; $i++) {
        $svc = $AllServices[$i]
        $portHint = if ($svc.NeedsPort) { "端口起点 $($svc.PreferredPort)" } else { '无需端口' }
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $svc.Label, $portHint)
    }
    Write-Host ("  [{0}] 全部开" -f ($AllServices.Count + 1))
    Write-Host '  [0] 取消'
    Write-Host ''

    $defaultChoice = '1'
    $raw = Read-Host "请选择（可多选，逗号分隔，如 1,2；默认 $defaultChoice）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultChoice }

    if ($raw.Trim() -eq '0') {
        throw '已取消启动。'
    }

    $allIndex = $AllServices.Count + 1
    $parts = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($part in $parts) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n)) {
            throw "无效选项：$part"
        }
        if ($n -eq $allIndex) {
            return @($AllServices)
        }
        if ($n -lt 1 -or $n -gt $AllServices.Count) {
            throw "选项超出范围：$n"
        }
        $selected.Add($AllServices[$n - 1])
    }

    if ($selected.Count -eq 0) {
        throw '未选择任何服务。'
    }

    $byId = [ordered]@{}
    foreach ($s in $selected) { $byId[$s.Id] = $s }
    return @($byId.Values)
}

function Assert-GpuOkForSelection {
    param([object[]]$Selected)

    $gpuServices = @($Selected | Where-Object { $_.UsesGpu })
    if ($gpuServices.Count -le 1) { return }

    $labels = ($gpuServices | ForEach-Object { $_.Label }) -join ', '
    Write-Host ''
    Write-Host "已选多个占卡服务：$labels" -ForegroundColor Yellow
    Write-Host '16GB 显存下同时加载多个推理服务容易 OOM。请确认剩余显存足够，或改回只开一个。' -ForegroundColor Yellow
    $confirm = Read-Host '仍要继续？[y/N]'
    if ($confirm -notmatch '^[yY]') {
        throw '已取消：多服务占卡未确认。'
    }
}

function Get-ConfigWebuiPort {
    $cfg = Join-Path $PSScriptRoot 'config.yml'
    if (-not (Test-Path $cfg)) { return 47801 }
    $text = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
    if ($text -match '(?ms)^\s*webui:\s*.*?^\s*port:\s*(\d+)') {
        return [int]$Matches[1]
    }
    return 47801
}

function Get-ConfigServerPort {
    $cfg = Join-Path $PSScriptRoot 'config.yml'
    if (-not (Test-Path $cfg)) { return 47802 }
    $text = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
    if ($text -match '(?ms)^\s*server:\s*.*?^\s*port:\s*(\d+)') {
        return [int]$Matches[1]
    }
    return 47802
}

$Services = @(
    [pscustomobject]@{
        Id            = 'infer'
        Label         = 'infer（推理 WebUI，webui.py）'
        PreferredPort = (Get-ConfigWebuiPort)
        NeedsPort     = $true
        UsesGpu       = $true
    }
    [pscustomobject]@{
        Id            = 'preprocess'
        Label         = 'preprocess（数据预处理 UI）'
        PreferredPort = 7860
        NeedsPort     = $true
        UsesGpu       = $false
    }
    [pscustomobject]@{
        Id            = 'server'
        Label         = 'server（FastAPI，hiyoriUI.py）'
        PreferredPort = (Get-ConfigServerPort)
        NeedsPort     = $true
        UsesGpu       = $true
    }
)

function Start-ProjectService {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$RunMode,

        [int]$ListenPort = 0
    )

    if ($RunMode -eq 'docker') {
        throw 'Bert-VITS2 本仓库无 Docker 编排，请使用 -Mode direct。'
    }

    $Python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path $Python)) {
        throw "未找到虚拟环境：$Python 。请先按 RUN.md 创建 .venv 并安装依赖。"
    }

    switch ($Service.Id) {
        'infer' {
            Write-Host "访问：http://127.0.0.1:$ListenPort" -ForegroundColor Green
            $ymlArgs = @()
            $cfgPath = Join-Path $PSScriptRoot 'config.yml'
            $runCfg = Join-Path $PSScriptRoot '.config.run.yml'
            if ((Test-Path $cfgPath) -and ($ListenPort -ne (Get-ConfigWebuiPort))) {
                $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
                $raw2 = [regex]::Replace(
                    $raw,
                    '(?ms)(^webui:\r?\n(?:^[ \t].*\r?\n)*?[ \t]*port:\s*)\d+',
                    "`${1}$ListenPort"
                )
                [System.IO.File]::WriteAllText($runCfg, $raw2, [System.Text.UTF8Encoding]::new($true))
                $ymlArgs = @('-y', $runCfg)
                Write-Host "已写入临时配置 $runCfg（port=$ListenPort）" -ForegroundColor Yellow
            }
            & $Python webui.py @ymlArgs
        }
        'preprocess' {
            Write-Host "访问：http://127.0.0.1:$ListenPort" -ForegroundColor Green
            $src = Join-Path $PSScriptRoot 'webui_preprocess.py'
            if ($ListenPort -eq 7860) {
                & $Python $src
            } else {
                $tmp = Join-Path $env:TEMP ("bert_vits2_webui_preprocess_{0}.py" -f $ListenPort)
                $code = Get-Content -LiteralPath $src -Raw -Encoding UTF8
                $code = $code.Replace('http://127.0.0.1:7860', "http://127.0.0.1:$ListenPort")
                $code = $code.Replace('server_port=7860', "server_port=$ListenPort")
                [System.IO.File]::WriteAllText($tmp, $code, [System.Text.UTF8Encoding]::new($true))
                Write-Host "端口已顺延，使用临时脚本：$tmp" -ForegroundColor Yellow
                & $Python $tmp
            }
        }
        'server' {
            $cfgPort = Get-ConfigServerPort
            if ($ListenPort -ne $cfgPort) {
                Write-Warning "hiyoriUI 端口写在 config.yml 的 server.port，当前探测到空闲 $ListenPort 与配置 $cfgPort 不一致。"
                throw "server 模式请先保证 config.yml 的 server.port 空闲（当前建议 $ListenPort）。"
            }
            Write-Host "访问：http://127.0.0.1:$ListenPort" -ForegroundColor Green
            & $Python hiyoriUI.py
        }
        default {
            throw "未知服务：$($Service.Id)"
        }
    }
}

Show-GpuStatus

if ($Service) {
    $match = @($Services | Where-Object { $_.Id -eq $Service })
    if ($match.Count -eq 0) {
        throw "未知服务 Id：$Service。可选：$($Services.Id -join ', ')"
    }
    $chosen = $match
} else {
    $chosen = Select-ServicesInteractive -AllServices $Services
    Assert-GpuOkForSelection -Selected $chosen
}

$multi = $chosen.Count -gt 1

if ($multi) {
    $started = @()
    foreach ($svc in $chosen) {
        $listen = 0
        if ($svc.NeedsPort) {
            $listen = Get-FreePort -StartPort $svc.PreferredPort
            Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.AddRange([string[]]@('-NoProfile', '-File', $PSCommandPath, '-Mode', $Mode, '-Service', $svc.Id))
        if ($listen -gt 0) {
            $argList.Add('-Port')
            $argList.Add("$listen")
        }

        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -PassThru -WorkingDirectory $PSScriptRoot
        $started += [pscustomobject]@{ Id = $svc.Id; Label = $svc.Label; Port = $listen; Pid = $p.Id }
        Write-Host "已后台启动 $($svc.Label) PID=$($p.Id)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== 已启动 ===' -ForegroundColor Cyan
    foreach ($s in $started) {
        $portInfo = if ($s.Port -gt 0) { " port=$($s.Port)" } else { '' }
        Write-Host ("- {0}{1} pid={2}" -f $s.Label, $portInfo, $s.Pid)
    }
    Write-Host '各服务在独立进程中运行；结束请自行停对应 PID。' -ForegroundColor Yellow
    return
}

$svc = $chosen[0]
$listen = 0
if ($svc.NeedsPort) {
    $startPort = $svc.PreferredPort
    if ($Port -gt 0) { $startPort = $Port }
    $listen = Get-FreePort -StartPort $startPort
    Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
}

Start-ProjectService -Service $svc -RunMode $Mode -ListenPort $listen