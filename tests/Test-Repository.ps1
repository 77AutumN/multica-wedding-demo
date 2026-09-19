param([string]$OutputDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$files = @(& git -C $repo ls-files)
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw 'Tracked source list is unavailable.' }
$forbidden = '(^|/)(runtime|evidence|backups|vendor|tools)(/|$)|(^|/)(connection\.json|state\.initial\.json|\.env(?:\..*)?)$|\.(exe|zip|dump|pem|key)$'
$sensitive = '(?:cli_|ou_|oc_)[A-Za-z0-9]{16,}|S-1-5-21-\d|https://[^\s"<>]+/base/[A-Za-z0-9]{15,}|(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?i)(?:app_secret|client_secret|access_token|refresh_token)\s*["'':= ]+\s*["'']?[A-Za-z0-9_./+\-]{16,}'
foreach ($file in $files) {
    if ($file -match $forbidden) { throw "Forbidden tracked path: $file" }
    $path = Join-Path $repo $file
    $text = [IO.File]::ReadAllText($path)
    if ($text -match $sensitive) { throw "Potential sensitive value in: $file (value omitted)" }
    if ($file.EndsWith('.ps1')) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "PowerShell parse error: $file" }
        $bytes=[IO.File]::ReadAllBytes($path)
        if ($text -match '[\u4e00-\u9fff]' -and -not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) { throw "Chinese PowerShell requires UTF-8 BOM: $file" }
    }
    if ($file.EndsWith('.json')) { [void](ConvertFrom-Json -InputObject $text) }
}
$example = Get-Content (Join-Path $repo 'examples/connection.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($example.ready -or $example.writes_enabled -or $example.base_token -or $example.orders_table_id) { throw 'Example configuration must remain disconnected and read-only.' }
$empty = Get-Content (Join-Path $repo 'examples/state.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($empty.active -or $empty.current -or @($empty.history).Count -or @($empty.reserved_codes).Count -or @($empty.used_codes).Count) { throw 'State example contains live history.' }
Write-Output "Source boundaries, syntax and examples passed ($($files.Count) tracked files)."
& "$PSScriptRoot\Test-WeddingDemo.ps1" -OutputDirectory $OutputDirectory
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Offline test process failed.' }
