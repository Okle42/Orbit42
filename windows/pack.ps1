# Orbit42 Windows 版打包＋安裝（Mac scripts/build_app.sh 的對應）
#   pwsh windows\pack.ps1            發佈 Release → %LOCALAPPDATA%\Programs\Orbit42，桌面與開始選單放捷徑
#   pwsh windows\pack.ps1 -NoInstall 只發佈到 windows\out\Orbit42
# 需要 .NET 8 Desktop Runtime 與 WebView2 Runtime（Windows 11 內建）
param([switch]$NoInstall, [string]$ShoWork42Dir = "")
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Join-Path $here 'Orbit42.Win\Orbit42.Win.csproj'
$out = Join-Path $here 'out\Orbit42'
if (-not $ShoWork42Dir) { $ShoWork42Dir = Join-Path $here '..\Engine' }
# 跟 ShoWork42 的 windows\pack.ps1 一樣：hook CLI（showork.exe，獨立式）先單獨發佈，再用 PackShowork 內嵌，
# ShoWork.Win 就不會帶著專案引用（不然 NETSDK1151：非獨立式不能引用獨立式）
$cli = Join-Path $here 'out\cli'
& dotnet publish (Join-Path $ShoWork42Dir 'windows\showork\showork.csproj') -c Release -r win-x64 -o $cli -nologo -v q
if ($LASTEXITCODE -ne 0) { throw "showork.exe 發佈失敗" }
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
& dotnet publish $proj -c Release -r win-x64 --self-contained false -o $out -nologo -v q "-p:ShoWork42Dir=$ShoWork42Dir" "-p:PackShowork=$cli\showork.exe"
if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失敗" }
Copy-Item "$cli\showork.exe" $out
if ($NoInstall) { "published $out"; return }
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Orbit42'
# 正在跑的 Orbit42 先關掉才換得掉檔案（它結束時會把 ShoWorkAgent 開回來）
$running = @(Get-Process Orbit42 -EA SilentlyContinue)
if ($running) {
  # 請它自己正常結束（記下衛星、把 ShoWorkAgent 開回來）；從 ssh 送關視窗送不到桌面，所以用檔案
  Set-Content (Join-Path $env:LOCALAPPDATA 'Orbit42\quit.request') 'pack'
  foreach ($p in $running) { if (-not $p.WaitForExit(15000)) { $p.Kill($true); Write-Warning "Orbit42 沒有自己結束，強制關掉（這次衛星不會接回）" } }
  Remove-Item (Join-Path $env:LOCALAPPDATA 'Orbit42\quit.request') -EA SilentlyContinue
}
New-Item -ItemType Directory -Force $dest | Out-Null
robocopy $out $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
$exe = Join-Path $dest 'Orbit42.exe'
$sh = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
  $l = $sh.CreateShortcut((Join-Path $dir 'Orbit42.lnk'))
  $l.TargetPath = $exe; $l.WorkingDirectory = $dest; $l.Description = 'Orbit42：球體是桌面，每個 AI 是一顆衛星'
  $l.IconLocation = "$exe,0"; $l.Save()
}
"installed $exe"
