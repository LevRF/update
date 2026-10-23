<#
.SYNOPSIS
  Создаёт ключ подписи обновлений (RSA-3072) и прописывает открытую часть в клиенты.

  Закрытый ключ сохраняется вне репозитория (по умолчанию %USERPROFILE%\.update-signing\private-key.xml).
  Сделайте его резервную копию (флешка, менеджер паролей) и никому не передавайте:
  кто владеет этим файлом, тот может выпускать обновления для всех ваших программ.
  Если ключ потерян, придётся создать новый и заново раздать клиенты с новым открытым ключом.
#>
param(
    [string]$KeyPath,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Signing.ps1"
if (-not $KeyPath) { $KeyPath = $DefaultKeyPath }

if ((Test-Path -LiteralPath $KeyPath) -and -not $Force) {
    throw "Ключ уже существует: $KeyPath. Новый ключ сделает старые клиенты несовместимыми; если это осознанно, добавьте -Force"
}

$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
try {
    $rsa.PersistKeyInCsp = $false
    $private = $rsa.ToXmlString($true)
    $pub = $rsa.ExportParameters($false)
} finally {
    $rsa.Dispose()
}

New-Item -ItemType Directory -Force -Path (Split-Path $KeyPath) | Out-Null
[IO.File]::WriteAllText($KeyPath, $private, (New-Object Text.UTF8Encoding $false))

$n = [Convert]::ToBase64String($pub.Modulus)
$e = [Convert]::ToBase64String($pub.Exponent)
$root = Split-Path $PSScriptRoot
foreach ($f in @("client\updater.py", "client\Update-App.ps1")) {
    $path = Join-Path $root $f
    $text = [IO.File]::ReadAllText($path)
    $text = $text -replace '(?m)^(\s*\$?(?:PUBLIC_KEY_N|PublicKeyN)\s*=\s*)"[^"]*"', "`${1}`"$n`""
    $text = $text -replace '(?m)^(\s*\$?(?:PUBLIC_KEY_E|PublicKeyE)\s*=\s*)"[^"]*"', "`${1}`"$e`""
    $bom = $f.EndsWith(".ps1")
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $bom))
}

$fp = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash($pub.Modulus)).Replace("-", "").Substring(0, 16)
Write-Host "Ключ создан: $KeyPath"
Write-Host "Отпечаток открытого ключа: $fp"
Write-Host "Открытый ключ прописан в client\updater.py и client\Update-App.ps1 — закоммитьте их."
Write-Host "Сделайте резервную копию закрытого ключа!" -ForegroundColor Yellow
