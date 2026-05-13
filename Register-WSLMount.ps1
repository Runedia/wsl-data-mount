<#
.SYNOPSIS
    WSL2 물리 디스크 자동 부착을 위한 작업 스케줄러 등록 스크립트.

.DESCRIPTION
    지정된 NVMe 디스크를 사용자 로그온 시 WSL2 VM에 --bare 모드로
    자동 부착하는 작업 스케줄러 항목을 생성한다.

    핵심 설계:
      - 디스크는 SerialNumber로 식별되며, PhysicalDrive 번호 변동에 강건함
      - 런타임 래퍼 스크립트가 별도 파일로 생성되어 매 실행마다 디스크 재조회
      - 모든 동작은 로그 파일에 타임스탬프와 함께 기록됨
      - 멱등적 동작: 이미 부착된 디스크에 대한 재실행은 오류로 처리하지 않음

    사전 요건 (이 스크립트가 검증함):
      - 관리자 권한 PowerShell
      - WSL 0.67.6 이상
      - 대상 디스크가 Get-Disk로 조회 가능

.PARAMETER DriveLetter
    부착 대상 디스크의 현재 Windows 드라이브 문자.
    이 문자를 통해 SerialNumber가 자동 조회된다.
    디스크가 이미 오프라인 상태이거나 드라이브 문자가 제거된 경우
    -SerialNumber 파라미터를 직접 사용.

.PARAMETER SerialNumber
    디스크 SerialNumber를 직접 지정. -DriveLetter와 상호 배타적.
    Get-Disk | Select-Object Number, SerialNumber 로 확인 가능.

.PARAMETER TaskName
    작업 스케줄러 항목 이름. 기본값: WSL_Mount_DataNVMe

.PARAMETER WrapperPath
    런타임 마운트 래퍼 스크립트 경로.
    기본값: C:\ProgramData\WSL\Mount-WSLDisk.ps1

.PARAMETER LogPath
    런타임 마운트 로그 파일 경로.
    기본값: C:\ProgramData\WSL\mount.log

.PARAMETER Force
    동일 이름의 기존 작업이 있을 경우 덮어쓴다.

.EXAMPLE
    .\Register-WSLMount.ps1 -DriveLetter Y

    Y 드라이브에서 SerialNumber를 조회하여 작업을 등록한다.

.EXAMPLE
    .\Register-WSLMount.ps1 -SerialNumber "ABCD1234EFGH" -Force

    이미 오프라인된 디스크에 대해 SerialNumber로 직접 지정, 기존 작업 덮어쓰기.

.NOTES
    실행 후 즉시 테스트:
        Start-ScheduledTask -TaskName 'WSL_Mount_DataNVMe'
        Get-Content 'C:\ProgramData\WSL\mount.log' -Tail 20
#>

#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'ByDriveLetter')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByDriveLetter')]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,

    [Parameter(Mandatory, ParameterSetName = 'BySerial')]
    [ValidateNotNullOrEmpty()]
    [string]$SerialNumber,

    [Parameter(Mandatory, ParameterSetName = 'ByDiskNumber')]
    [ValidateRange(0, 99)]
    [int]$DiskNumber,

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'WSL_Mount_DataNVMe',

    [ValidateNotNullOrEmpty()]
    [string]$WrapperPath = 'C:\ProgramData\WSL\Mount-WSLDisk.ps1',

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\ProgramData\WSL\mount.log',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ===== 출력 헬퍼 =====

function Write-Info { param($Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Ok   { param($Message) Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err  { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# ===== 사전 검사 =====

Write-Info '사전 검사 시작'

# WSL 설치 확인
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    Write-Err 'wsl.exe를 찾을 수 없음. WSL2가 설치되어 있어야 함.'
    exit 1
}
Write-Ok "WSL 실행 파일: $($wslCmd.Source)"

# WSL 버전 정보 (참고용 — 출력은 UTF-16이라 PS에서 깨질 수 있어 간략 처리)
try {
    $null = & wsl.exe --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info 'wsl --version OK (출력은 인코딩 차이로 생략)'
    } else {
        Write-Warn 'wsl --version 응답 없음. 구형 WSL일 수 있음 (--manage 등 일부 명령 미지원 가능).'
    }
} catch {
    Write-Warn "WSL 버전 조회 실패: $($_.Exception.Message)"
}

# 디스크 식별
if ($PSCmdlet.ParameterSetName -eq 'ByDriveLetter') {
    Write-Info "드라이브 ${DriveLetter}: 에서 디스크 정보 조회"
    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk = $partition | Get-Disk
    } catch {
        Write-Err "드라이브 ${DriveLetter}: 를 찾을 수 없음."
        Write-Err '이미 오프라인이거나 문자가 제거된 경우 -SerialNumber 또는 -DiskNumber 파라미터로 직접 지정 바람.'
        exit 1
    }
    $SerialNumber = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } else { '' }
}
elseif ($PSCmdlet.ParameterSetName -eq 'ByDiskNumber') {
    Write-Info "DiskNumber $DiskNumber 로 디스크 조회"
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-Err "DiskNumber=$DiskNumber 에 해당하는 디스크를 찾을 수 없음."
        Get-Disk | Format-Table -AutoSize | Out-String | Write-Host
        exit 1
    }
    $SerialNumber = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } else { '' }
}
else {
    Write-Info "SerialNumber '$SerialNumber' 로 디스크 조회 (공백 제거, 대소문자 무시)"
    $needle = $SerialNumber.Trim()

    # 1차: 완전 일치 (trim + 대소문자 무시)
    $disk = Get-Disk | Where-Object {
        $_.SerialNumber -and ($_.SerialNumber.Trim() -ieq $needle)
    }

    # 2차 fallback: 부분 일치 (공백 포함 raw 문자열에 needle이 포함되는지)
    if (-not $disk) {
        $disk = Get-Disk | Where-Object {
            $_.SerialNumber -and ($_.SerialNumber -ilike "*$needle*")
        }
        if ($disk -and @($disk).Count -gt 1) {
            Write-Err "SerialNumber 부분 일치로 여러 디스크가 매칭됨. 더 구체적인 값을 지정 바람."
            $disk | Format-Table Number, FriendlyName, SerialNumber, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}} -AutoSize | Out-String | Write-Host
            exit 1
        }
        if ($disk) {
            Write-Warn "완전 일치 실패. 부분 일치로 매칭됨: '$($disk.SerialNumber)'"
            $SerialNumber = $disk.SerialNumber.Trim()
        }
    }

    if (-not $disk) {
        Write-Err "SerialNumber='$needle' 에 해당하는 디스크를 찾을 수 없음."
        Write-Err '현재 시스템의 모든 디스크 목록:'
        Get-Disk | ForEach-Object {
            [PSCustomObject]@{
                Number       = $_.Number
                FriendlyName = $_.FriendlyName
                SerialRaw    = "'$($_.SerialNumber)'"
                SerialLen    = if ($_.SerialNumber) { $_.SerialNumber.Length } else { 0 }
                SizeGB       = [math]::Round($_.Size / 1GB, 1)
            }
        } | Format-Table -AutoSize | Out-String | Write-Host
        Write-Err '대안: -DiskNumber <N> 로 디스크 번호 직접 지정.'
        exit 1
    }
}

if (-not $SerialNumber -or $SerialNumber.Trim() -eq '') {
    Write-Err '디스크에 SerialNumber가 비어 있음. 가상 디스크 또는 일부 컨트롤러에서 발생.'
    Write-Err '이 경우 작업 스케줄러 자동 등록은 불안정함. PhysicalDrive 번호 직접 지정 방식이 필요.'
    exit 1
}

Write-Ok '디스크 식별 완료:'
Write-Host ("           Number         : {0}" -f $disk.Number)
Write-Host ("           FriendlyName   : {0}" -f $disk.FriendlyName)
Write-Host ("           SerialNumber   : {0}" -f $disk.SerialNumber)
Write-Host ("           Size           : {0} GB" -f [math]::Round($disk.Size / 1GB, 2))
Write-Host ("           PartitionStyle : {0}" -f $disk.PartitionStyle)
Write-Host ("           IsOffline      : {0}" -f $disk.IsOffline)

# 기존 작업 확인
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    if (-not $Force) {
        Write-Err "동일 이름의 작업이 이미 존재: $TaskName"
        Write-Err '덮어쓰려면 -Force 지정.'
        exit 1
    }
    Write-Warn "기존 작업 제거: $TaskName"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# ===== 런타임 래퍼 스크립트 작성 =====

Write-Info "런타임 래퍼 스크립트 생성: $WrapperPath"

$wrapperDir = Split-Path $WrapperPath -Parent
if (-not (Test-Path $wrapperDir)) {
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null
}

# 래퍼 스크립트 본문 (here-string)
$wrapperContent = @'
<#
WSL --mount 런타임 실행 래퍼.

작업 스케줄러가 매 로그온 시 이 스크립트를 호출한다. SerialNumber로
디스크를 동적 조회하므로 PhysicalDrive 번호가 바뀌어도 동작한다.

이미 부착된 디스크에 대한 재실행은 정상으로 간주하여 0을 반환한다.
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
    Write-Log "디스크 식별: Number=$($disk.Number), Path=$devicePath, Online=$(-not $disk.IsOffline)"

    # wsl --mount 실행
    Write-Log "wsl --mount $devicePath --bare 실행"
    $wslOutput = & wsl.exe --mount $devicePath --bare 2>&1 | Out-String
    $wslExitCode = $LASTEXITCODE
    $wslOutputTrim = $wslOutput.Trim()

    Write-Log "ExitCode=$wslExitCode, Output: $wslOutputTrim"

    if ($wslExitCode -eq 0) {
        Write-Log '마운트 성공'
        exit 0
    }

    # 이미 마운트된 경우는 정상으로 처리 (멱등성)
    # ASCII 오류 코드 우선 매칭 — wsl.exe의 한국어 메시지는 PS 캡처 시 깨질 수 있음
    $alreadyMountedPatterns = @(
        'WSL_E_DISK_ALREADY_ATTACHED',
        'ALREADY_ATTACHED',
        'ALREADY_MOUNTED',
        'already attached',
        'already mounted',
        '이미',
        'in use',
        'busy'
    )
    foreach ($pattern in $alreadyMountedPatterns) {
        if ($wslOutputTrim -match $pattern) {
            Write-Log "디스크가 이미 부착된 상태로 추정. 정상 처리." 'WARN'
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
'@

Set-Content -Path $WrapperPath -Value $wrapperContent -Encoding UTF8
Write-Ok '래퍼 스크립트 작성 완료'

# ===== 작업 스케줄러 항목 구성 =====

Write-Info "작업 스케줄러 등록: $TaskName"

$psExe = (Get-Command powershell.exe -ErrorAction Stop).Source

# 인자 구성 — 경로에 공백 가능성을 고려하여 큰따옴표로 감쌈
$wrapperArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', "`"$WrapperPath`"",
    '-SerialNumber', "`"$SerialNumber`"",
    '-LogPath', "`"$LogPath`""
) -join ' '

$Action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument $wrapperArgs

$Trigger = New-ScheduledTaskTrigger `
    -AtLogOn `
    -User "$env:USERDOMAIN\$env:USERNAME"

$Principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

$description = @"
WSL2 데이터 NVMe 자동 부착 (등록 시점 정보)
  Disk Number  : $($disk.Number)
  Disk Name    : $($disk.FriendlyName)
  SerialNumber : $SerialNumber
  Registered   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $Principal `
    -Settings $Settings `
    -Description $description `
    -Force | Out-Null

Write-Ok '작업 스케줄러 등록 완료'

# ===== 결과 요약 =====

Write-Host ''
Write-Host '===== 등록 완료 =====' -ForegroundColor Green
Write-Host ''
Write-Host "  TaskName        : $TaskName"
Write-Host "  Trigger         : 사용자 로그온 시"
Write-Host "  Wrapper Script  : $WrapperPath"
Write-Host "  Log File        : $LogPath"
Write-Host "  Disk Number     : $($disk.Number) (변경 가능 — SerialNumber 기준 동적 조회)"
Write-Host "  SerialNumber    : $SerialNumber"
Write-Host ''
Write-Host '----- 검증 명령 -----' -ForegroundColor Yellow
Write-Host ''
Write-Host '  # 즉시 실행 (재부팅 전 동작 확인)'
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host ''
Write-Host '  # 로그 확인'
Write-Host "  Get-Content '$LogPath' -Tail 30"
Write-Host ''
Write-Host '  # WSL 내부에서 디스크 인식 확인'
Write-Host '  wsl -- lsblk -d -o NAME,SIZE,MODEL,TYPE'
Write-Host ''
Write-Host '  # 작업 상태 조회'
Write-Host "  Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host ''
Write-Host '----- 제거 명령 -----' -ForegroundColor Yellow
Write-Host ''
Write-Host "  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
Write-Host "  Remove-Item '$WrapperPath' -ErrorAction SilentlyContinue"
Write-Host ''
