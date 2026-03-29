# Pester tests for install-ca-cert.ps1 on Windows runners
#
# Each test invokes install-ca-cert.ps1 directly as a child pwsh process,
# passing -CASource / -Yes / -Force as named parameters — the same pattern
# used by the bash tests (e.g. "bash install-ca-cert.sh -y $CERT").

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

    # Invoke install-ca-cert.ps1 directly with named parameters — same pattern as bash tests.
    # Stdin is redirected and closed immediately so any Read-Host call gets EOF → returns null,
    # which the script treats as "no input" and exits with error.  Both stdout and stderr are
    # read asynchronously to avoid the deadlock that sequential ReadToEnd() can cause when the
    # child process fills one pipe while we are blocked draining the other.
    function global:Invoke-Script {
        param(
            [string]$CASource = '',
            [switch]$Force,
            [switch]$Yes
        )

        $argList = [Collections.Generic.List[string]]::new()
        $argList.Add('-NoProfile')
        $argList.Add('-NonInteractive')
        $argList.Add('-File')
        $argList.Add($ScriptPath)
        if ($CASource) { $argList.Add('-CASource'); $argList.Add($CASource) }
        if ($Force)    { $argList.Add('-Force') }
        if ($Yes)      { $argList.Add('-Yes') }

        $psi = [Diagnostics.ProcessStartInfo]@{
            FileName               = 'pwsh'
            RedirectStandardInput  = $true
            RedirectStandardOutput = $true
            RedirectStandardError  = $true
            UseShellExecute        = $false
        }
        foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
        $p = [Diagnostics.Process]::Start($psi)
        # Always close stdin immediately so any Read-Host call receives EOF and returns null
        $p.StandardInput.Close()
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        $finished = $p.WaitForExit($script:CmdTimeoutMs)
        if (-not $finished) {
            try {
                if (-not $p.HasExited) {
                    $p.Kill()
                }
            } catch {
                # Ignore failures from Kill() in the timeout path (process may have already exited)
            }
            try {
                $p.WaitForExit()
            } catch {
                # Ignore failures from WaitForExit() after attempting to kill the process
            }
        }
        # Collect output; use GetAwaiter().GetResult() so individual task exceptions surface cleanly
        $out = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
        if (-not $finished) {
            return [PSCustomObject]@{ ExitCode = 124; Output = 'Command timed out' }
        }
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
        $r = Invoke-Script
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'No CA source provided'
    }

    It 'local cert file: installs and verifies' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            $r = Invoke-Script -CASource $script:CertFile -Yes
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
            $r = Invoke-Script -CASource $script:CertFile
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

    It '-Force: already installed cert continues and reinstalls' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
            $store.Open('ReadWrite')
            $store.Add($cert)
            $store.Close()
            $r = Invoke-Script -CASource $script:CertFile -Yes -Force
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match '-Force was specified, continuing'
            $r.Output   | Should -Match 'System trust: OK'
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

        $opensslPsi = [Diagnostics.ProcessStartInfo]@{
            FileName               = 'openssl'
            RedirectStandardOutput = $true
            RedirectStandardError  = $true
            UseShellExecute        = $false
        }
        $opensslPsi.ArgumentList.Add('s_server')
        $opensslPsi.ArgumentList.Add('-quiet')
        $opensslPsi.ArgumentList.Add('-accept')
        $opensslPsi.ArgumentList.Add($port.ToString())
        $opensslPsi.ArgumentList.Add('-cert')
        $opensslPsi.ArgumentList.Add($script:HttpsServerCrt)
        $opensslPsi.ArgumentList.Add('-key')
        $opensslPsi.ArgumentList.Add($script:HttpsServerKey)
        $opensslPsi.ArgumentList.Add('-www')
        $opensslProc = [Diagnostics.Process]::Start($opensslPsi)

        $installed = $false
        try {
            $serverReady = $false
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 5) {
                try {
                    $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
                    $tcp.Close()
                    $serverReady = $true
                    break
                } catch {
                    Start-Sleep -Milliseconds 100
                }
            }
            $sw.Stop()
            if (-not $serverReady) {
                throw "HTTPS test server on port $port was not reachable within $([math]::Round($sw.Elapsed.TotalSeconds, 2)) seconds; aborting test before Invoke-WebRequest."
            }

            $r = Invoke-Script -CASource $script:HttpsCaFile -Yes
            $r.ExitCode | Should -Be 0
            $installed = $true

            $psi = [Diagnostics.ProcessStartInfo]@{
                FileName = 'pwsh'
                Arguments = "-NoProfile -NonInteractive -Command `"Invoke-WebRequest https://127.0.0.1:$port/ | Out-Null`""
                RedirectStandardOutput = $true; RedirectStandardError = $true
                UseShellExecute = $false
            }
            $p = [Diagnostics.Process]::Start($psi)
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            $stderrTask = $p.StandardError.ReadToEndAsync()
            $fin = $p.WaitForExit($script:CmdTimeoutMs)
            if (-not $fin) {
                try { $p.Kill() } catch { }
                $p.WaitForExit()
            }
            [void]$stdoutTask.GetAwaiter().GetResult()
            [void]$stderrTask.GetAwaiter().GetResult()
            $p.ExitCode | Should -Be 0
        }
        finally {
            if ($null -ne $opensslProc -and -not $opensslProc.HasExited) {
                try { $opensslProc.Kill(); $opensslProc.WaitForExit() } catch { }
            }
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
