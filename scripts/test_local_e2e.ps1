$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$exitCode = 1

try {
    if ($args.Count -ne 0) { throw 'This runner accepts no arguments; its four modes are fixed.' }
    . (Join-Path $PSScriptRoot 'local_environment.ps1')
    $benchmark = Join-Path $RepoRoot 'benchmark\benchmark_qwen.ps1'
    Assert-LocalPath $benchmark
    if (-not (Test-Path -LiteralPath $benchmark -PathType Leaf)) { throw "Benchmark script is missing: $benchmark" }
    $logRoot = Join-Path $RepoRoot ('.localai\logs\e2e-' + [Guid]::NewGuid().ToString('N'))
    Assert-LocalTree $logRoot
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    Write-Host "E2E_LOG_ROOT=$logRoot"
    $modes = [ordered]@{
        PreflightOnly = 'BENCHMARK_PREFLIGHT=PASS'
        AgenticHarnessSelfTest = 'AGENTIC_HARNESS_SELFTEST=PASS'
        ReasoningGrowthSelfTest = 'REASONING_GROWTH_SELFTEST=PASS'
        OrchestrationEnduranceSelfTest = 'ORCHESTRATION_ENDURANCE_SELFTEST=PASS'
    }
    foreach ($mode in $modes.GetEnumerator()) {
        $stdout = Join-Path $logRoot ($mode.Key + '.stdout.log')
        $stderr = Join-Path $logRoot ($mode.Key + '.stderr.log')
        Assert-LocalPath $stdout
        Assert-LocalPath $stderr
        Write-Host "E2E_MODE=$($mode.Key)"
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
            ('"' + $benchmark + '"'), ('-' + $mode.Key)
        ) -WorkingDirectory (Get-Location).Path -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $process.Refresh()
        if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) {
            if ($null -ne $process.ExitCode) { $exitCode = $process.ExitCode }
            throw "Mode $($mode.Key) failed with exit $exitCode. Logs: $stdout and $stderr"
        }
        Assert-LocalPath $stdout
        Assert-LocalPath $stderr
        $outLines = @([regex]::Split([IO.File]::ReadAllText($stdout), '\r?\n'))
        $allLines = $outLines + @([regex]::Split([IO.File]::ReadAllText($stderr), '\r?\n'))
        $key = $mode.Value.Split('=')[0]
        $results = @($allLines | Where-Object { $_ -match ([regex]::Escape($key) + '\s*=') })
        $failures = @($allLines | Where-Object { $_ -match '^[A-Z][A-Z0-9_]*\s*=\s*(FAIL|FAILED)($|[\s:])' })
        if (@($outLines | Where-Object { $_ -ceq $mode.Value }).Count -ne 1 -or $results.Count -ne 1 -or $failures.Count -ne 0) {
            throw "Mode $($mode.Key) did not produce one unambiguous success marker. Logs: $stdout and $stderr"
        }
        Write-Host "E2E_MODE_RESULT=$($mode.Key):PASS"
    }
    Write-Host 'AUTOMATED_E2E_SELFTESTS=PASS'
    exit 0
}
catch {
    Write-Host 'AUTOMATED_E2E_SELFTESTS=FAIL'
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit $exitCode
}
finally {
    $snapshot = Get-Variable -Name LocalAiOriginalEnvironment -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $snapshot -and $null -ne $snapshot.Value -and (Get-Command Restore-LocalEnvironment -ErrorAction SilentlyContinue)) {
        Restore-LocalEnvironment
    }
}
