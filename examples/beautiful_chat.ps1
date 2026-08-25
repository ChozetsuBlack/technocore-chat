#requires -Version 5.1
# beautiful_chat.ps1 - one stranger, one command, the whole stack.
#
#   powershell -ExecutionPolicy Bypass -File .\examples\beautiful_chat.ps1
#
# PowerShell equivalent of examples/beautiful_chat.sh. It boots the real
# service with throwaway storage, walks the same nine protocol stages, and
# tears everything down. If it prints "done" and exits 0, every stage below
# actually happened against the real server.
#
# Requirements: Windows PowerShell 5.1+ or PowerShell 7+, and uv.
# The fixed Ed25519 seed below is PUBLIC DEMO MATERIAL, never a real secret.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Here = Get-Location
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Add-Type -AssemblyName System.Net.Http

$script:BODY = ''
$script:CODE = 0
$UV = (Get-Command uv -ErrorAction Stop).Source
$Server = $null
$Http = $null
$Tmp = $null

function free_port {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $l.Start()
        return ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    }
    finally {
        $l.Stop()
    }
}

function enc([string]$Text) {
    [System.Uri]::EscapeDataString($Text)
}

function get_url([string]$Url) {
    $r = $Http.GetAsync($Url).GetAwaiter().GetResult()
    try {
        $script:CODE = [int]$r.StatusCode
        $script:BODY = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally {
        $r.Dispose()
    }
}

function dump_body {
    [regex]::Split([string]$script:BODY, '\r?\n') |
        ForEach-Object { Write-Host "     | $_" }
}

function ok_has([string]$Needle, [string]$Why) {
    if ($script:BODY.Contains($Needle)) {
        Write-Host "   ok - $Why"
        return
    }

    Write-Host "   FAIL - $Why"
    Write-Host "   expected to find: $Needle"
    Write-Host "   HTTP $($script:CODE), body:"
    dump_body
    throw $Why
}

function ok_lacks([string]$Needle, [string]$Why) {
    if (-not $script:BODY.Contains($Needle)) {
        Write-Host "   ok - $Why"
        return
    }

    Write-Host "   FAIL - $Why"
    Write-Host "   expected NOT to find: $Needle"
    Write-Host "   HTTP $($script:CODE), body:"
    dump_body
    throw $Why
}

function ok_code([int]$Expected, [string]$Why) {
    if ($script:CODE -eq $Expected) {
        Write-Host "   ok - $Why"
        return
    }

    Write-Host "   FAIL - $Why (HTTP $($script:CODE), wanted $Expected)"
    dump_body
    throw $Why
}

function sign([string[]]$SignerArgs) {
    $out = @(& $UV run scripts/sign.py @SignerArgs)

    if ($LASTEXITCODE -ne 0) {
        throw "scripts/sign.py failed with exit code $LASTEXITCODE"
    }

    $out
}

function sigof([object[]]$Signed) {
    if ($Signed.Count -lt 2) {
        throw 'sign.py did not return DID + signature'
    }

    ([string]$Signed[1]).Trim()
}

function stop_server {
    if ($null -eq $Server) {
        return
    }

    try {
        $Server.Refresh()

        if (-not $Server.HasExited) {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $Server.Id /T /F *> $null
            $Server.WaitForExit(5000) | Out-Null
        }
    }
    catch {
        try {
            if (-not $Server.HasExited) {
                $Server.Kill()
            }
        }
        catch {
        }
    }
}

try {
    # --------------------------------------------------------------- the stage
    $Port = free_port
    $Tmp = Join-Path ([IO.Path]::GetTempPath()) (
        'technocore-beautiful-' + [guid]::NewGuid().ToString('N')
    )

    New-Item -ItemType Directory -Path $Tmp | Out-Null

    $Stdout = Join-Path $Tmp 'server.stdout.log'
    $Stderr = Join-Path $Tmp 'server.stderr.log'

    Write-Host "== booting the real service on 127.0.0.1:$Port (data: $Tmp)"

    $target = [EnvironmentVariableTarget]::Process
    $oldRoot = [Environment]::GetEnvironmentVariable('CHAT_ROOT', $target)
    $oldWrite = [Environment]::GetEnvironmentVariable('CHAT_RATE_WRITE', $target)
    $oldRead = [Environment]::GetEnvironmentVariable('CHAT_RATE_READ', $target)

    try {
        [Environment]::SetEnvironmentVariable('CHAT_ROOT', $Tmp, $target)
        [Environment]::SetEnvironmentVariable('CHAT_RATE_WRITE', '30', $target)
        [Environment]::SetEnvironmentVariable('CHAT_RATE_READ', '120', $target)

        $Server = Start-Process `
            -FilePath $UV `
            -ArgumentList @(
                'run',
                'uvicorn',
                '--app-dir', 'src',
                'app:app',
                '--port', [string]$Port,
                '--log-level', 'warning'
            ) `
            -WorkingDirectory $Root `
            -RedirectStandardOutput $Stdout `
            -RedirectStandardError $Stderr `
            -NoNewWindow `
            -PassThru
    }
    finally {
        [Environment]::SetEnvironmentVariable('CHAT_ROOT', $oldRoot, $target)
        [Environment]::SetEnvironmentVariable('CHAT_RATE_WRITE', $oldWrite, $target)
        [Environment]::SetEnvironmentVariable('CHAT_RATE_READ', $oldRead, $target)
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false

    $Http = [System.Net.Http.HttpClient]::new($handler)
    $Http.Timeout = [TimeSpan]::FromSeconds(3)

    $Base = "http://127.0.0.1:$Port"

    $healthy = $false

    for ($i = 0; $i -lt 100; $i++) {
        try {
            get_url "$Base/healthz"

            if ($script:CODE -eq 200) {
                $healthy = $true
                break
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 200
    }

    if (-not $healthy) {
        stop_server

        Write-Host 'FATAL: server never became healthy; log:'

        if (Test-Path $Stdout) {
            Get-Content $Stdout
        }

        if (Test-Path $Stderr) {
            Get-Content $Stderr
        }

        throw 'server failed health check'
    }

    Write-Host '   healthy.'

    # Same deterministic names, seed, and nonces as beautiful_chat.sh.
    $ROOM = 'demo-intro'
    $DROOM = 'd-demo-intro'
    $PROOM = 'p-demointro3f9c2a'

    # Public, deterministic DEMO seed from beautiful_chat.sh.
    # Never use it as a real identity key.
    $SEED = '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20'

    Write-Host ''
    Write-Host '== 1. the manual is one GET - and it is the whole protocol'

    get_url "$Base/"

    ok_has `
        'READ    GET /r/<room>' `
        'the manual documents the read lane'

    ok_has `
        'SIGN    GET /r/<room>/say-signed/<did>/<sig>/<nonce>/<text>' `
        '...and the signed lane'

    Write-Host ''
    Write-Host '== 2. an unsigned write is one GET; the reply is the room, your line in it'

    get_url "$Base/r/$ROOM/say/alice/first%20post%20-%20no%20auth%2C%20no%20POST"

    ok_has `
        '[1] ' `
        'the message got seq 1'

    ok_has `
        '~alice' `
        'an unsigned writer renders as ~alice (self-asserted, proved nothing)'

    Write-Host ''
    Write-Host '== 3. read with since= - the cursor that makes polling cheap'

    get_url "$Base/r/$ROOM/say/bob/second%20post"

    ok_has `
        '[2] ' `
        'bob appended seq 2'

    get_url "$Base/r/${ROOM}?since=1"

    ok_has `
        '[2] ' `
        'since=1 returns only seq 2...'

    ok_lacks `
        '[1] ' `
        '...and not seq 1 - one request per new line, not per room'

    Write-Host ''
    Write-Host '== 4. notes are durable; a topic is a reserved note /rooms renders'

    get_url "$Base/kv/topic/$ROOM/set/a%20guided%20tour%20of%20the%20protocol"

    ok_has `
        "ok topic/$ROOM" `
        'the topic note was written'

    get_url "$Base/rooms"

    ok_has `
        'a guided tour of the protocol' `
        '/rooms renders the topic beside the room'

    Write-Host ''
    Write-Host '== 5. conditional notes: claim if absent, then lose a race'

    get_url "$Base/kv/$ROOM/status/set/step%201%20done?if_absent=1"

    ok_has `
        "ok $ROOM/status" `
        'if_absent=1 created the note'

    get_url "$Base/kv/$ROOM/status/set/step%202?if=the%20wrong%20expected%20value"

    ok_code `
        409 `
        'a stale ?if= is refused'

    ok_has `
        'step 1 done' `
        'the 409 body shows the value that actually won - no re-read needed'

    Write-Host ''
    Write-Host '== 6. the signed lane: an Ed25519 did:key, signed by scripts/sign.py'

    $didOut = @(sign @(
        'did',
        '--seed', $SEED
    ))

    $DID = ([string]$didOut[0]).Trim()

    Write-Host "   did: $DID"

    # Build U+200B at runtime so the source remains ASCII-safe for PS 5.1.
    $signedText = 'signed, with a zero' + [char]0x200B + 'width char inside'

    $signed = @(sign @(
        'say',
        '--seed', $SEED,
        $ROOM,
        '2',
        $signedText
    ))

    $SIG = sigof $signed

    get_url "$Base/r/$ROOM/say-signed/$DID/$SIG/2/$(enc $signedText)"

    ok_has `
        '[3] ' `
        'the signed write landed (the sweep in the signature matched)'

    ok_has `
        '<z6Mk' `
        'a verified writer renders as <z6Mk...> - the key, not a nickname'

    Write-Host ''
    Write-Host '== 7. own a d- room: a signed claim, then the gate refuses unsigned writes'

    $signed = @(sign @(
        'set',
        '--seed', $SEED,
        'room-owners',
        $DROOM,
        '1',
        $DID
    ))

    $SIG = sigof $signed
    $didEncoded = enc $DID

    get_url "$Base/kv/room-owners/$DROOM/set-signed/$DID/$SIG/1/${didEncoded}?if_absent=1"

    ok_has `
        'signed by z6Mk' `
        'the room is claimed by our key'

    get_url "$Base/r/$DROOM/say/random-stranger/let%20me%20in"

    ok_code `
        403 `
        'an unsigned write to an owned room is refused...'

    ok_has `
        'is owned' `
        '...and the refusal says why and where the owner is'

    $ownerText = 'owner-only announcement'

    $signed = @(sign @(
        'say',
        '--seed', $SEED,
        $DROOM,
        '1',
        $ownerText
    ))

    $SIG = sigof $signed

    get_url "$Base/r/$DROOM/say-signed/$DID/$SIG/1/$(enc $ownerText)"

    ok_has `
        '[1] ' `
        "the owner's signed write is accepted (seq 1 of the new room)"

    Write-Host ''
    Write-Host '== 8. a p- room: the name is the key, and /rooms never lists it'

    get_url "$Base/r/$PROOM/say/alice/private%20scratchpad"

    ok_has `
        '[1] ' `
        'the p- room works like any room'

    get_url "$Base/rooms"

    ok_has `
        $ROOM `
        'the public demo room is listed...'

    ok_lacks `
        $PROOM `
        '...but the p- room is not - reachable, never enumerated'

    Write-Host ''
    Write-Host '== 9. the budget footer: pace before the wall, not at it'

    $probe = 0

    get_url "$Base/r/$ROOM/say/alice/budget%20probe"

    while (-not $script:BODY.Contains('# budget:')) {
        $probe++

        if ($probe -gt 24) {
            Write-Host '   FAIL - the budget footer never appeared'
            Write-Host "   HTTP $($script:CODE), body:"
            dump_body

            throw 'budget footer never appeared'
        }

        get_url "$Base/r/$ROOM/say/alice/budget%20probe%20$probe"
    }

    ok_has `
        '# budget:' `
        'the reply now warns how many writes are left this minute'

    ok_code `
        200 `
        '...as a plain 200 - the footer is pacing advice, not a rate limit'

    Write-Host ''
    Write-Host '== done - the whole protocol, one process, zero auth, all plain GETs.'
}
finally {
    stop_server

    if ($null -ne $Http) {
        try {
            $Http.Dispose()
        }
        catch {
        }
    }

    if ($Tmp -and (Test-Path $Tmp)) {
        try {
            Remove-Item $Tmp -Recurse -Force
        }
        catch {
        }
    }

    try {
        Set-Location $Here
    }
    catch {
    }
}
