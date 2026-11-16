param([string]$ProjectRoot, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $ProjectRoot 'release' }
$BuildDir = Join-Path $ProjectRoot 'apps/client/build/windows/x64/runner/Release'
$versionLine = Select-String -LiteralPath (Join-Path $ProjectRoot 'apps/client/pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+'
if (-not $versionLine) { throw 'Client release version is missing.' }
$version = $versionLine.Matches[0].Groups[1].Value
$PackageDir = Join-Path $OutputDirectory "WeekGlass-Windows-x64-$version"
$HelperPath = Join-Path $ProjectRoot 'release/weekglass_updater.exe'
$ZipPath = "$PackageDir.zip"
if (-not (Test-Path -LiteralPath (Join-Path $BuildDir 'weekglass.exe'))) { throw 'Build Windows release first.' }
if (-not (Test-Path -LiteralPath $HelperPath)) { throw 'Compile the production update helper before packaging.' }
if (Test-Path -LiteralPath $PackageDir) { throw "Package already exists: $PackageDir. Choose a fresh output directory." }
# Use the same toolchain override and configured default as tooling/env.ps1.
# Do not load the complete Flutter/Android environment to package a built app.
$toolchainRoot = $env:WEEKGLASS_TOOLCHAIN_HOME
if (-not $toolchainRoot) {
  $versions = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tooling/versions.json') -Raw | ConvertFrom-Json
  $toolchainRoot = [string]$versions.toolchainRoot
}
$vsInstallations = @()
if ($toolchainRoot) { $vsInstallations += Join-Path $toolchainRoot 'vs-buildtools' }
$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if ($programFilesX86) {
  $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
  if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
    $vsInstallations += @(& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  }
}
$crtDir = foreach ($installation in ($vsInstallations | Select-Object -Unique)) {
  $redist = Join-Path $installation 'VC/Redist/MSVC'
  if (-not (Test-Path -LiteralPath $redist -PathType Container)) { continue }
  $match = Get-ChildItem -LiteralPath $redist -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'vcruntime140.dll') -PathType Leaf } |
    Select-Object -First 1
  if ($match) { $match; break }
}
if (-not $crtDir) { throw 'Microsoft Visual C++ x64 runtime not found. Install the Visual Studio x64 C++ tools or set WEEKGLASS_TOOLCHAIN_HOME to the WeekGlass toolchain directory.' }
New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null
Copy-Item -Path (Join-Path $BuildDir '*') -Destination $PackageDir -Recurse
Copy-Item -Path (Join-Path $crtDir '*.dll') -Destination $PackageDir
Copy-Item -LiteralPath $HelperPath -Destination $PackageDir
$guide = @'
# WeekGlass 使用说明

版本 {VERSION}，适用于 Windows 10 1809 及以上的 64 位系统。

## 开始使用

使用安装程序可自选安装目录，并建立桌面和开始菜单快捷方式。若下载的是便携 ZIP，请完整解压后运行 weekglass.exe，不要单独移动 EXE 或删除 DLL、data 文件夹及 weekglass_updater.exe。

本地日历免费，无需注册。点击空白时间创建日程；拖动可选取时段。单击日程查看详情，在「调整」中编辑，在「复制」中快速安排相同事项。短日程保持真实长度，悬停可查看完整名称、时间与备注。

设置中可调整外观、显示和通知，导入或导出日程。日程和本机偏好保存在 Windows 用户的应用数据目录，更新程序不会清空日历。

## 官方云与自托管

在设置中连接独立的 WeekGlass 云账号。账号管理、订单和订阅方案位于 https://cloud.viliana.cn/account 。WeekGlass 账号与 Viliana 主站账号相互独立。

官方云同步 ¥1.00／30 天或 ¥9.99／365 天，微信单次付款，不自动续费。未开通或已到期时，不进行云端上传、下载或合并；本地日历照常可用。有效服务期间首次连接需确认合并，之后自动增量同步。

到期后可从网站账号管理自助导出一次云端日程，请妥善保管文件。下载失败可以继续下载同一份导出。自托管同步免费，与官方订阅无关。

## 课表与文件

目前支持已通过实际账号验证的武汉大学课表导入。按学校页面完成登录，核对第一教学周、课程和节次后导入；可选择排除假期。学校要求验证时，请在官方页面完成。

Windows 支持本机识别课表图片。也可导入 ICS、JSON、CSV 或粘贴课表文字；识别结果确认后才加入日历。导出支持日程文件、彩色 PDF 和黑白 PDF。

学校登录使用 Microsoft Edge WebView2 Runtime。若系统缺少此组件，请从微软官方网站安装：https://developer.microsoft.com/microsoft-edge/webview2/ 。

## 关闭与更新

关闭主窗口默认收回托盘，仍可提醒日程。右键托盘图标选择「退出 WeekGlass」才完全退出。重复打开会唤回现有窗口，不另开一份。

设置中检查更新。更新支持增量传输和断点续传，并使用内置公钥验证；自托管地址不会改变软件更新的信任来源。Windows 程序尚无公信代码签名，系统可能显示「未知发布者」，请核对下载来源。

## 支持

官网：https://cloud.viliana.cn
源码：https://github.com/Vilianastclair/WeekGlass
邮箱：support@viliana.cn

设置标题下方可前往 GitHub 点 Star，底部「友情赞助」为自愿支持，不购买云同步权益。
'@
$guide.Replace('{VERSION}', $version) | Set-Content -LiteralPath (Join-Path $PackageDir '使用说明.md') -Encoding utf8
Compress-Archive -Path $PackageDir -DestinationPath $ZipPath -CompressionLevel Optimal
Get-Item -LiteralPath $ZipPath | Select-Object FullName,Length
Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
