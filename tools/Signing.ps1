# Общие функции подписи. Подключается через точку: . "$PSScriptRoot\Signing.ps1"
#
# Подписывается не сам файл, а строка с проектом, версией, именем и SHA-256 файла,
# чтобы подписанный файл нельзя было выдать за другую версию или другой проект.
# Формат должен совпадать с client/updater.py и client/Update-App.ps1.

$DefaultKeyPath = Join-Path $env:USERPROFILE ".update-signing\private-key.xml"

function Get-SignedMessage([string]$Project, [string]$Version, [string]$Name, [string]$Sha256) {
    $text = "update-sig-v1`n$($Project.ToLower())`n$Version`n$Name`n$($Sha256.ToLower())"
    [Text.Encoding]::UTF8.GetBytes($text)
}

function New-AssetSignature([string]$KeyPath, [string]$Project, [string]$Version, [IO.FileInfo]$File) {
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        throw "Нет ключа подписи: $KeyPath. Создайте его: tools\New-SigningKey.ps1"
    }
    $sha = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString([IO.File]::ReadAllText($KeyPath))
        $sig = $rsa.SignData((Get-SignedMessage $Project $Version $File.Name $sha), "SHA256")
    } finally {
        $rsa.Dispose()
    }
    $sigPath = "$($File.FullName).sig"
    [IO.File]::WriteAllText($sigPath, [Convert]::ToBase64String($sig), (New-Object Text.UTF8Encoding $false))
    Get-Item -LiteralPath $sigPath
}
