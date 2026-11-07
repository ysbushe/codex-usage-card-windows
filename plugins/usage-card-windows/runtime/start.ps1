$ErrorActionPreference = 'Stop'
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
try {
  $pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
  if (-not $pkg) { throw '未找到 Microsoft Store 版 Codex。' }
  $app = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $app)) { throw '未找到 Codex 启动程序。' }
  $sessionId = (Get-Process -Id $PID).SessionId
  if (@(Find-ConflictingUsageAgents $sessionId).Count -gt 0) { throw '检测到额度助手已在运行，请关闭旧的启动窗口后重试。' }
  $remaining = @()
  foreach ($p in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
    if ($p.SessionId -ne $sessionId) { continue }
    try { $exe = $p.Path } catch { throw "无法核实 ChatGPT 进程 $($p.Id) 的路径，请检查进程权限。" }
    if (-not $exe) { throw "无法核实 ChatGPT 进程 $($p.Id) 的路径，请检查进程权限。" }
    if ([string]::Equals($exe, $app, [StringComparison]::OrdinalIgnoreCase)) { $remaining += $p }
  }
  if ($remaining.Count -gt 0) {
    if (@($remaining | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) { throw 'Codex 窗口仍在运行。请保存工作并正常退出后重试。' }
    Write-Host "发现 $($remaining.Count) 个属于当前 Codex 安装的后台进程。结束它们可能中断后台工作。"
    $answer = Read-Host '确认已保存工作并结束这些后台进程？输入 Y 继续，其他输入取消'
    if ($answer -notmatch '^(y|yes)$') { throw '已取消启动。' }
    foreach ($p in $remaining) {
      $current = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
      if (-not $current) { continue }
      if ($current.SessionId -ne $sessionId -or $current.StartTime -ne $p.StartTime -or -not [string]::Equals($current.Path, $app, [StringComparison]::OrdinalIgnoreCase) -or $current.MainWindowHandle -ne 0) { throw '进程状态已变化，为避免中断工作已停止。请重试。' }
      Stop-Process -Id $current.Id -ErrorAction Stop
    }
    foreach ($p in $remaining) { Wait-Process -Id $p.Id -Timeout 10 -ErrorAction SilentlyContinue }
    if (@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId -and $_.Path -eq $app }).Count -gt 0) { throw 'Codex 后台进程未完全退出，请检查后重试。' }
  }
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 39222)
  try { $listener.Start() } catch { throw '本机端口 39222 不可用，请检查端口占用。' } finally { $listener.Stop() }
  $nodeCandidates = @((Join-Path $pkg.InstallLocation 'app\resources\cua_node\bin\node.exe'))
  $nodePath = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
  if ($nodePath) { $nodeCandidates += $nodePath }
  $node = $null
  foreach ($candidate in $nodeCandidates) {
    if (Test-Path -LiteralPath $candidate) {
      & $candidate -e "if(typeof WebSocket!=='function'||typeof fetch!=='function')process.exit(1)" 2>$null
      if ($LASTEXITCODE -eq 0) { $node = $candidate; break }
    }
  }
  if (-not $node) { throw '找不到支持 WebSocket 和 fetch 的 Node.js；请安装 Node.js 22 或更新版本。' }
  Write-Host '正在启动 Codex。此窗口运行期间请保持打开。'
  $launched = Start-Process -FilePath $app -ArgumentList '--remote-debugging-address=127.0.0.1','--remote-debugging-port=39222' -PassThru
  $connected = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $found = @(Get-NetTCPConnection -LocalPort 39222 -State Listen -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1 -and $found[0].LocalAddress -eq '127.0.0.1') {
      $candidate = Get-Process -Id $found[0].OwningProcess -ErrorAction SilentlyContinue
      if ($candidate -and $candidate.Id -eq $launched.Id -and $candidate.SessionId -eq $sessionId -and $candidate.StartTime -eq $launched.StartTime -and [string]::Equals($candidate.Path, $app, [StringComparison]::OrdinalIgnoreCase)) { $connected = $true; break }
      throw '调试端口由其他进程占用，已停止操作。'
    }
    if ($found.Count -gt 0) { throw '调试端口被占用或监听地址不安全。' }
  }
  if (-not $connected) { throw '30 秒内未检测到调试接口。请检查客户端是否启动、是否已完全退出旧实例，以及客户端版本是否兼容。' }
  & $node (Join-Path $PSScriptRoot 'agent.cjs') --app $app --expected-pid ([string]$launched.Id)
  if ($LASTEXITCODE -ne 0) { throw "额度助手退出，代码 $LASTEXITCODE。" }
} catch {
  Write-Host "启动失败：$($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
