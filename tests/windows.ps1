# Pester tests for install-ca-cert.ps1 on Windows runners
#
# Read-Host reads from the console host, not stdin, so each test builds a
# temp script with a queue-backed Read-Host mock prepended and runs it as
# a child pwsh process.

BeforeAll {
    $RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $ScriptPath = Join-Path $RepoRoot 'install-ca-cert.ps1'
    $script:CertFile = Join-Path $RepoRoot 'tests\fixtures\test-ca.crt'

    # Strip #Requires (unsupported when inlined) — done once for all tests
    $script:RawScript = (Get-Content $ScriptPath -Raw) `
        -replace '(?m)^#Requires[^\r\n]*[\r\n]+', ''

    function global:Invoke-WithInput([string[]]$Inputs) {
        $inputsJson = $Inputs | ConvertTo-Json -Compress

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("{0}.ps1" -f [IO.Path]::GetRandomFileName())
        Set-Content $tmp @"
`$global:_Q = [Collections.Generic.Queue[string]]::new()
`$inputsJson = @'
$inputsJson
'@
`$inputs = `$inputsJson | ConvertFrom-Json
if (`$inputs -is [string]) {
    `$global:_Q.Enqueue(`$inputs)
} else {
    foreach (`$i in `$inputs) {
        `$global:_Q.Enqueue([string]`$i)
    }
}
function global:Read-Host { param([string]`$Prompt)
    if (`$global:_Q.Count -gt 0) { return `$global:_Q.Dequeue() }
    return '' }
$($script:RawScript)
"@
        $psi = [Diagnostics.ProcessStartInfo]@{
            FileName = 'pwsh'; Arguments = "-File `"$tmp`""
            RedirectStandardOutput = $true; RedirectStandardError = $true
            UseShellExecute = $false
        }
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = $out.Trim() }
    }
}

Describe 'install-ca-cert.ps1 (Windows)' {

    It 'empty input exits with error' {
        $r = Invoke-WithInput @('')
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'No CA source provided'
    }

    It 'local cert file: loads, extracts CN, exits cleanly' {
        $r = Invoke-WithInput @($script:CertFile)
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'CA Name\s+:\s+Test CA'
    }

    It 'HTTP URL: fetches cert over plain HTTP' {
        $fixtures = Join-Path $RepoRoot 'tests\fixtures'
        $job = Start-Job {
            param($dir)
            python -m http.server 8081 --bind 127.0.0.1 --directory $dir
        } -ArgumentList $fixtures
        Start-Sleep -Milliseconds 800

        $r = Invoke-WithInput @('http://127.0.0.1:8081/test-ca.crt')
        Stop-Job $job -Force; Remove-Job $job -Force
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'CA Name\s+:\s+Test CA'
    }
}
