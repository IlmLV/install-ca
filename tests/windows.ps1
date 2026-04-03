# Pester tests for install-ca.ps1 on Windows runners
#
# Each test invokes install-ca.ps1 directly as a child PowerShell process,
# passing -Url / -Yes / -Force as named parameters — the same pattern
# used by the bash tests (e.g. "bash install-ca.sh -y $CERT").

BeforeAll {
    # Elevation check — LocalMachine\Root writes require Administrator privileges.
    $currentIdentity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "These tests modify LocalMachine\Root and must be run from an elevated (Administrator) PowerShell session."
    }

    $RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ScriptPath = Join-Path $RepoRoot 'install-ca.ps1'
    $script:PowerShellExe = (Get-Process -Id $PID).Path
    if (-not $script:PowerShellExe) {
        $script:PowerShellExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    }

    $rawTimeout = if ($env:CMD_TIMEOUT_SECS) { $env:CMD_TIMEOUT_SECS } else { '10' }
    $script:CmdTimeoutMs = [int]($rawTimeout -replace 's$', '') * 1000

    # Generate test certificates via the dedicated script (cert gen is not inline here)
    $script:TmpCertDir = Join-Path ([IO.Path]::GetTempPath()) "test-certs-$([guid]::NewGuid().ToString('N'))"
    & (Join-Path $PSScriptRoot 'generate-certs.ps1') -OutputDir $script:TmpCertDir
    $script:CertFile       = Join-Path $script:TmpCertDir 'test-ca.crt'
    $script:LeafCertFile   = Join-Path $script:TmpCertDir 'leaf.crt'
    $script:HttpsCaFile    = Join-Path $script:TmpCertDir 'https-ca.crt'
    $script:HttpsServerCrt = Join-Path $script:TmpCertDir 'https-server.crt'
    $script:HttpsServerKey = Join-Path $script:TmpCertDir 'https-server.key'

    # Invoke install-ca.ps1 directly with named parameters — same pattern as bash tests.
    # Stdin is redirected and closed immediately so any Read-Host call gets EOF → returns null,
    # which the script treats as "no input" and exits with error.  Both stdout and stderr are
    # read asynchronously to avoid the deadlock that sequential ReadToEnd() can cause when the
    # child process fills one pipe while we are blocked draining the other.
    function Join-ProcessArguments {
        param([string[]]$Argument)

        $quoted = foreach ($item in $Argument) {
            if ($null -eq $item) {
                '""'
            } elseif ($item -match '[\s"]') {
                '"' + ($item -replace '"', '\"') + '"'
            } else {
                $item
            }
        }

        return ($quoted -join ' ')
    }

    function global:Add-CertToStore([Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
        $store.Open('ReadWrite')
        $store.Add($Cert)
        $store.Close()
    }

    function global:Remove-CertFromStore([Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
        $store.Open('ReadWrite')
        $store.Certificates | Where-Object Thumbprint -eq $Cert.Thumbprint | ForEach-Object { $store.Remove($_) }
        $store.Close()
    }

    # Simulate: irm <url> | iex; Install [args]
    # Invoke-Expression on the local script file mirrors what iex does when piped.
    function global:Invoke-Oneliner {
        param(
            [string]$Url   = '',
            [switch]$Force,
            [switch]$Yes
        )

        $escapedPath  = $ScriptPath -replace "'", "''"
        $installParts = [Collections.Generic.List[string]]::new()
        $installParts.Add('Install')
        if ($Url)   { $installParts.Add("-Url '$($Url -replace "'","''")'") }
        if ($Force) { $installParts.Add('-Force') }
        if ($Yes)   { $installParts.Add('-Yes') }
        $installCall = $installParts -join ' '

        $command = "Invoke-Expression (Get-Content '$escapedPath' -Raw); $installCall"
        $argList  = @('-NoProfile', '-NonInteractive', '-Command', $command)

        $psi = [Diagnostics.ProcessStartInfo]@{
            FileName               = $script:PowerShellExe
            RedirectStandardInput  = $true
            RedirectStandardOutput = $true
            RedirectStandardError  = $true
            UseShellExecute        = $false
        }
        $psi.Arguments = Join-ProcessArguments -Argument $argList
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        $finished   = $p.WaitForExit($script:CmdTimeoutMs)
        if (-not $finished) {
            try { if (-not $p.HasExited) { $p.Kill() } } catch { }
            try { $null = $p.WaitForExit([Math]::Min($script:CmdTimeoutMs, 2000)) } catch { }
        }
        if ($finished) {
            $out = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
            return [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = $out.Trim() }
        }
        return [PSCustomObject]@{ ExitCode = 124; Output = 'Command timed out' }
    }

    function global:Invoke-Script {
        param(
            [string]$Url = '',
            [switch]$Force,
            [switch]$Yes
        )

        $argList = [Collections.Generic.List[string]]::new()
        $argList.Add('-NoProfile')
        $argList.Add('-NonInteractive')
        $argList.Add('-File')
        $argList.Add($ScriptPath)
        if ($Url)      { $argList.Add('-Url'); $argList.Add($Url) }
        if ($Force)    { $argList.Add('-Force') }
        if ($Yes)      { $argList.Add('-Yes') }

        $psi = [Diagnostics.ProcessStartInfo]@{
            FileName               = $script:PowerShellExe
            RedirectStandardInput  = $true
            RedirectStandardOutput = $true
            RedirectStandardError  = $true
            UseShellExecute        = $false
        }
        $psi.Arguments = Join-ProcessArguments -Argument $argList.ToArray()
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
                # Use a bounded wait after attempting to kill the process to avoid blocking indefinitely
                $null = $p.WaitForExit([Math]::Min($script:CmdTimeoutMs, 2000))
            } catch {
                # Ignore failures from WaitForExit() after attempting to kill the process
            }
        }
        # Collect output; use GetAwaiter().GetResult() so individual task exceptions surface cleanly
        if ($finished) {
            $out = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
            return [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = $out.Trim() }
        }
        # On timeout, do not wait on the read tasks to avoid hanging if the process is still running
        return [PSCustomObject]@{ ExitCode = 124; Output = 'Command timed out' }
    }
}

AfterAll {
    if ($script:TmpCertDir -and (Test-Path $script:TmpCertDir)) {
        Remove-Item $script:TmpCertDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'install-ca.ps1 (Windows)' {

    It 'empty input exits with error' {
        $r = Invoke-Script
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'No CA source provided'
    }

    It 'non-CA leaf cert is rejected with exit code 1' {
        $r = Invoke-Script -Url $script:LeafCertFile -Yes
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'not a CA certificate|BasicConstraints'
    }

    It 'local cert file: installs and verifies' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            $r = Invoke-Script -Url $script:CertFile -Yes
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'CA Name\s+:\s+Test CA'
            $r.Output   | Should -Match 'System trust: OK'
        }
        finally {
            Remove-CertFromStore $cert
        }
    }

    It 'already installed cert exits cleanly' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        Add-CertToStore $cert
        try {
            $r = Invoke-Script -Url $script:CertFile
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'Already up-to-date'
        }
        finally {
            Remove-CertFromStore $cert
        }
    }

    It '-Force: already installed cert continues and reinstalls' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            Add-CertToStore $cert
            $r = Invoke-Script -Url $script:CertFile -Yes -Force
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match '-Force was specified, continuing'
            $r.Output   | Should -Match 'System trust: OK'
        }
        finally {
            Remove-CertFromStore $cert
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

    # ── Oneliner (irm | iex) syntax ───────────────────────────────────────────────
    #
    # Simulates: irm <url> | iex; Install '<cert>' [-Yes] [-Force]
    # Invoke-Expression on the local script file mirrors what iex does when piped.

    It 'oneliner: Install with cert path installs cert' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            $r = Invoke-Oneliner -Url $script:CertFile -Yes
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'CA Name\s+:\s+Test CA'
            $r.Output   | Should -Match 'System trust: OK'
        } finally {
            Remove-CertFromStore $cert
        }
    }

    It 'oneliner: Install with no args fails with error' {
        $r = Invoke-Oneliner
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'No CA source provided'
    }

    It 'oneliner: Install -Force reinstalls already-present cert' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            Add-CertToStore $cert
            $r = Invoke-Oneliner -Url $script:CertFile -Yes -Force
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match '-Force was specified, continuing'
            $r.Output   | Should -Match 'System trust: OK'
        } finally {
            Remove-CertFromStore $cert
        }
    }

    It 'oneliner: Install skips already-installed cert' {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CertFile)
        try {
            Add-CertToStore $cert
            $r = Invoke-Oneliner -Url $script:CertFile
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'Already up-to-date'
        } finally {
            Remove-CertFromStore $cert
        }
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
            FileName              = 'openssl'
            UseShellExecute       = $false
            # Redirect stdin so openssl does not inherit a closed pipe from the CI runner.
            # openssl s_server monitors stdin in its select() loop and exits on EOF; keeping
            # the pipe open (but empty) prevents it from dying during the cert-install step.
            RedirectStandardInput = $true
        }
        $opensslArgs = @(
            's_server'
            '-quiet'
            '-accept'
            $port.ToString()
            '-cert'
            $script:HttpsServerCrt
            '-key'
            $script:HttpsServerKey
            '-www'
        )
        $opensslPsi.Arguments = Join-ProcessArguments -Argument $opensslArgs
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

            $r = Invoke-Script -Url $script:HttpsCaFile -Yes
            $r.ExitCode | Should -Be 0
            $installed = $true

            # Verify the server is still alive after the cert install step; if it exited
            # (e.g., stdin EOF on CI), fail with a clear message rather than a TLS error.
            if ($opensslProc.HasExited) {
                throw "openssl s_server exited unexpectedly (exit code $($opensslProc.ExitCode)) before the HTTPS trust check could run."
            }

            $psi = [Diagnostics.ProcessStartInfo]@{
                FileName               = $script:PowerShellExe
                RedirectStandardOutput = $true
                RedirectStandardError  = $true
                UseShellExecute        = $false
            }
            $childArgs = @(
                '-NoProfile'
                '-NonInteractive'
                '-Command'
                "Invoke-WebRequest https://127.0.0.1:$port/ -UseBasicParsing | Out-Null"
            )
            $psi.Arguments = Join-ProcessArguments -Argument $childArgs
            $p = [Diagnostics.Process]::Start($psi)
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            $stderrTask = $p.StandardError.ReadToEndAsync()
            $fin = $p.WaitForExit($script:CmdTimeoutMs)
            if (-not $fin) {
                try { $p.Kill() } catch { }
                $finAfterKill = $p.WaitForExit($script:CmdTimeoutMs)
                if (-not $finAfterKill) {
                    throw "Child PowerShell process for HTTPS Invoke-WebRequest did not exit within $($script:CmdTimeoutMs) ms even after Kill(); aborting test to avoid hang."
                }
            }
            [void]$stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $p.ExitCode | Should -Be 0 -Because "Invoke-WebRequest stderr: $($stderr.Trim())"
        }
        finally {
            if ($null -ne $opensslProc -and -not $opensslProc.HasExited) {
                try { $opensslProc.Kill(); $opensslProc.WaitForExit() } catch { }
            }
            if ($installed) {
                $httpsCaCert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:HttpsCaFile)
                try { Remove-CertFromStore $httpsCaCert } finally { $httpsCaCert.Dispose() }
            }
        }
    }
}
