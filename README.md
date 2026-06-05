# 🛡️ Linux 기반 시스템 관제 자동화 및 인프라 보안 환경 구축 보고서

본 보고서는 다중 사용자 엔지니어링 환경에서의 역할 기반 권한 제어(RBAC), 인바운드 보안 통제 규칙, 애플리케이션 가동 무결성 확보 및 시스템 리소스 모니터링 스크립트 자동화에 대한 최종 요구사항 수행 내역서입니다.

---

## 📑 1. 요구사항 수행 내역서

### 🔒 [보안 및 네트워크 통제]
- **SSH 인프라 강화**: 원격 접속 기본 포트를 `20022`로 포트 포워딩 변경 처리 완료하였으며, 외부 무차별 대입 공격(Brute Force)의 원천 차단을 위해 `/etc/ssh/sshd_config` 내부 설정을 변경하여 **Root 원격 로그인(`PermitRootLogin no`)을 차단**했습니다.
- **최소 네트워크 차단막 정책**: 방화벽 엔진(`UFW`)을 커널 레이어에서 활성화한 뒤, 승인된 관리 포트인 **TCP 20022 (SSH)** 및 서비스 통신 규격 포트인 **TCP 15034 (APP)** 포트 2개만을 인바운드 허용 리스트로 고정했습니다.

### 👥 [계정/그룹 권한 체계 및 ACL 인프라 설계]
- **역할 기반 사용자 그룹 분리**:
  - `agent-admin`: 자동화 크론 로봇(`crontab`)의 단독 실행자이자 모니터링 주체 계정.
  - `agent-dev`: 관제 핵심 코드인 `monitor.sh`를 연구 및 설계한 개발 권한 계정.
  - `agent-test`: 자원 모니터링 대상 구역의 샌드박스를 확인하는 QA 계정.
- **보안 디렉터리 격리 정책**: 공용 자산 디렉터리는 `agent-common` 그룹에 개방하되, 핵심 암호화 통제 장소인 `$AGENT_HOME/api_keys` 및 시스템 중앙 로그 수집소인 `/var/log/agent-app`은 철저히 **`agent-core` (Admin, Dev 핵심 소속) 그룹 ONLY**의 R/W 권한만 허용하여 권한 탈취 리스크를 완벽하게 배제했습니다.

### 🚀 [애플리케이션 가동 및 부트 시퀀스 통과]
- **보안 암호문 매칭 우회**: 앱 실행 즉시 파이썬 바이너리가 정적 탐색하는 고정 경로 `$AGENT_HOME/api_keys/t_secret.key`를 정석대로 매핑하고, 내부 지시 스트링인 `agent_api_key_test`를 정확히 1줄로 주입 완료했습니다.
- **검증 완료**: 루트(Root) 권한이 아닌 일반 계정 신분으로 환경 변수 5형제를 동기화하여 구동 한 결과, 독점적인 내부 검증 시퀀스가 모두 **[OK]** 사인을 반환하며 `0.0.0.0:15034` 대기 상태인 **"Agent READY"** 플래그를 정상 확인했습니다.

---

## 📋 2. 필수 증거 자료 체크리스트 및 실시간 증적

### 📸 1) SSH 포트 변경 및 독립 구동 검증
> **체크리스트:** sshd 설정 구성 및 `ss -tulnp` 명령을 통한 20022 포트 리슨 상태 점검 (수행 계정: dave)

```bash
sudo grep -E "Port|PermitRootLogin" /etc/ssh/sshd_config | grep -v '^#' ; sudo ss -tulnp | grep ssh
```
![SSH 포트 독립 구동 화면](docs/screenshots/01_ssh_setting.png)

---

### 📸 2) 방화벽(UFW) 활성화 및 필요 포트 격리 허용 인증
> **체크리스트:** `ufw status verbose` 결과 내역 중 20022/tcp 및 15034/tcp 포트 인바운드 허용 (수행 계정: dave)

```bash
sudo ufw status verbose
```
![방화벽 설정 규칙 화면](docs/screenshots/02_ufw_status.png)

---

### 📸 3) 역할 기반 접근 제어(RBAC) 신분증 배지 검증
> **체크리스트:** `id` 명령어를 통한 계정별 고유 UID/GID 및 소속 groups 추가 배지 획득 내역 확인 (수행 계정: agent-admin)

```bash
id agent-admin; id agent-dev; id agent-test
```
![계정별 그룹 배지 검증 화면](docs/screenshots/03_rbac_identity.png)

---

### 📸 4) 보안 디렉터리 파일 소유권 및 770 자물쇠 구조 확인
> **체크리스트:** `ls -l`을 통한 api_keys(agent-core 전용) 및 upload_files(agent-common 공용) 권한 분리 상태 검증 (수행 계정: agent-admin)

```bash
ls -l /home/agent-dev/agent-app
```
![디렉터리 권한 구조 확인 화면](docs/screenshots/04_dir_permission.png)

---

### 📸 5) 일반 테스터(agent-test)의 핵심 보안 구역 침투 차단 증적
> **체크리스트:** 권한이 없는 격리 계정이 핵심 키 폴더 접근 시 커널 레이어 차단 및 에러 유도 (수행 계정: agent-test)

```bash
cat /home/agent-dev/agent-app/api_keys/t_secret.key
```
![테스터 접근 원천 차단 화면](docs/screenshots/05_sandbox_block.png)

---

### 📸 6) 애플리케이션 Boot Sequence 5단계 Pass 증적
> **체크리스트:** x86 바이너리 초기 구동 환경 변수 동기화 및 최종 Agent READY 로그 출력 상태 (수행 계정: agent-dev)

```bash
$AGENT_HOME/agent-app-linux-x86
```
![App Boot Sequence 통과 화면](docs/screenshots/06_app_boot.png)

---

### 📸 7) 관리자 크론탭(Crontab) 자동화 로봇 등록 검증
> **체크리스트:** `crontab -l` 명령어를 통한 1분 주기 monitor.sh 관제 스크립트 연동 상태 기록 확인 (수행 계정: agent-admin)

```bash
crontab -l
```
![크론탭 스케줄러 등록 화면](docs/screenshots/07_cron_setting.png)

---

### 📸 8) 실시간 관제 일지(monitor.log) 1분 주기 축적 증적
> **체크리스트:** `/var/log/agent-app/monitor.log`에 실시간 누적되는 인프라 표준 포맷 일지 연속 추적 (수행 계정: agent-admin)

```bash
tail -f /var/log/agent-app/monitor.log
```
![관제 일지 실시간 누적 화면](docs/screenshots/08_monitor_log.png)
