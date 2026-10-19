# settle.ps1: the Windows side's boot settling for the cross-OS comparison (profiler/windows/cross-os-trial.sh), the
# counterpart of the Linux runs' (120 s, then until the 1-minute load is below 1.0). Waits for the user's desktop
# session (auto-logon; Live needs it), then 120 s, then until total CPU is below 10 % in a 5 s sample, at most 600 s.
$t0 = Get-Date
while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and ((Get-Date) - $t0).TotalSeconds -lt 600) { Start-Sleep 5 }
"desktop session: $([bool](Get-Process explorer -ErrorAction SilentlyContinue)) after $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
Start-Sleep 120
$t1 = Get-Date
do {
  $c = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 5 -MaxSamples 1).CounterSamples[0].CookedValue
} while ($c -ge 10 -and ((Get-Date) - $t1).TotalSeconds -lt 480)
"settled: cpu $([math]::Round($c, 1)) % after $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
