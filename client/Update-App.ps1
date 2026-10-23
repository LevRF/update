<#
.SYNOPSIS
  Клиент обновлений: сверяет локальную версию проекта с manifest.json
  в репозитории обновлений и ставит последний релиз. Работает в Windows PowerShell 5.1.

.EXAMPLE
  .\Update-App.ps1 -Project genom -Dir "C:\Program Files\Genom"
  .\Update-App.ps1 -Project genom-db -Dir data -Asset *.db
  .\Update-App.ps1 -Project genom -Check     # код выхода 10, если есть обновление

  Коды выхода: 0 — всё актуально/обновлено, 10 — есть обновление (-Check), 1 — ошибка.
#>
param(
    [Parameter(Mandatory)] [string]$Project,
    [string]$Dir = ".",
    [string]$Repo = "LevRF/update",
    [string]$Manifest,
    [string[]]$Asset,
    [switch]$Check,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # без этого Invoke-WebRequest в 5.1 качает в разы медленнее
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$StateFile = ".update.json"

function Get-VersionKey([string]$v) {
    $main, $pre = $v -split "-", 2
    $nums = [System.Collections.Generic.List[int]]($main -split "\." | ForEach-Object { [int]$_ })
    while ($nums.Count -gt 1 -and $nums[$nums.Count - 1] -eq 0) { $nums.RemoveAt($nums.Count - 1) }
    [pscustomobject]@{ Nums = $nums; Release = -not $pre; Pre = [string]$pre }
}

function Compare-Version([string]$a, [string]$b) {
    $ka = Get-VersionKey $a; $kb = Get-VersionKey $b
    $n = [Math]::Max($ka.Nums.Count, $kb.Nums.Count)
    for ($i = 0; $i -lt $n; $i++) {
        # отсутствующий компонент меньше любого присутствующего (как сравнение кортежей в Python)
        $x = if ($i -lt $ka.Nums.Count) { $ka.Nums[$i] } else { -1 }
        $y = if ($i -lt $kb.Nums.Count) { $kb.Nums[$i] } else { -1 }
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    if ($ka.Release -ne $kb.Release) { return $(if ($ka.Release) { 1 } else { -1 }) }
    return [string]::CompareOrdinal($ka.Pre, $kb.Pre)
}

function Get-File([string]$Url, [string]$Dest, [string]$Sha256) {
    $part = "$Dest.part"
    if ($Url -match "^https?://") {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -UserAgent "updater"
    } else {
        Copy-Item -LiteralPath $Url -Destination $part -Force
    }
    $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
    if ($hash -ne $Sha256.ToUpper()) {
        Remove-Item -LiteralPath $part -Force
        throw "$([IO.Path]::GetFileName($Dest)): контрольная сумма не совпала"
    }
    Move-Item -LiteralPath $part -Destination $Dest -Force
}

function Expand-Update([string]$Archive, [string]$Target) {
    $staging = Join-Path $Target ".update-staging"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    Expand-Archive -LiteralPath $Archive -DestinationPath $staging -Force
    Get-ChildItem -LiteralPath $staging -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($staging.Length + 1)
        $dst = Join-Path $Target $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Move-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
    Remove-Item -LiteralPath $staging -Recurse -Force
}

try {
    $Project = $Project.ToLower()
    $target = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Dir))
    if (-not $Manifest) { $Manifest = "https://raw.githubusercontent.com/$Repo/main/manifest.json" }

    if ($Manifest -match "^https?://") {
        # raw.githubusercontent.com кэширует ~5 минут, параметр обходит кэш
        $sep = if ($Manifest.Contains("?")) { "&" } else { "?" }
        $data = Invoke-RestMethod -Uri "$Manifest${sep}t=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -UseBasicParsing -UserAgent "updater"
    } else {
        $data = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $info = $data.projects.$Project
    if (-not $info) { throw "Проекта '$Project' нет в манифесте" }

    $statePath = Join-Path $target $StateFile
    $state = if (Test-Path -LiteralPath $statePath) {
        Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { [pscustomobject]@{} }
    $current = $state.$Project.version
    $latest = $info.version

    if ($current -and -not $Force -and (Compare-Version $current $latest) -ge 0) {
        Write-Host "${Project}: актуальная версия $current"
        exit 0
    }
    if ($Check) {
        Write-Host "${Project}: доступно обновление $(if ($current) { $current } else { '—' }) -> $latest"
        exit 10
    }

    $assets = @($info.assets | Where-Object {
        $name = $_.name
        -not $Asset -or ($Asset | Where-Object { $name -like $_ })
    })
    if ($assets.Count -eq 0) { throw "В релизе нет подходящих файлов" }

    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($a in $assets) {
        Write-Host ("Скачиваю {0} ({1:N1} МБ)" -f $a.name, ($a.size / 1MB))
        if ($a.name -like "*.zip") {
            $tmp = Join-Path $target (".update-" + $a.name)
            try {
                Get-File $a.url $tmp $a.sha256
                Expand-Update $tmp $target
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        } else {
            Get-File $a.url (Join-Path $target $a.name) $a.sha256
        }
    }

    $entry = [pscustomobject]@{ version = $latest; updated = [DateTimeOffset]::UtcNow.ToString("o") }
    $state | Add-Member -NotePropertyName $Project -NotePropertyValue $entry -Force
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    Write-Host "${Project}: обновлено до $latest"
    exit 0
} catch {
    Write-Host "Ошибка обновления: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
