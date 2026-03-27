# Pester tests for install-ca-cert.ps1 on Windows runners
#
# Read-Host reads from the console host, not stdin, so each test builds a
# temp script with a queue-backed Read-Host mock prepended and runs it as
# a child pwsh process.

BeforeAll {
    $RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ScriptPath = Join-Path $RepoRoot 'install-ca-cert.ps1'

    $rawTimeout = if ($env:CMD_TIMEOUT_SECS) { $env:CMD_TIMEOUT_SECS } else { '10' }
    $script:CmdTimeoutMs = [int]($rawTimeout -replace 's$', '') * 1000

    # Generate test certificates via the dedicated script (cert gen is not inline here)
    $script:TmpCertDir = Join-Path ([IO.Path]::GetTempPath()) "test-certs-$([guid]::NewGuid().ToString('N'))"
    & (Join-Path $PSScriptRoot 'generate-certs.ps1') -OutputDir $script:TmpCertDir
    $script:CertFile      = Join-Path $script:TmpCertDir 'test-ca.crt'
    $script:HttpsCaFile   = Join-Path $script:TmpCertDir 'https-ca.crt'
    $script:HttpsServerCrt = Join-Path $script:TmpCertDir 'https-server.crt'
    $script:HttpsServerKey = Join-Path $script:TmpCertDir 'https-server.key'

    # Strip #Requires and param() block (both are invalid when the script is inlined)
    $script:RawScript = (Get-Content $ScriptPath -Raw) `
        -replace '(?m)^#Requires[^\r\n]*[\r\n]+', '' `
        -replace '(?ms)^param\s*\(.*?\)\s*[\r\n]+', ''

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
`$CASource = ''
`$Force = `$false
$($script:RawScript)
"@
        $psi = [Diagnostics.ProcessStartInfo]@{
            FileName = 'pwsh'; Arguments = "-File `"$tmp`""
            RedirectStandardOutput = $true; RedirectStandardError = $true
            UseShellExecute = $false
        }
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        $finished = $p.WaitForExit($script:CmdTimeoutMs)
        if (-not $finished) {
            $p.Kill()
            $p.WaitForExit()
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return [PSCustomObject]@{ ExitCode = 124; Output = 'Command timed out' }
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = $out.Trim() }
    }
}

AfterAll {
    if ($script:TmpCertDir -and (Test-Path $script:TmpCertDir)) {
        Remove-Item $script:TmpCertDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'install-ca-cert.ps1 (Windows)' {

    It 'empty input exits with error' {
        $r = Invoke-WithInput @('')
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'No CA source provided'
    }

    It 'local cert file: installs and verifies' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            $r = Invoke-WithInput @($script:CertFile, 'y', 'n')
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'CA Name\s+:\s+Test CA'
            $r.Output   | Should -Match 'System trust: OK'
        }
        finally {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
            $store.Open('ReadWrite')
            $store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint | ForEach-Object { $store.Remove($_) }
            $store.Close()
        }
    }

    It 'already installed cert exits cleanly' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
        $store.Open('ReadWrite')
        $store.Add($cert)
        $store.Close()
        try {
            $r = Invoke-WithInput @($script:CertFile)
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'Already up-to-date'
        }
        finally {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
            $store.Open('ReadWrite')
            $store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint | ForEach-Object { $store.Remove($_) }
            $store.Close()
        }
    }

    # TODO: add headless TLS verification tests for browsers on Windows:
    #   - Chrome    — uses Windows cert store; should trust CA after system install
    #   - Edge      — uses Windows cert store; should trust CA after system install
    #   - Firefox   — uses its own NSS profile store; requires profile setup like Linux tests
    #   - Brave     — uses Windows cert store; should trust CA after system install
    #   - Chromium  — uses Windows cert store; should trust CA after system install

    It 'Chrome headless loads HTTPS page after trust install' {
        # TODO: implement — Chrome uses the Windows cert store, so trust is implicit after
        # system install. Spawn: chrome --headless=new --no-sandbox --dump-dom https://...
        Set-ItResult -Skipped -Because 'not yet implemented'
    }

    It 'Microsoft Edge headless loads HTTPS page after trust install' {
        # TODO: implement — Edge uses the Windows cert store, so trust is implicit after
        # system install. Spawn: msedge --headless=new --no-sandbox --dump-dom https://...
        Set-ItResult -Skipped -Because 'not yet implemented'
    }

    It 'Firefox headless loads HTTPS page after trust install' {
        # TODO: implement — Firefox uses its own NSS profile store on Windows.
        # Requires profile directory setup similar to the Linux $FIREFOX_DEB_NSS_DIR tests,
        # then: firefox --headless --no-remote --profile <dir> --screenshot ... https://...
        Set-ItResult -Skipped -Because 'not yet implemented'
    }

    It 'Brave headless loads HTTPS page after trust install' {
        # TODO: implement — Brave uses the Windows cert store, so trust is implicit after
        # system install. Spawn: brave --headless=new --no-sandbox --dump-dom https://...
        Set-ItResult -Skipped -Because 'not yet implemented'
    }

    It 'HTTPS URL trusts system CA after install' {
        if (-not (Test-Path $script:HttpsCaFile)) {
            Set-ItResult -Skipped -Because 'openssl not available — HTTPS certs not generated'
            return
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()

        $job = Start-Job {
            param($crt, $key, $port)
            & openssl s_server -quiet -accept $port -cert $crt -key $key -www 2>$null
        } -ArgumentList $script:HttpsServerCrt, $script:HttpsServerKey, $port

        $installed = $false
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 5) {
                try {
                    $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
                    $tcp.Close()
                    break
                } catch {
                    Start-Sleep -Milliseconds 100
                }
            }
            $sw.Stop()

            $r = Invoke-WithInput @($script:HttpsCaFile, 'y', 'y')
            $r.ExitCode | Should -Be 0
            $installed = $true

            $psi = [Diagnostics.ProcessStartInfo]@{
                FileName = 'pwsh'
                Arguments = "-NoProfile -NonInteractive -Command `"Invoke-WebRequest https://127.0.0.1:$port/ -UseBasicParsing | Out-Null`""
                RedirectStandardOutput = $true; RedirectStandardError = $true
                UseShellExecute = $false
            }
            $p = [Diagnostics.Process]::Start($psi)
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            $stderrTask = $p.StandardError.ReadToEndAsync()
            $fin = $p.WaitForExit($script:CmdTimeoutMs)
            [void]$stdoutTask.Result; [void]$stderrTask.Result
            if (-not $fin) { $p.Kill(); $p.WaitForExit() }
            $p.ExitCode | Should -Be 0
        }
        finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            if ($installed) {
                $thumb = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $script:HttpsCaFile).Thumbprint
                $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
                $store.Open('ReadWrite')
                $store.Certificates | Where-Object Thumbprint -eq $thumb | ForEach-Object { $store.Remove($_) }
                $store.Close()
            }
        }
    }
}
