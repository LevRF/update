<#
.SYNOPSIS
  Публикует новую версию проекта как GitHub Release (тег <project>-v<version>) и загружает файлы.
  После публикации GitHub Action сам обновит manifest.json.

  Нужен токен в переменной окружения GITHUB_TOKEN:
  fine-grained token только на этот репозиторий с правом Contents: Read and write.

.EXAMPLE
  .\Publish-Release.ps1 -Project genom -Version 1.2.0 -Files .\build\genom-1.2.0.zip -Notes "Исправления"
  .\Publish-Release.ps1 -Project genom-db -Version 2026.10.23 -Files .\data\genom.db
#>
param(
    [Parameter(Mandatory)] [string]$Project,
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string[]]$Files,
    [string]$Notes = "",
    [string]$Repo = "LevRF/update"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not $env:GITHUB_TOKEN) { throw "Задайте переменную окружения GITHUB_TOKEN" }
if ($Project -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$") { throw "Недопустимое имя проекта: $Project" }
if ($Version -notmatch "^\d+(\.\d+)*(-[0-9A-Za-z.-]+)?$") { throw "Версия должна быть вида 1.2.0 или 1.2.0-beta.1" }

$items = $Files | ForEach-Object { Get-Item -LiteralPath $_ }
$tag = "$($Project.ToLower())-v$Version"
$headers = @{
    Authorization          = "Bearer $env:GITHUB_TOKEN"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# Сначала черновик: событие published (и сборка манифеста) должно случиться, когда файлы уже загружены
$body = @{ tag_name = $tag; name = "$Project $Version"; body = $Notes; draft = $true; prerelease = $Version.Contains("-") } | ConvertTo-Json
$release = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repo/releases" -Headers $headers `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8"
Write-Host "Создан черновик релиза $tag"

foreach ($f in $items) {
    Write-Host ("Загружаю {0} ({1:N1} МБ)" -f $f.Name, ($f.Length / 1MB))
    $uri = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets?name=$([Uri]::EscapeDataString($f.Name))"
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -InFile $f.FullName -ContentType "application/octet-stream" | Out-Null
}

$release = Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$Repo/releases/$($release.id)" -Headers $headers `
    -Body (@{ draft = $false } | ConvertTo-Json) -ContentType "application/json"

Write-Host "Готово: $($release.html_url)"
Write-Host "manifest.json обновится через ~1 минуту (GitHub Actions)."
