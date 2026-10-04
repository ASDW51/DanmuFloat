<#
  生成 Android release 签名 keystore，并导出 CI 所需的 base64 文本。

  用法（Windows PowerShell）：
    powershell -ExecutionPolicy Bypass -File scripts\generate-keystore.ps1
    powershell -ExecutionPolicy Bypass -File scripts\generate-keystore.ps1 -Alias danmufloat -ValidityDays 10000

  产物：
    android\app\<FileName>              签名文件（已 .gitignore，勿提交）
    android\key.properties              Gradle 读取的签名配置（已 .gitignore，勿提交）
    android\app\<FileName>.base64.txt   仅用于粘贴到 CI Secrets 的 base64（已 .gitignore，勿提交）

  注意：keystore 一旦丢失，已用该签名发布的应用将无法再更新，请务必离线备份。
#>
[CmdletBinding()]
param(
    [string]$Alias = 'danmufloat',
    [string]$FileName = 'danmu-float-release.jks',
    [int]$ValidityDays = 10000,
    [int]$KeySize = 2048,
    [string]$StoreType = 'PKCS12',
    [string]$DName = 'CN=DanmuFloat, OU=DanmuFloat, O=DanmuFloat, L=Beijing, ST=Beijing, C=CN',
    [string]$OutDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'android\app' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

$keystorePath = Join-Path $OutDir $FileName
$keyPropsPath = Join-Path $repoRoot 'android\key.properties'
$base64Path = Join-Path $OutDir ($FileName + '.base64.txt')

function Get-KeytoolPath {
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    $cmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw '未找到 keytool。请安装 JDK 并设置 JAVA_HOME，或把 keytool 所在目录加入 PATH。'
}

function Read-PlainPassword([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$keytool = Get-KeytoolPath
Write-Host "使用 keytool: $keytool"

if ((Test-Path $keystorePath) -and -not $Force) {
    throw "keystore 已存在：$keystorePath`n如需覆盖请追加 -Force（覆盖后旧签名文件不可恢复）。"
}

$pw1 = Read-PlainPassword '请输入 keystore 密码（至少 6 位）'
if ($pw1.Length -lt 6) { throw 'keystore 密码至少 6 位。' }
$pw2 = Read-PlainPassword '请再次输入以确认'
if ($pw1 -ne $pw2) { throw '两次输入的密码不一致。' }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Write-Host '正在生成 keystore ...'
# 说明：密码经命令行参数传给 keytool，会短暂出现在本机进程列表；请在可信环境执行。
# keytool 的 -v 进度输出走 stderr，需临时放宽 ErrorActionPreference，避免被当作终止错误。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $keytool -genkeypair -v `
        -keystore $keystorePath `
        -storetype $StoreType `
        -keyalg RSA `
        -keysize $KeySize `
        -validity $ValidityDays `
        -alias $Alias `
        -dname $DName `
        -storepass $pw1 `
        -keypass $pw1 2>&1 | Out-Host
    $keytoolExit = $LASTEXITCODE
}
finally { $ErrorActionPreference = $prevEap }
if ($keytoolExit -ne 0) { throw "keytool 执行失败（退出码 $keytoolExit）。" }

$keyProps = @(
    "storePassword=$pw1"
    "keyPassword=$pw1"
    "keyAlias=$Alias"
    "storeFile=$FileName"
) -join "`n"
[System.IO.File]::WriteAllText($keyPropsPath, $keyProps + "`n", [System.Text.UTF8Encoding]::new($false))

$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($keystorePath))
[System.IO.File]::WriteAllText($base64Path, $b64, [System.Text.Encoding]::ASCII)

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
Write-Host "  签名文件   : $keystorePath"
Write-Host "  签名配置   : $keyPropsPath"
Write-Host "  base64 文本: $base64Path"
Write-Host ''
Write-Host '下一步：把以下内容分别填入 CI Secrets（值见上面对应文件）：'
Write-Host '  ANDROID_KEYSTORE_BASE64  <- *.base64.txt 全文（单行，勿换行）'
Write-Host '  ANDROID_STORE_PASSWORD   <- key.properties 的 storePassword'
Write-Host '  ANDROID_KEY_PASSWORD     <- key.properties 的 keyPassword'
Write-Host '  ANDROID_KEY_ALIAS        <- key.properties 的 keyAlias'
Write-Host ''
Write-Host '提醒：以上三个产物均已被 .gitignore 忽略，请勿提交；keystore 请离线备份。' -ForegroundColor Yellow