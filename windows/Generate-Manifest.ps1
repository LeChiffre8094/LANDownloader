param(
    [string]$Root = 'E:\迅雷下载',
    [string]$BaseURL = 'http://192.168.0.245:8080',
    [string]$OutputName = '_lan_manifest.json'
)
$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$extensions = @('.mp4','.mkv','.avi','.mov','.m4v','.wmv','.ts','.flv','.webm','.mpg','.mpeg','.iso')
$items = @(
    Get-ChildItem -LiteralPath $rootPath -File -Recurse | Where-Object {
        $extensions -contains $_.Extension.ToLowerInvariant() -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length).TrimStart('\')
        $parts = $relative -split '\\'
        $urlPath = ($parts | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        [pscustomobject]@{
            path = ($parts -join '/')
            name = $_.Name
            size = [long]$_.Length
            url = $BaseURL.TrimEnd('/') + '/' + $urlPath
        }
    } | Sort-Object path
)
$manifest = [pscustomobject]@{
    version = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    files = $items
}
$json = ConvertTo-Json -InputObject $manifest -Depth 6
$outPath = Join-Path $rootPath $OutputName
[IO.File]::WriteAllText($outPath, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Generated $($items.Count) files: $outPath"
