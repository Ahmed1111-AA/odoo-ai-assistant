# Simple static file server for the Odoo AI Assistant
# Serves index.html on http://localhost:8080

param([int]$Port = 8080)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:${Port}/")
$listener.Start()

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Static File Server" -ForegroundColor Green
Write-Host "  Open: http://localhost:${Port}" -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$root = $PSScriptRoot

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.LocalPath
    if ($path -eq "/" -or $path -eq "") { $path = "/index.html" }

    $filePath = Join-Path $root $path.TrimStart("/")
    $response = $context.Response

    if (Test-Path $filePath) {
        $content = [System.IO.File]::ReadAllBytes($filePath)
        $ext = [System.IO.Path]::GetExtension($filePath)
        $mime = switch ($ext) {
            ".html" { "text/html; charset=utf-8" }
            ".js"   { "application/javascript" }
            ".css"  { "text/css" }
            ".json" { "application/json" }
            ".png"  { "image/png" }
            ".svg"  { "image/svg+xml" }
            default { "application/octet-stream" }
        }
        $response.ContentType = $mime
        $response.ContentLength64 = $content.Length
        $response.OutputStream.Write($content, 0, $content.Length)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 200 $path" -ForegroundColor Gray
    } else {
        $response.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
        $response.ContentLength64 = $msg.Length
        $response.OutputStream.Write($msg, 0, $msg.Length)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 404 $path" -ForegroundColor Red
    }
    $response.Close()
}
