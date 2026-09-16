<#
家教出行助手 · 本地一键启动（Windows）

双击或用 PowerShell 运行本文件，它会：
  1. 检查环境是否就绪（虚拟环境、依赖、密钥）
  2. 打开两个窗口分别启动后端和前端
  3. 等页面就绪后自动打开浏览器

如果提示「无法加载文件，因为在此系统上禁止运行脚本」，在项目目录执行：
  powershell -ExecutionPolicy Bypass -File .\start-local.ps1

关闭时：直接关掉那两个新弹出的黑色窗口即可。
#>

[CmdletBinding()]
param(
    [int]$BackendPort = 8000,
    [int]$FrontendPort = 3000
)

$ErrorActionPreference = "Stop"

function Write-Step($text) {
    Write-Host ""
    Write-Host "==> $text" -ForegroundColor Green
}

function Write-Warn($text) {
    Write-Host "[提示] $text" -ForegroundColor Yellow
}

function Write-Fail($text) {
    Write-Host "[错误] $text" -ForegroundColor Red
}

$Root = $PSScriptRoot
$BackendDir = Join-Path $Root "backend"
$FrontendDir = Join-Path $Root "frontend"
$PythonExe = Join-Path $BackendDir "venv\Scripts\python.exe"
$EnvFile = Join-Path $BackendDir ".env"

Write-Host "=============================================="
Write-Host " 家教出行助手 · 本地启动"
Write-Host "=============================================="

# ---------- 1. 环境检查 ----------
Write-Step "检查运行环境"

if (-not (Test-Path $PythonExe)) {
    Write-Fail "找不到后端虚拟环境，请先执行："
    Write-Host "  cd $BackendDir"
    Write-Host "  python -m venv venv"
    Write-Host "  .\venv\Scripts\pip install -r requirements.txt"
    exit 1
}

if (-not (Test-Path (Join-Path $BackendDir "main.py"))) {
    Write-Fail "找不到 backend\main.py，请确认本文件放在项目根目录下。"
    exit 1
}

if (-not (Test-Path (Join-Path $FrontendDir "node_modules"))) {
    Write-Fail "前端依赖还没安装，请先执行："
    Write-Host "  cd $FrontendDir"
    Write-Host "  npm install"
    exit 1
}

if (-not (Test-Path $EnvFile)) {
    Write-Fail "找不到 backend\.env，请先执行 cd backend 然后运行：python setup_env.py"
    exit 1
}

# 检查两个密钥是否已经填上
$lines = Get-Content $EnvFile -Encoding UTF8
$missing = @()
foreach ($name in @("DEEPSEEK_API_KEY", "AMAP_KEY")) {
    $line = ($lines | Where-Object { $_ -match "^$name=" } | Select-Object -First 1)
    if (-not $line -or ($line -replace "^$name=", "").Trim() -eq "") {
        $missing += $name
    }
}
if ($missing.Count -gt 0) {
    Write-Fail ("backend\.env 里还没填：" + ($missing -join "、"))
    Write-Host "  cd $BackendDir"
    Write-Host "  .\venv\Scripts\python.exe setup_env.py"
    exit 1
}

Write-Host "环境检查通过。"

# ---------- 2. 启动后端 ----------
Write-Step "启动后端（端口 $BackendPort）"

Start-Process -FilePath $PythonExe `
    -ArgumentList "-m", "uvicorn", "main:app", "--reload", "--port", "$BackendPort" `
    -WorkingDirectory $BackendDir

# ---------- 3. 启动前端 ----------
Write-Step "启动前端（端口 $FrontendPort）"

Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "npm", "run", "dev", "--", "-p", "$FrontendPort" `
    -WorkingDirectory $FrontendDir

# ---------- 4. 等待就绪 ----------
Write-Step "等待页面就绪（首次编译需要十几秒）"

$Url = "http://localhost:$FrontendPort"
$ready = $false

for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -eq 200) {
            $ready = $true
            break
        }
    }
    catch {
        # 还没起来，继续等
    }
}

# ---------- 5. 打开浏览器 ----------
if ($ready) {
    Write-Host "服务已就绪。"
}
else {
    Write-Warn "等待超时，仍然尝试打开浏览器。如果页面打不开，去看那两个黑窗口里的报错信息。"
}

Start-Process $Url

Write-Host ""
Write-Host "=============================================="
Write-Host " 已启动" -ForegroundColor Green
Write-Host "=============================================="
Write-Host ""
Write-Host "页面地址：  $Url"
Write-Host "后端地址：  http://127.0.0.1:$BackendPort"
Write-Host ""
Write-Host "使用方式：把家教聊天记录粘贴进第一个输入框，点「开始解析」。"
Write-Host ""
Write-Warn "停止服务：关掉新弹出的那两个黑色窗口。"
Write-Host ""
