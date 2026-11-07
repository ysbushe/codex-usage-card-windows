param(
 [ValidateSet('install','status','uninstall')][string]$Action = 'status',
 [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'CodexUsageCardWindows'),
 [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Codex 额度圆环.lnk')
)
$ErrorActionPreference = 'Stop'
$markerName = 'codex-usage-card-windows.marker'
$markerText = 'codex-usage-card-windows-v1'
$installFull = [IO.Path]::GetFullPath($InstallDir)
$linkFull = [IO.Path]::GetFullPath($ShortcutPath)
$marker = Join-Path $installFull $markerName
$launcher = Join-Path $installFull 'launch-shortcut.ps1'
$agent = Join-Path $installFull 'agent.cjs'
$iconFile = Join-Path $installFull 'codex.ico'
$statusFile = Join-Path $installFull 'status.json'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Is-OwnedInstall { return (Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $markerText }
function Is-OwnedShortcut {
 if (-not (Test-Path -LiteralPath $linkFull)) { return $false }
 $shell = New-Object -ComObject WScript.Shell
 $link = $shell.CreateShortcut($linkFull)
 return [string]::Equals($link.TargetPath, $powershell, [StringComparison]::OrdinalIgnoreCase) -and $link.Arguments.Contains('"'+$launcher+'"')
}
try {
 switch ($Action) {
  'install' {
   if ((Test-Path -LiteralPath $installFull) -and -not (Is-OwnedInstall)) { throw "安装目录已存在且不属于本程序：$installFull" }
   if ((Test-Path -LiteralPath $linkFull) -and -not (Is-OwnedShortcut)) { throw "快捷方式已存在且不属于本程序：$linkFull" }
   $pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
   if (-not $pkg) { throw '未找到 Microsoft Store 版 Codex。' }
   $app = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
   if (-not (Test-Path -LiteralPath $app)) { throw '未找到 Codex 程序。' }
   $source = Join-Path $PSScriptRoot 'plugins\usage-card-windows\runtime'
   if (-not (Test-Path -LiteralPath (Join-Path $source 'agent.cjs')) -or -not (Test-Path -LiteralPath (Join-Path $source 'launch-shortcut.ps1'))) { throw '安装包不完整，请完整解压后运行。' }
   Add-Type -AssemblyName System.Drawing
   $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($app)
   if (-not $icon) { throw '无法提取 Codex 图标，安装已中止。' }
   New-Item -ItemType Directory -Force -Path $installFull | Out-Null
   Set-Content -LiteralPath $marker -Value $markerText -Encoding ASCII
   try { $stream = [IO.File]::Open($iconFile,[IO.FileMode]::Create); try { $icon.Save($stream) } finally { $stream.Dispose() } } finally { $icon.Dispose() }
   Copy-Item -LiteralPath (Join-Path $source 'agent.cjs') -Destination $agent -Force
   Copy-Item -LiteralPath (Join-Path $source 'launch-shortcut.ps1') -Destination $launcher -Force
   Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $installFull 'manage-shortcut.ps1') -Force
   Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') -Destination (Join-Path $installFull 'LICENSE') -Force
   $commandPrefix = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-shortcut.ps1" '
   [IO.File]::WriteAllText((Join-Path $installFull '检查状态.cmd'), $commandPrefix + 'status' + "`r`npause`r`n", [Text.Encoding]::ASCII)
   [IO.File]::WriteAllText((Join-Path $installFull '卸载.cmd'), $commandPrefix + 'uninstall' + "`r`npause`r`n", [Text.Encoding]::ASCII)
   $shell = New-Object -ComObject WScript.Shell
   $link = $shell.CreateShortcut($linkFull)
   $link.TargetPath = $powershell
   $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
   $link.WorkingDirectory = $installFull
   $link.IconLocation = $iconFile + ',0'
   $link.Description = '启动 Codex 并显示额度圆环'
   $link.WindowStyle = 7
   $link.Save()
   Write-Host "已创建快捷方式：$linkFull"
   Write-Host '首次使用前请保存工作并完全退出 Codex，再双击该快捷方式。'
  }
  'status' {
   Write-Host ('安装文件：' + $(if (Is-OwnedInstall) {'存在'} else {'未找到'}))
   Write-Host ('专用快捷方式：' + $(if (Is-OwnedShortcut) {'存在'} else {'未找到或不匹配'}))
   $valid = $false
   try {
    $state = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$state.updatedAt
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$state.pid)" -ErrorAction Stop
    $valid = $age -ge 0 -and $age -le 30000 -and $proc.Name -eq 'node.exe' -and $proc.CommandLine -and $proc.CommandLine.IndexOf($agent,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $state.connected -is [bool] -and $state.mounted -is [bool] -and $state.usageAvailable -is [bool]
   } catch { $valid = $false }
   if ($valid) {
    Write-Host ('助手连接：' + $(if ($state.connected) {'已连接'} else {'未连接'}))
    Write-Host ('圆环挂载：' + $(if ($state.mounted) {'已确认'} else {'未确认'}))
    Write-Host ('额度读取：' + $(if ($state.usageAvailable) {'有可用数据'} else {'未确认可用数据'}))
   } else { Write-Host '助手运行状态不可用或已过期；请检查快捷方式及客户端。' }
   Write-Host '状态仅供诊断；显示效果请在 Codex 窗口中确认。'
  }
  'uninstall' {
   if (-not (Is-OwnedInstall)) { throw '未找到可确认归属的安装目录，未删除任何文件。' }
   $running = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($agent) })
   if ($running.Count -gt 0) { throw '本安装的额度助手仍在运行。请先完全退出 Codex 并等待数秒，再卸载。' }
   if (Is-OwnedShortcut) { Remove-Item -LiteralPath $linkFull -ErrorAction Stop }
   foreach ($file in @($launcher,$agent,$iconFile,$statusFile,(Join-Path $installFull 'LICENSE'),(Join-Path $installFull '检查状态.cmd'),(Join-Path $installFull '卸载.cmd'),(Join-Path $installFull 'manage-shortcut.ps1'),$marker)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -ErrorAction Stop } }
   if ((Test-Path -LiteralPath $installFull) -and @(Get-ChildItem -LiteralPath $installFull -Force).Count -eq 0) { Remove-Item -LiteralPath $installFull -ErrorAction Stop }
   Write-Host '已移除本方案的安装文件及其专用快捷方式。'
  }
 }
} catch { Write-Error $_; exit 1 }
