<#
.SYNOPSIS
  Клиент обновлений: сверяет локальную версию проекта с manifest.json
  в репозитории обновлений и ставит последний релиз. Работает в Windows PowerShell 5.1.

  Каждый файл проверяется по SHA-256 и по подписи RSA, сделанной закрытым ключом владельца.
  Неподписанные или изменённые файлы не устанавливаются, даже если репозиторий взломан.

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

# Открытый ключ подписи (base64). Прописывается скриптом tools\New-SigningKey.ps1
$PublicKeyN = "rbl9jYLuJaLgQlnqwmAXeVLdjrP2uG3UrzcPIJtr7pLQf7wT4YJAu8tDPxv+Ou1MVVcCwEzgcgzw4cKol7GzQsEaMhfAlISYDzIGOAM1cXFAtu4kpaRqf1gb7f4qRBvZUvBb2GHnoSgkNoQoMIAwf0N1cNfEQfDC9qi3rDGajC0pJt5LIlQBO4ImQUER8qSDIsdpDki+C4OQ6CCtYumgwRR5OW0jtkBDF4wZMWM4F8+tznoSnAcBRHRQqoFP9omJnctyi1R8DjsBsLOqn9GFbSg8kIZl3djiurAKo78A4qJ+hVioJBeMODKfpe6bcHMzbbfJbc1pS9lrPCrsI76jh8z/3aJkaAtZTQAJm66HwFeLWfUOfXBMhlaBnGw7/QYc55V7U1XuPLoMM+0Ad/hJQWqERN+oozfCK8vaxAFv/B2GgXTe7b5SvlBrzgN9vIEl5qXfmGUlKg8U6dt4ZMvGuMIWVjToTinisU12EG+xoYElvcVcJ0shJssXvD4rVHQF"
$PublicKeyE = "AQAB"

$NamePattern = "^[A-Za-z0-9][A-Za-z0-9._-]*$"
$VersionPattern = "^\d+(\.\d+)*(-[0-9A-Za-z.-]+)?$"

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

function Test-Signature([string]$Name, [string]$Version, [string]$Sha256, [string]$Signature) {
    if (-not $PublicKeyN) { throw "в клиент не прописан открытый ключ (tools\New-SigningKey.ps1)" }
    if (-not $Signature) { return $false }
    # формат должен совпадать с tools\Signing.ps1
    $msg = [Text.Encoding]::UTF8.GetBytes("update-sig-v1`n$Project`n$Version`n$Name`n$($Sha256.ToLower())")
    try { $sig = [Convert]::FromBase64String($Signature) } catch { return $false }
    $p = New-Object Security.Cryptography.RSAParameters
    $p.Modulus = [Convert]::FromBase64String($PublicKeyN)
    $p.Exponent = [Convert]::FromBase64String($PublicKeyE)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.ImportParameters($p)
        return $rsa.VerifyData($msg, "SHA256", $sig)
    } catch {
        return $false
    } finally {
        $rsa.Dispose()
    }
}

# Скачивает файл в $Dest, только если совпали SHA-256 и подпись
function Get-VerifiedFile($A, [string]$Dest, [string]$Version, [string]$UrlPrefix) {
    if ($UrlPrefix -and -not $A.url.StartsWith($UrlPrefix)) { throw "$($A.name): недопустимый адрес $($A.url)" }
    $part = "$Dest.part"
    try {
        if ($UrlPrefix) {
            Invoke-WebRequest -Uri $A.url -OutFile $part -UseBasicParsing -UserAgent "updater"
        } else {
            Copy-Item -LiteralPath $A.url -Destination $part -Force
        }
        $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $A.sha256.ToLower()) { throw "$($A.name): контрольная сумма не совпала" }
        if (-not (Test-Signature $A.name $Version $hash $A.signature)) {
            throw "$($A.name): подпись отсутствует или неверна, файл отклонён"
        }
        Move-Item -LiteralPath $part -Destination $Dest -Force
    } finally {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
}

function Expand-Update([string]$Archive, [string]$Target) {
    $staging = Join-Path $Target ".update-staging"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    # Expand-Archive сам отклоняет пути вида ../ внутри архива
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
    $urlPrefix = $null

    if ($Manifest -match "^https://") {
        # файлы из сетевого манифеста — только из релизов своего репозитория
        $urlPrefix = "https://github.com/$Repo/releases/download/"
        # raw.githubusercontent.com кэширует ~5 минут, параметр обходит кэш
        $sep = if ($Manifest.Contains("?")) { "&" } else { "?" }
        $data = Invoke-RestMethod -Uri "$Manifest${sep}t=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -UseBasicParsing -UserAgent "updater"
    } elseif ($Manifest -match "^http://") {
        throw "манифест только по https"
    } else {
        $data = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $info = $data.projects.$Project
    if (-not $info) { throw "Проекта '$Project' нет в манифесте" }
    $latest = [string]$info.version
    if ($latest -notmatch $VersionPattern) { throw "некорректная версия в манифесте: '$latest'" }

    $statePath = Join-Path $target $StateFile
    $state = if (Test-Path -LiteralPath $statePath) {
        Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { [pscustomobject]@{} }
    $current = $state.$Project.version

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
    foreach ($a in $assets) {
        if ($a.name -notmatch $NamePattern) { throw "недопустимое имя файла: '$($a.name)'" }
    }

    New-Item -ItemType Directory -Force -Path $target | Out-Null
    # сначала скачиваем и проверяем всё, ставим только если проверка прошла у всех файлов
    $tmps = @($assets | ForEach-Object { Join-Path $target (".update-" + $_.name) })
    try {
        for ($i = 0; $i -lt $assets.Count; $i++) {
            Write-Host ("Скачиваю {0} ({1:N1} МБ)" -f $assets[$i].name, ($assets[$i].size / 1MB))
            Get-VerifiedFile $assets[$i] $tmps[$i] $latest $urlPrefix
        }
        for ($i = 0; $i -lt $assets.Count; $i++) {
            if ($assets[$i].name -like "*.zip") {
                Expand-Update $tmps[$i] $target
            } else {
                Move-Item -LiteralPath $tmps[$i] -Destination (Join-Path $target $assets[$i].name) -Force
            }
        }
    } finally {
        foreach ($t in $tmps) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
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
