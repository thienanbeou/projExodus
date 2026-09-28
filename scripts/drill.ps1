# drill.ps1: time how long the node1 stack takes to come back after an outage.
#   .\drill.ps1 auto -Trials 10   unattended simulated outage: poweroff node1, reboot the R3P, time the WoL recovery, repeat
#   .\drill.ps1 manual            real power cut: press Enter the moment power returns
# Before running: laptop on the Viettel router, Tailscale running with `tailscale set --accept-dns=false`.
# Every check targets a Tailscale IP, so the Windows resolver and its cache are never involved.
param(
    [ValidateSet('auto', 'manual')][string]$Mode = 'auto',
    [int]$Trials = 10,
    [int]$Timeout = 900,   # seconds before a trial counts as not recovered
    [int]$Settle = 120     # auto: seconds to leave the stack alone between trials
)

$Key      = "$env:USERPROFILE\.ssh\drill"
$Node1    = '100.109.121.103'
$Node1Lan = '192.168.2.149'
$R3P      = '100.96.106.9'
$Ts       = 'smelt-macaroni.ts.net'
$File     = "drill-$Mode.csv"

# name = exe, arguments. tsdproxy names are pinned to their IP with --resolve, so TLS still validates.
$c = '-s -o NUL -w %{http_code} --connect-timeout 3 --max-time 8'
$checks = [ordered]@{
    host    = 'curl.exe', "$c -k https://${Node1}:8006/"
    dns     = 'nslookup.exe', '-timeout=2 -retry=1 example.com. 100.72.51.17'
    vault   = 'curl.exe', "$c --resolve vaultwarden.${Ts}:443:100.67.11.120 https://vaultwarden.$Ts/alive"
    cloud   = 'curl.exe', "$c --resolve cloud.${Ts}:443:100.119.14.81 https://cloud.$Ts/status.php"
    music   = 'curl.exe', "$c -L --resolve music.${Ts}:443:100.99.10.37 https://music.$Ts/"
    immich  = 'curl.exe', "$c http://100.70.185.13:2283/api/server/ping"
    grafana = 'curl.exe', "$c http://100.116.32.37:3000/api/health"
}

function TailnetOk {
    try { (tailscale status --json 2>$null | Out-String | ConvertFrom-Json).BackendState -eq 'Running' } catch { $false }
}

function Ssh($target, $cmd) {
    $null = & ssh.exe -i $Key -o BatchMode=yes -o ConnectTimeout=5 "root@$target" $cmd 2>&1
    $LASTEXITCODE
}

# 'ok', or a short reason the check failed.
function Verdict($name, $p) {
    $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    if ($name -eq 'dns') { if ($out -match 'Name:\s+example\.com') { return 'ok' } else { return 'no answer' } }
    $code = 0; $null = [int]::TryParse($out.Trim(), [ref]$code)
    if ($p.ExitCode -eq 0 -and $code -ge 200 -and $code -lt 400) { return 'ok' }
    switch ($p.ExitCode) {
        0 { "http $code" }  7 { 'unreachable' }  28 { 'timeout' }  35 { 'tls' }
        52 { 'empty reply' }  56 { 'reset' }  60 { 'bad cert' }  default { "curl $($p.ExitCode)" }
    }
}

# Runs every pending check in parallel each round until all pass or $limit seconds pass. Fills $r in place.
function Watch($t0, $limit, $r) {
    $last = ''
    while ($r.up.Count -lt $checks.Count -and ((Get-Date) - $t0).TotalSeconds -lt $limit) {
        if (-not (TailnetOk)) {
            if ($r.instrument) { Write-Host 'WARNING: Tailscale on this laptop is down; this trial will be marked instrument_ok=False' }
            $r.instrument = $false
        }
        $procs = [ordered]@{}
        foreach ($n in $checks.Keys) {
            if ($r.up.Contains($n)) { continue }
            $psi = New-Object Diagnostics.ProcessStartInfo $checks[$n][0], $checks[$n][1]
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $procs[$n] = [Diagnostics.Process]::Start($psi)
        }
        foreach ($n in $procs.Keys) {
            $v = Verdict $n $procs[$n]
            if ($v -eq 'ok') {
                $r.up[$n] = [int](($procs[$n].ExitTime - $t0).TotalSeconds)
                Write-Host ('{0,-8} up at {1}s' -f $n, $r.up[$n])
            } else { $r.why[$n] = $v }
        }
        $wait = ($checks.Keys | Where-Object { -not $r.up.Contains($_) } | ForEach-Object { "$_ ($($r.why[$_]))" }) -join ', '
        if ($wait -and $wait -ne $last) {
            Write-Host ('[{0,4}s] waiting: {1}' -f [int]((Get-Date) - $t0).TotalSeconds, $wait)
            $last = $wait
        }
        Start-Sleep 2
    }
}

function Save($t0, $r, $note) {
    $row = [ordered]@{ date = $t0.ToString('s'); recovered = ($r.up.Count -eq $checks.Count); instrument_ok = $r.instrument }
    foreach ($n in $checks.Keys) { $row[$n] = $r.up[$n] }
    $row['total'] = if ($row['recovered']) { ($r.up.Values | Measure-Object -Maximum).Maximum } else { '' }
    $row['stuck'] = ($checks.Keys | Where-Object { -not $r.up.Contains($_) } | ForEach-Object { "$_=$($r.why[$_])" }) -join '; '
    $row['note'] = $note
    [pscustomobject]$row | Export-Csv $File -Append -NoTypeInformation
}

# Only trials where the laptop itself stayed healthy, and that weren't aborted, count toward the stats.
function Summary {
    $all = @(Import-Csv $File)
    $valid = @($all | Where-Object { $_.instrument_ok -eq 'True' -and $_.note -notlike 'aborted*' })
    $t = @($valid | Where-Object { $_.recovered -eq 'True' } | ForEach-Object { [int]$_.total } | Sort-Object)
    Write-Host ('trials: {0}  valid: {1}  recovered: {2}' -f $all.Count, $valid.Count, $t.Count)
    if ($t.Count) {
        $median = ($t[[math]::Floor(($t.Count - 1) / 2)] + $t[[math]::Ceiling(($t.Count - 1) / 2)]) / 2
        Write-Host ('median: {0}s  worst: {1}s' -f $median, $t[-1])
    }
}

# One measured trial. The row is written even if you Ctrl+C.
function Trial($t0, $note) {
    $r = @{ up = [ordered]@{}; why = @{}; instrument = $true }
    $saved = $false
    try { Watch $t0 $Timeout $r; Save $t0 $r $note; $saved = $true }
    finally { if (-not $saved) { Save $t0 $r 'aborted (Ctrl+C)' } }
    Summary
    $r.up.Count -eq $checks.Count
}

if (-not (TailnetOk)) { throw 'Tailscale is not running on this laptop. Start it; "tailscale set --accept-dns=false" keeps your normal DNS.' }

if ($Mode -eq 'manual') {
    Read-Host 'Press Enter the moment power comes back'
    $null = Trial (Get-Date) 'manual'
    return
}

foreach ($t in $Node1, $R3P) {
    if ((Ssh $t 'true') -ne 0) { throw "Passwordless SSH to root@$t failed; install the drill key first." }
}

for ($i = 1; $i -le $Trials; $i++) {
    Write-Host "`n=== trial $i of $Trials ==="
    Write-Host 'baseline: everything must be up before the outage'
    $pre = @{ up = [ordered]@{}; why = @{}; instrument = $true }
    Watch (Get-Date) 120 $pre
    if ($pre.up.Count -ne $checks.Count) { throw 'Stack not fully healthy before the trial; stopping.' }

    Write-Host 'powering off node1'
    $null = Ssh $Node1 'poweroff'
    # busybox ping exits 1 on no reply; 3 misses in a row from the R3P means node1 has left the LAN
    $misses = 0; $deadline = (Get-Date).AddMinutes(5)
    while ($misses -lt 3) {
        if ((Get-Date) -gt $deadline) { throw 'node1 still answering 5 min after poweroff; stopping.' }
        if ((Ssh $R3P "ping -c 1 -W 1 $Node1Lan") -eq 1) { $misses++ } else { $misses = 0 }
        Start-Sleep 2
    }
    Write-Host 'node1 is off the LAN; waiting 30s so it is fully powered down'
    Start-Sleep 30

    Write-Host 'rebooting the R3P, timer starts now'
    $t0 = Get-Date
    $null = Ssh $R3P 'reboot'
    if (-not (Trial $t0 'auto')) { Write-Host 'Not recovered; stopping so you can look at it.'; break }
    if ($i -lt $Trials) { Write-Host "settling ${Settle}s"; Start-Sleep $Settle }
}
