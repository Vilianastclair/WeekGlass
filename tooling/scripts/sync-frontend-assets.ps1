param(
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$Previews,
    [string]$PythonExe = 'python'
)
$ErrorActionPreference = 'Stop'
$assetRoot = (Get-Item -LiteralPath $Destination).FullName.TrimEnd('\')
if ((Split-Path -Leaf $assetRoot) -ne '前端') { throw 'Expected the selected 前端 asset folder.' }
function Assert-AssetPath([string]$Path) {
    $resolved = (Get-Item -LiteralPath $Path -Force).FullName
    if (-not $resolved.StartsWith($assetRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Outside the selected asset directory: $resolved"
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refuse link: $resolved" }
    if ($item.PSIsContainer) {
        $links = @(Get-ChildItem -LiteralPath $resolved -Force -Recurse -Attributes ReparsePoint)
        if ($links.Count -gt 0) { throw "Refuse directory containing links: $resolved" }
    }
    return $resolved
}
if ((Get-Item -LiteralPath $assetRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Refuse a linked asset destination.'
}
foreach ($child in @(Get-ChildItem -LiteralPath $assetRoot -Force)) {
    $null = Assert-AssetPath $child.FullName
}
$before = (Get-ChildItem -LiteralPath $assetRoot -File -Recurse | Measure-Object Length -Sum).Sum
$exportText = & $PythonExe (Join-Path $PSScriptRoot 'archive-frontend.py') --destination $assetRoot --previews $Previews
if ($LASTEXITCODE -ne 0) { throw 'Asset export failed; nothing was removed.' }
$export = $exportText | ConvertFrom-Json
$bundle = Assert-AssetPath $export.bundle
$keep = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($record in $export.files) {
    $asset = Assert-AssetPath (Join-Path $bundle $record.path)
    if ((Get-Item -LiteralPath $asset).Length -ne $record.bytes) {
        throw "New asset did not verify; nothing was removed: $asset"
    }
    $null = $keep.Add($asset)
}
# Verify every selected asset before removing anything from the old export.
foreach ($file in @(Get-ChildItem -LiteralPath $bundle -File -Recurse -Force)) {
    if (-not $keep.Contains($file.FullName)) {
        $target = Assert-AssetPath $file.FullName
        Remove-Item -LiteralPath $target -Force
    }
}
foreach ($folder in @(Get-ChildItem -LiteralPath $bundle -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)) {
    if (@(Get-ChildItem -LiteralPath $folder.FullName -Force).Count -eq 0) {
        $target = Assert-AssetPath $folder.FullName
        Remove-Item -LiteralPath $target -Force
    }
}
foreach ($child in @(Get-ChildItem -LiteralPath $assetRoot -Force)) {
    if ($child.FullName -eq $bundle) { continue }
    if ($child.Name -match '^WeekGlass-前端设计-v\d+\.\d+\.\d+(\.zip)?$' -or
        $child.Name -match '^归档校验-v\d+\.\d+\.\d+\.json$' -or $child.Name -eq 'README.md') {
        $target = Assert-AssetPath $child.FullName
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
$remaining = @(Get-ChildItem -LiteralPath $assetRoot -File -Recurse)
$after = ($remaining | Measure-Object Length -Sum).Sum
[pscustomobject]@{Folder=$bundle;Files=$remaining.Count;Bytes=$after;RemovedBytes=$before-$after} | ConvertTo-Json
