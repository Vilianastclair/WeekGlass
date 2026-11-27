# Compile the published shader entry points and sample the real Direct3D compositor.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../env.ps1')
$client = Join-Path $ProjectRoot 'apps/client'
$runner = Join-Path $client 'windows/runner'
$qa = Join-Path $client '.dart_tool/corner-probe'
New-Item -Type Directory -Force $qa | Out-Null
$vc = (Get-ChildItem "$ToolchainRoot/vs-buildtools/VC/Tools/MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$kit = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Windows Kits/10'
$sdk = (Get-ChildItem "$kit/Include" -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$env:PATH = "$vc/bin/Hostx64/x64;$env:PATH"
Push-Location $qa
try {
  foreach ($entry in 'SheetVS','SheetPS','GlintVS','GlintPS') {
    $profile = if ($entry.EndsWith('VS')) { 'vs_4_0' } else { 'ps_4_0' }
    & "$kit/bin/$sdk/x64/fxc.exe" /nologo /Ges /O3 /E $entry /T $profile /Qstrip_reflect /Qstrip_debug /Fh "$entry.h" /Vn "k$entry" "$runner/vortex.hlsl"
    if ($LASTEXITCODE) { throw "Shader failed: $entry" }
  }
  & "$vc/bin/Hostx64/x64/cl.exe" /nologo /std:c++17 /O2 /MD /EHsc /W4 /WX /wd4100 /DNOMINMAX /DWG_VORTEX_CORNER_PROBE "/I$vc/include" "/I$kit/Include/$sdk/winrt" "/I$kit/Include/$sdk/um" "/I$kit/Include/$sdk/shared" "/I$kit/Include/$sdk/ucrt" "/I$qa" "/I$runner" "$client/test/native/vortex_corner_probe.cpp" "$runner/vortex_renderer.cpp" /Fe:corner_probe.exe /link "/LIBPATH:$vc/lib/x64" "/LIBPATH:$kit/Lib/$sdk/um/x64" "/LIBPATH:$kit/Lib/$sdk/ucrt/x64" d3d11.lib dxgi.lib dcomp.lib dwmapi.lib user32.lib gdi32.lib
  if ($LASTEXITCODE) { throw 'Probe compilation failed' }
  & ./corner_probe.exe
  if ($LASTEXITCODE) { throw 'Corner pixel check failed' }
} finally { Pop-Location }
