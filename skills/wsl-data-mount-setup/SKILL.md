---
name: wsl-data-mount-setup
description: Use when rebuilding WSL2 ext4 passthrough mount system on a fresh Windows install (or new machine), need to identify a data disk by SerialNumber/label/size despite changed disk numbers, or troubleshooting /mnt/data auto-mount via Task Scheduler + fstab
---

# WSL Data Mount Setup

## Overview

WSL2 패스스루 마운트 시스템(`PHYSICALDRIVE → /mnt/data`)을 새 환경에서 재구축하기 위한 절차 안내. 자산 번들은 본 저장소(`<repo-path>`)의 ps1/sh 4개에 모두 포함됨.

핵심 식별 기준: **SerialNumber** (가장 안정), **파티션 라벨** (기본 `wsldata`), **디스크 크기** 순. PhysicalDrive 번호와 FriendlyName은 환경마다 바뀌므로 신뢰하지 않는다.

## Bundle Contents

| 파일 | 역할 |
|---|---|
| `Setup-WSL-DataMount.ps1` | **Windows 부트스트랩** — self-elevation, SAN 정책, Offline 전환, ProgramData 배포, 스케줄러 등록을 일괄 수행 |
| `Setup-Ubuntu-DataMount.sh` | **Ubuntu 부트스트랩** — 라벨 자동 탐지, `/etc/wsl.conf` 보강, `/etc/fstab` 등록, chown |
| `Mount-WSLDisk.ps1` | 런타임 래퍼 (작업 스케줄러가 매 로그온 시 호출) |
| `Register-WSLMount.ps1` | 작업 스케줄러 등록 일회성 스크립트 (Setup-WSL이 내부 호출) |

## Pre-flight Checklist

진행 전 다음을 확인.

- [ ] **WSL2 설치 + Ubuntu distro 등록** — Setup-WSL은 distro를 설치하지 않음. 누락 시 `wsl --install -d Ubuntu` 후 재부팅
- [ ] **Ubuntu 내 sudo 가능 사용자 존재** — 부트스트랩은 `$SUDO_USER`를 자동 감지
- [ ] **데이터 디스크 물리 연결**
- [ ] **데이터 디스크에 기존 ext4 데이터가 있다면 보존 의도 확인** — 라벨 매칭이 안 되면 `--force-format`이 필요할 수 있는데 이는 DESTRUCTIVE
- [ ] **자산 번들 4개 파일 한 디렉터리에 위치** — Setup-WSL은 같은 디렉터리에서 다른 ps1을 찾음

후보 디스크 사전 확인:
```powershell
.\Setup-WSL-DataMount.ps1 -ListCandidates
```

## Run Order

```
[1] Windows측 elevated 실행
        ↓
    UAC 자동 트리거 (스크립트 자체가 self-elevation)
        ↓
    SAN 정책 + 디스크 Offline + 스케줄러 등록 + 즉시 검증 트리거
        ↓
[2] WSL 진입 후 Ubuntu측 sudo 실행
        ↓
    라벨 자동 탐지 + wsl.conf + fstab + chown
        ↓
[3] wsl --shutdown 후 wsl 재진입
        ↓
[4] df -hT /mnt/data 로 최종 검증
```

## Quick Reference

### 표준 시나리오 — 기존 데이터 보존
```powershell
# Windows (관리자/일반 모두 가능 — UAC 자동)
cd <repo-path>
.\Setup-WSL-DataMount.ps1 -SerialNumber '<SN>' -Force
```
```bash
# WSL Ubuntu — 경로는 Windows측 스크립트 종료 시 안내됨
sudo bash /mnt/<drive>/<path>/wsl-data-mount/Setup-Ubuntu-DataMount.sh
```

### 라벨로 자동 식별 (디스크가 이미 부착되어 ext4 라벨로 보이는 상태)
```powershell
.\Setup-WSL-DataMount.ps1 -PartitionLabel '<label>' -Force
```

### 신규 디스크 (데이터 없음) — 포맷부터 수행
```bash
sudo bash Setup-Ubuntu-DataMount.sh --force-format --yes
```

### 변경 사전 검토 (실제 변경 없음)
```bash
sudo bash Setup-Ubuntu-DataMount.sh --dry-run
```

## Disk Identification Strategy

SerialNumber > 라벨 > 크기 순으로 안정. 환경 변화 내성:

| 식별자 | PC 포맷 후 | 다른 머신 | 디스크 교체 |
|---|---|---|---|
| PhysicalDrive 번호 | 가변 | 가변 | 가변 |
| FriendlyName | 동일 | 동일 | 변경 |
| SerialNumber | **동일** | **동일** | 변경 (디스크 자체가 새 것이라면) |
| 파티션 라벨 | 동일 | 동일 | 라벨이 살아있으면 동일 |

**권장**: 본인 디스크의 SerialNumber/UUID는 `LOCAL.md`에 기록(`.gitignore` 제외). 템플릿은 `LOCAL.md.example`.

## Verification

각 단계 직후 확인 명령:

| 단계 | 검증 |
|---|---|
| Windows 후 | `Get-ScheduledTask WSL_Mount_DataNVMe \| Get-ScheduledTaskInfo` → `LastTaskResult=0` |
| 디스크 부착 | `wsl -d Ubuntu -- lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID` → 본인 라벨 등장 |
| Ubuntu 후 | `wsl -d Ubuntu -- df -hT /mnt/data` → `ext4 ...` |
| 재부팅 후 | 위 명령을 재부팅 직후 실행, 동일 결과 |

## Common Failure Modes

| 증상 | 원인 | 조치 |
|---|---|---|
| `Set-StorageSetting: PermissionDenied` | 비-elevated 실행 | 스크립트 self-elevation에 맡기거나 관리자 PowerShell에서 직접 실행 |
| `WSL_E_DISK_ALREADY_ATTACHED` 후 ExitCode=-1 | 멱등성 매칭 불발 (UTF-16/cp949 인코딩) | 번들의 패치된 `Mount-WSLDisk.ps1`가 정규화로 해결 — 백업본 사용 시 패치 적용 필수 |
| `wsl: Processing /etc/fstab with mount -a failed` | fstab UUID 라인의 디바이스가 부착 전 또는 fstab 자체 깨짐 | `cat -A /etc/fstab`로 잡음 라인 확인. `nofail`로 부팅 무영향 |
| 디스크가 재부팅 후 Windows에 다시 Online | SAN 정책 미적용 | `Set-StorageSetting -NewDiskPolicy OfflineShared` (Setup-WSL이 자동 처리) |
| 라벨 매칭 0건 + `--force-format` 미지정 | 디스크 미부착 또는 다른 라벨 | 먼저 Windows측 Setup-WSL을 실행해 부착. 라벨이 다르면 `--label <기존>` |
| 기본 distro가 `docker-desktop`으로 잡힘 | Docker Desktop WSL 통합 부작용 | `wsl --set-default Ubuntu` |

## Idempotency

두 부트스트랩 모두 **idempotent** 설계:
- Windows측: 기존 파일은 `.bak-<timestamp>`로 자동 백업 후 덮어쓰기. SAN 정책/디스크 Offline은 이미 적용돼 있으면 스킵 로그
- Ubuntu측: `/etc/wsl.conf`는 섹션/키별 갱신, `/etc/fstab`는 동일 mount-point 라인 제거 후 재추가, 백업 자동

반복 실행해도 상태 누적 없음.

## File Layout After Setup

```
C:\ProgramData\WSL\
  Mount-WSLDisk.ps1        # 런타임 (스케줄러가 호출)
  Register-WSLMount.ps1    # 등록 스크립트
  mount.log                # 매 실행 로그
  *.bak-*                  # 기존 파일 자동 백업

<repo-path>\                # 본 저장소 위치 (USB 백업 가능)
  Setup-WSL-DataMount.ps1
  Setup-Ubuntu-DataMount.sh
  Mount-WSLDisk.ps1
  Register-WSLMount.ps1
  README.md
  LOCAL.md                  # 사용자 디스크 정보 (.gitignore 제외)
  skills/wsl-data-mount-setup/SKILL.md
```

## When NOT to Use

- 기본 distro/사용자명이 시나리오와 다르면 매개변수로 명시 (`-DistroName`, `--default-user` 등)
- Windows Server / WSL1 — 본 시스템은 WSL2 패스스루(`wsl --mount`) 전용
- 공유 디스크(SMB, iSCSI) — 본 시스템은 로컬 물리 디스크 가정
