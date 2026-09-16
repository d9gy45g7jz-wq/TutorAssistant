<#
家教出行助手 · 本机一键部署脚本（Windows）

它做三件事：
  1. 把项目里的前后端代码打包（自动排除 node_modules、venv 等大目录）
  2. 上传到你的服务器
  3. 在服务器上自动装环境、构建前端、启动服务

用法（在本文件所在目录打开 PowerShell）：
  .\deploy.ps1 -ServerIp 1.2.3.4
或者直接运行，按提示输入服务器 IP：
  .\deploy.ps1

如果提示「无法加载文件，因为在此系统上禁止运行脚本」，改用这条命令运行：
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1

参数说明：
  -ServerIp  服务器公网 IP
  -User      SSH 用户名，默认 root
  -SshPort   SSH 端口，默认 22
  -WebPort   对外访问端口，默认 8080
#>

[CmdletBinding()]
param(
    [string]$ServerIp = "",
    [string]$User = "root",
    [int]$SshPort = 22,
    [int]$WebPort = 8080
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

Write-Host "=============================================="
Write-Host " 家教出行助手 · 一键部署到服务器"
Write-Host "=============================================="

# ---------- 0. 本机环境检查 ----------
foreach ($tool in @("ssh", "scp", "tar")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fail "找不到 $tool 命令。Windows 10 及以上自带 OpenSSH，请在「设置 - 应用 - 可选功能」里安装「OpenSSH 客户端」。"
        exit 1
    }
}

$DeployDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $DeployDir
$SetupScript = Join-Path $DeployDir "server-setup.sh"

if (-not (Test-Path $SetupScript)) {
    Write-Fail "找不到 server-setup.sh，请确认 deploy 目录完整。"
    exit 1
}

if (-not (Test-Path (Join-Path $ProjectRoot "backend\main.py"))) {
    Write-Fail "找不到 backend\main.py，请把 deploy 目录放在项目根目录下。"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ServerIp)) {
    $answer = Read-Host "请输入服务器公网 IP（云厂商控制台里可以看到）"
    if ($answer) { $ServerIp = $answer.Trim() }
}
while ([string]::IsNullOrWhiteSpace($ServerIp)) {
    Write-Warn "IP 不能为空。"
    $answer = Read-Host "请输入服务器公网 IP"
    if ($answer) { $ServerIp = $answer.Trim() }
}

$Target = "$User@$ServerIp"
$CommonArgs = @("-o", "StrictHostKeyChecking=accept-new")
$SshArgs = $CommonArgs + @("-p", "$SshPort")
$ScpArgs = $CommonArgs + @("-P", "$SshPort")

Write-Host ""
Write-Host "服务器：  $Target（SSH 端口 $SshPort）"
Write-Host "对外端口：$WebPort"

# ---------- 1. 打包 ----------
Write-Step "打包项目代码（排除 node_modules、venv 等大目录）"

$StageDir = Join-Path $env:TEMP "tutorassistant_deploy"
if (Test-Path $StageDir) {
    Remove-Item $StageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $StageDir | Out-Null

$TarBall = Join-Path $StageDir "tutorassistant.tar.gz"

Push-Location $ProjectRoot
try {
    & tar -czf $TarBall `
        --exclude=frontend/node_modules `
        --exclude=frontend/.next `
        --exclude=frontend/out `
        --exclude=frontend/.env.local `
        --exclude=backend/venv `
        --exclude=backend/__pycache__ `
        --exclude=backend/.env `
        --exclude=backend/setup_env.py `
        --exclude=.git `
        frontend backend

    if ($LASTEXITCODE -ne 0) {
        throw "打包失败，tar 退出码 $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$SizeMb = [math]::Round((Get-Item $TarBall).Length / 1MB, 2)
Write-Host "打包完成，体积 $SizeMb MB"

# ---------- 2. 上传 ----------
Write-Step "上传到服务器"
Write-Warn "需要输入服务器密码；如果这是第一次连接这台服务器，会先提示确认指纹，输入 yes 回车即可。"

& scp @ScpArgs $TarBall $SetupScript "${Target}:/tmp/"
if ($LASTEXITCODE -ne 0) {
    Write-Fail "上传失败，请检查 IP、SSH 端口和密码是否正确，以及服务器是否已启动。"
    exit 1
}
Write-Host "上传完成。"

# ---------- 3. 远程安装 ----------
Write-Step "在服务器上安装并启动服务"
Write-Warn "接下来需要粘贴两个密钥，然后等待几分钟（首次安装依赖和构建前端都比较慢）。"

$RemoteCommand = "sed -i 's/\r`$//' /tmp/server-setup.sh && bash /tmp/server-setup.sh --public-ip $ServerIp --port $WebPort"

& ssh -t @SshArgs $Target $RemoteCommand
if ($LASTEXITCODE -ne 0) {
    Write-Fail "服务器上的部署脚本执行失败，请把上面的报错内容发给技术人员。"
    exit 1
}

# ---------- 完成 ----------
Write-Host ""
Write-Host "=============================================="
Write-Host " 部署完成" -ForegroundColor Green
Write-Host "=============================================="
Write-Host ""
Write-Host "访问地址：  http://${ServerIp}:$WebPort"
Write-Host "把这个网址发给朋友和家长就能用了。"
Write-Host ""
Write-Warn "如果打不开，去云厂商控制台的「防火墙 / 安全组」里放行 $WebPort 端口。"
Write-Host ""
Write-Warn "需要更新代码时，改完直接重新运行本脚本即可。"
Write-Host ""
