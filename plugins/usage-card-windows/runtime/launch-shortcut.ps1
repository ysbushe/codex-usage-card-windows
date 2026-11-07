$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
function Show-Notice([string]$message) { [void][System.Windows.Forms.MessageBox]::Show($message, 'Codex 额度圆环', 'OK', 'Information') }
function Show-HealthWarningAsync {
  $script = "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('暂未确认圆环已挂载并读取额度。请运行检查状态；也可能是客户端或账号数据不兼容。','Codex 额度圆环','OK','Warning')"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -WindowStyle Hidden | Out-Null
}

function Find-ConflictingUsageAgents([int]$session) {
  $found = @()
  foreach ($node in @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop)) {
    if ($node.SessionId -ne $session) { continue }
    if (-not $node.CommandLine) { throw '无法核实当前会话中 Node 进程的用途；请关闭旧版额度助手后重试。' }
    $m = [regex]::Match($node.CommandLine, '(?i)(?:"([^"]*[\\/]agent\.cjs)"|(?:^|\s)(\S*[\\/]agent\.cjs))(?=\s|$)')
    if (-not $m.Success) { continue }
    $path = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    try {
      $file = Get-Item -LiteralPath $path -ErrorAction Stop
      if ($file.PSIsContainer -or $file.Length -gt 2097152) { throw '文件过大或不是普通文件' }
      $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    } catch { throw '无法核实正在运行的 agent.cjs；请检查并关闭旧版额度助手后重试。' }
    if ($content.Contains('__codexUsageBadge') -and $content.Contains('account/rateLimits/read') -and $content.Contains('39222')) { $found += $node }
  }
  return $found
}
function Owned-Process($proc, $exe, $session) {
  try { return $proc.SessionId -eq $session -and [string]::Equals($proc.Path, $exe, [StringComparison]::OrdinalIgnoreCase) } catch { return $false }
}
$mutex = $null; $lockHeld = $false; $helper = $null
try {
  $mutex = New-Object System.Threading.Mutex($false, "Local\CodexUsageCardLauncher-$env:USERNAME")
  try { $lockHeld = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $lockHeld = $true }
  if (-not $lockHeld) { return }
  $pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
  if (-not $pkg) { throw '未找到已安装的 Microsoft Store 版 Codex。' }
  $app = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $app)) { throw '未找到 Codex 程序。' }
  $session = (Get-Process -Id $PID).SessionId
  $codexProcesses = @()
  foreach ($proc in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
    if ($proc.SessionId -ne $session) { continue }
    try { $exe = $proc.Path } catch { throw '无法核实 ChatGPT 进程路径，已停止操作。' }
    if (-not $exe) { throw '无法核实 ChatGPT 进程路径，已停止操作。' }
    if ([string]::Equals($exe, $app, [StringComparison]::OrdinalIgnoreCase)) { $codexProcesses += $proc }
  }
  $listeners = @(Get-NetTCPConnection -LocalPort 39222 -State Listen -ErrorAction SilentlyContinue)
  $main = $null
  if ($listeners.Count -gt 0) {
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1') { throw '调试端口被占用或监听地址不安全。请关闭冲突程序后重试。' }
    $main = Get-Process -Id $listeners[0].OwningProcess -ErrorAction Stop
    if (-not (Owned-Process $main $app $session)) { throw '调试端口不属于当前会话中的 Codex，已停止操作。' }
    $details = Get-CimInstance Win32_Process -Filter "ProcessId = $($main.Id)" -ErrorAction Stop
    if ($details.CommandLine -notmatch '(?:^|\s)--remote-debugging-port=39222(?:\s|$)') { throw '无法确认 Codex 调试端口的启动参数，已停止操作。' }
  } elseif ($codexProcesses.Count -gt 0) {
    if (@($codexProcesses | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) { throw 'Codex 正在运行但没有开启圆环所需连接。请先保存工作，完全退出 Codex，再点击快捷方式。' }
    $choice = [System.Windows.Forms.MessageBox]::Show("发现 $($codexProcesses.Count) 个 Codex 后台进程。结束它们可能中断后台工作。`n`n确认已保存工作并结束这些进程？", 'Codex 额度圆环', 'YesNo', 'Warning')
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    foreach ($proc in $codexProcesses) {
      $again = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
      if (-not $again) { continue }
      if (-not (Owned-Process $again $app $session) -or $again.StartTime -ne $proc.StartTime -or $again.MainWindowHandle -ne 0) { throw 'Codex 进程状态已变化，已停止操作。' }
      Stop-Process -Id $again.Id -ErrorAction Stop
    }
    foreach ($proc in $codexProcesses) { Wait-Process -Id $proc.Id -Timeout 10 -ErrorAction SilentlyContinue }
    if (@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { Owned-Process $_ $app $session }).Count -gt 0) { throw 'Codex 后台进程仍在运行，请检查后重试。' }
  }
  if (-not $main) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,39222)
    try { $listener.Start() } catch { throw '调试端口 39222 不可用。' } finally { $listener.Stop() }
    $launched = Start-Process -FilePath $app -ArgumentList '--remote-debugging-address=127.0.0.1','--remote-debugging-port=39222' -PassThru
    for ($i=0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 1
      $found = @(Get-NetTCPConnection -LocalPort 39222 -State Listen -ErrorAction SilentlyContinue)
      if ($found.Count -eq 1 -and $found[0].LocalAddress -eq '127.0.0.1') {
        $candidate = Get-Process -Id $found[0].OwningProcess -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.Id -eq $launched.Id -and (Owned-Process $candidate $app $session) -and $candidate.StartTime -eq $launched.StartTime) { $main = $candidate; break }
        throw '调试端口由其他进程占用，已停止操作。'
      }
      if ($found.Count -gt 0) { throw '调试端口被占用或监听地址不安全。' }
    }
    if (-not $main) { throw '30 秒内未检测到 Codex 调试连接；客户端仍可正常使用。' }
  }
  $mainStart = $main.StartTime
  $agentPath = Join-Path $PSScriptRoot 'agent.cjs'
  $existing = @(Find-ConflictingUsageAgents $session)
  if ($existing.Count -gt 0) {
    if ($existing.Count -eq 1 -and $existing[0].CommandLine.IndexOf($agentPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and [regex]::IsMatch($existing[0].CommandLine, '(?:^|\s)--expected-pid\s+' + [regex]::Escape([string]$main.Id) + '(?:\s|$)')) {
      try { $shell = New-Object -ComObject WScript.Shell; [void]$shell.AppActivate($main.Id) } catch {}; return
    }
    throw '检测到其他版本的额度助手正在运行。请关闭其启动窗口后重试；不会自动结束这些进程。'
  }
  $node = Join-Path $pkg.InstallLocation 'app\resources\cua_node\bin\node.exe'
  if (-not (Test-Path -LiteralPath $node)) { $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source }
  if (-not $node -or -not (Test-Path -LiteralPath $node)) { throw '未找到 Node.js 22 或更新版本。' }
  & $node -e "if(typeof WebSocket!=='function'||typeof fetch!=='function')process.exit(1)" 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'Node.js 不支持所需功能，请安装 Node.js 22 或更新版本。' }
  $quotedAgent = '"' + $agentPath + '"'
  $quotedApp = '"' + $app + '"'
  $statusFile = Join-Path $PSScriptRoot 'status.json'
  $quotedStatus = '"' + $statusFile + '"'
  $helper = Start-Process -FilePath $node -ArgumentList @($quotedAgent,'--app',$quotedApp,'--expected-pid',([string]$main.Id),'--status-file',$quotedStatus) -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 1
  if ($helper.HasExited) { throw '额度助手启动失败；请关闭旧的助手或检查客户端兼容性。' }
  $mutex.ReleaseMutex(); $lockHeld = $false
  $healthClock = [Diagnostics.Stopwatch]::StartNew(); $healthWarned = $false
  while (-not $helper.HasExited) {
    Start-Sleep -Seconds 3
    $current = Get-Process -Id $main.Id -ErrorAction SilentlyContinue
    if (-not $current -or $current.StartTime -ne $mainStart -or -not (Owned-Process $current $app $session)) { break }
    if (-not $healthWarned -and $healthClock.Elapsed.TotalSeconds -ge 45) {
      $healthy = $false
      try {
        $state = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$state.updatedAt
        $healthy = [int]$state.pid -eq $helper.Id -and $age -ge 0 -and $age -le 30000 -and $state.connected -eq $true -and $state.mounted -eq $true -and $state.usageAvailable -eq $true
      } catch {}
      if (-not $healthy) { try { Show-HealthWarningAsync } catch {} }
      $healthWarned = $true
    }
  }
  if (-not $helper.HasExited) { $helper.Kill() }
  else {
    $current = Get-Process -Id $main.Id -ErrorAction SilentlyContinue
    if ($current -and $current.StartTime -eq $mainStart -and (Owned-Process $current $app $session)) { Show-Notice '额度助手已退出，Codex 仍在运行。请检查是否有其他助手或重新启动快捷方式。' }
  }
} catch { Show-Notice "启动失败：$($_.Exception.Message)" }
finally {
  if ($helper) { try { if (-not $helper.HasExited) { $helper.Kill() } } catch {} }
  if ($lockHeld) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
}
