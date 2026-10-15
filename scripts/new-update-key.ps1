# Create the RSA-3072 key that signs update-manifest.json (installed app updates, 2.5.0). The private key is written
# DPAPI-protected for the current Windows user to -PrivateKeyPath, which must be outside the repository; only the public
# key goes into the package (package-template/app/update-key.xml by default). An existing private key is never replaced.
param([Parameter(Mandatory=$true)][string]$PrivateKeyPath,[string]$PublicKeyPath='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
if(!$PublicKeyPath){$PublicKeyPath=Join-Path $repo 'package-template\app\update-key.xml'}
$private=[IO.Path]::GetFullPath($PrivateKeyPath)
if($private.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The private key must be stored outside the repository.'}
if(Test-Path -LiteralPath $private){throw "Private key already exists, not replaced: $private"}
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(3072);$rsa.PersistKeyInCsp=$false
try{
 $plain=[Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
 try{$protected=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)}finally{[Array]::Clear($plain,0,$plain.Length)}
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($private))
 [IO.File]::WriteAllBytes($private,$protected)
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($PublicKeyPath),$rsa.ToXmlString($false),(New-Object Text.UTF8Encoding($false)))
}finally{$rsa.Dispose()}
Write-Host "Private key (DPAPI, current user): $private"
Write-Host "Public key: $PublicKeyPath"
