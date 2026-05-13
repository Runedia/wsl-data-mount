<#
WSL --mount 런타임 실행 래퍼.

작업 스케줄러가 매 로그온 시 이 스크립트를 호출한다. SerialNumber로
디스크를 동적 조회하므로 PhysicalDrive 번호가 바뀌어도 동작한다.

이미 부착된 디스크에 대한 재실행은 정상으로 간주하여 0을 반환한다.
디스크가 Online이면 먼저 Offline으로 전환한 뒤 wsl --mount를 시도한다.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SerialNumber,

    [string]$LogPath = 'C:\ProgramData\WSL\mount.log',

    [int]$DiskLookupRetry = 5,

    [int]$DiskLookupDelaySec = 3
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 로그 실패는 무시 (디스크 작업 자체는 계속)
    }
}

try {
    # 로그 디렉터리 보장
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Write-Log "===== 마운트 시도 시작 ====="
    Write-Log "대상 SerialNumber: $SerialNumber"
    Write-Log "실행 컨텍스트: User=$env:USERNAME, PID=$PID"

    $needle = $SerialNumber.Trim()

    # 디스크 조회 (재시도 루프 — 부팅 직후 디스크 인식 지연 대비)
    $disk = $null
    for ($i = 1; $i -le $DiskLookupRetry; $i++) {
        $disk = Get-Disk | Where-Object {
            $_.SerialNumber -and ($_.SerialNumber.Trim() -ieq $needle)
        }
        if (-not $disk) {
            # fallback: 부분 일치
            $disk = Get-Disk | Where-Object {
                $_.SerialNumber -and ($_.SerialNumber -ilike "*$needle*")
            }
            if ($disk -and @($disk).Count -gt 1) {
                Write-Log "SerialNumber 부분 일치로 여러 디스크 매칭. 작업 중단." 'ERROR'
                exit 1
            }
        }
        if ($disk) { break }
        Write-Log "디스크 미발견. 재시도 $i / $DiskLookupRetry"
        Start-Sleep -Seconds $DiskLookupDelaySec
    }

    if (-not $disk) {
        Write-Log '디스크 조회 최종 실패. 작업 중단.' 'ERROR'
        exit 1
    }

    $devicePath = "\\.\PHYSICALDRIVE$($disk.Number)"
    Write-Log "디스크 식별: Number=$($disk.Number), Path=$devicePath, IsOffline=$($disk.IsOffline)"

    # Windows에서 Online 상태면 wsl --mount가 실패한다. Offline으로 전환.
    # SAN 정책(OfflineShared)이 새 디스크에만 적용되므로 기존 디스크에는
    # 매 실행 시점에 명시적으로 Offline 보장이 필요하다.
    if (-not $disk.IsOffline) {
        Write-Log "디스크가 Online 상태. Offline으로 전환 시도." 'WARN'
        try {
            Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop
            Start-Sleep -Seconds 1
            $disk = Get-Disk -Number $disk.Number
            Write-Log "Offline 전환 결과: IsOffline=$($disk.IsOffline)"
        } catch {
            Write-Log "Set-Disk Offline 실패: $($_.Exception.Message)" 'ERROR'
            # 그래도 wsl --mount는 시도해본다 (이미 부착 상태일 수도 있음)
        }
    }

    # wsl --mount 실행
    # wsl.exe는 출력을 UTF-16LE로 내보내므로 OutputEncoding을 맞춰서 캡처해야
    # 한글 메시지의 깨짐을 줄이고 ASCII 오류 코드 매칭이 안정된다.
    Write-Log "wsl --mount $devicePath --bare 실행"
    $prevOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $wslOutput = & wsl.exe --mount $devicePath --bare 2>&1 | Out-String
        $wslExitCode = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
    }
    $wslOutputTrim = $wslOutput.Trim()

    # 매칭용 정규화 — NULL/공백/줄바꿈을 모두 제거해 cp949↔UTF-16 변환 잡음을 흡수.
    # wsl.exe 한국어 메시지가 잘못 디코딩되어 글자 사이에 공백/NULL이 끼더라도
    # ASCII 오류 코드는 살아남는다.
    $normalized = ($wslOutputTrim -replace '[\x00\s]', '')

    Write-Log "ExitCode=$wslExitCode, Output(raw): $wslOutputTrim"
    Write-Log "Output(normalized): $normalized"

    if ($wslExitCode -eq 0) {
        Write-Log '마운트 성공'
        exit 0
    }

    # 이미 마운트된 경우는 정상으로 처리 (멱등성)
    # 정규화된 문자열에 대해 ASCII 오류 코드를 매칭한다.
    $alreadyMountedPatterns = @(
        'WSL_E_DISK_ALREADY_ATTACHED',
        'ALREADY_ATTACHED',
        'ALREADY_MOUNTED'
    )
    foreach ($pattern in $alreadyMountedPatterns) {
        if ($normalized -match $pattern) {
            Write-Log "디스크가 이미 부착된 상태로 추정 (패턴: $pattern). 정상 처리." 'WARN'
            exit 0
        }
    }

    Write-Log "마운트 실패 (ExitCode=$wslExitCode)" 'ERROR'
    exit $wslExitCode

} catch {
    Write-Log "예외 발생: $($_.Exception.Message)" 'ERROR'
    Write-Log "스택: $($_.ScriptStackTrace)" 'ERROR'
    exit 99
}
