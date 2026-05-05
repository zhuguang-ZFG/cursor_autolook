# Cursor Autolook — core loader (implementation split under lib/domains by functional area).
# $Root / runtime globals are initialized by caller (cursor-autolook.ps1) before dot-sourcing.

$coreDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$domainsDir = Join-Path $coreDir "domains"
if (-not (Test-Path -LiteralPath $domainsDir)) {
    throw "Missing domain modules directory: $domainsDir"
}
foreach ($script in @(Get-ChildItem -LiteralPath $domainsDir -Filter "*.ps1" | Sort-Object Name)) {
    . $script.FullName
}
