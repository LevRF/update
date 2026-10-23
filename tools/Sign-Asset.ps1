<#
.SYNOPSIS
  Подписывает файлы для публикации через сайт: рядом с каждым файлом появится <файл>.sig.
  Загрузите в релиз и сами файлы, и .sig. Без подписи клиенты обновление не поставят.

.EXAMPLE
  .\Sign-Asset.ps1 -Project genom -Version 1.2.0 -Files .\build\genom-1.2.0.zip
  # затем релиз с тегом genom-v1.2.0, файлы genom-1.2.0.zip и genom-1.2.0.zip.sig
#>
param(
    [Parameter(Mandatory)] [string]$Project,
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string[]]$Files,
    [string]$KeyPath
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Signing.ps1"
if (-not $KeyPath) { $KeyPath = $DefaultKeyPath }

foreach ($f in $Files) {
    $item = Get-Item -LiteralPath $f
    # GitHub переименовывает файлы с другими символами, и подпись перестала бы совпадать
    if ($item.Name -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$") { throw "Имя файла только из латиницы, цифр, . _ - : $($item.Name)" }
    $sig = New-AssetSignature $KeyPath $Project $Version $item
    Write-Host "Подписано: $($sig.Name)"
}
Write-Host "Тег релиза: $($Project.ToLower())-v$Version"
