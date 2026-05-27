#!/bin/bash

# ==============================================================================
# [미션 요구사항] 시스템 관제 자동화 스크립트 (monitor.sh)
# 경로: $AGENT_HOME/bin/monitor.sh
# 소유자: agent-dev | 그룹: agent-core | 권한: 750 (rwxr-x---)
# cron 실행 계정: agent-admin (agent-core 그룹 소속으로 실행 가능)
# ==============================================================================

# 1. 환경 변수 기본값 검증 및 보안 포맷 정의
if [ -z "$AGENT_HOME" ]; then
    AGENT_HOME="/home/agent-dev/agent-app"
fi

LOG_DIR="/var/log/agent-app"
LOG_FILE="$LOG_DIR/monitor.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# ------------------------------------------------------------------------------
# 2. Health Check (실패 시 즉시 감지 후 강제 종료 exit 1)
# ------------------------------------------------------------------------------

# [Check 1] 프로세스 생존 감시 (제공된 애플리케이션 파일명 매칭 및 복수 PID 병합)
PID=$(pgrep -f "agent-app-linux" | paste -sd "," -)
if [ -z "$PID" ]; then
    echo "[$TIMESTAMP] [ERROR] agent-app process is not running. Initiating exit 1." >> "$LOG_FILE"
    exit 1
fi

# [Check 2] TCP 15034 포트 Listen 상태 감시
PORT_CHECK=$(ss -tln | grep -w "15034")
if [ -z "$PORT_CHECK" ]; then
    echo "[$TIMESTAMP] [ERROR] Port 15034 is not listening. Initiating exit 1." >> "$LOG_FILE"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. 상태 점검 (비활성 시 경고 로그만 적재, 스크립트는 중단 없이 지속)
# ------------------------------------------------------------------------------

# [보안 우회 완료] sudo ufw status 호출 시의 sudo-rs 권한 거부 반응 원천 배제
UFW_STATUS=$(systemctl is-active ufw | grep "active")
if [ -z "$UFW_STATUS" ]; then
    echo "[$TIMESTAMP] [WARNING] UFW Firewall is inactive." >> "$LOG_FILE"
fi

# ------------------------------------------------------------------------------
# 4. 인프라 자원 수집 및 임계값 경고 (Integer 변환 최적화로 정밀 대응)
# ------------------------------------------------------------------------------

# CPU 사용률 추출 및 bc 문법 오류(syntax error) 처리 완료
CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}')
CPU_USED=$(echo "100 - $CPU_IDLE" | bc)
CPU_INT=$(echo "$CPU_USED" | awk '{print int($1)}')

# 메모리 및 루트 디스크 사용률 수집
MEM_USED=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
DISK_USED=$(df / | tail -1 | awk '{print $5}' | tr -d '%')

# 임계값 정책 비교 연산 (CPU > 20%, MEM > 10%, DISK > 80%)
if [ "$CPU_INT" -gt 20 ]; then
    echo "[$TIMESTAMP] [WARNING] CPU usage exceeded 20% (Current: ${CPU_INT}%)" >> "$LOG_FILE"
fi
if [ "$MEM_USED" -gt 10 ]; then
    echo "[$TIMESTAMP] [WARNING] Memory usage exceeded 10% (Current: ${MEM_USED}%)" >> "$LOG_FILE"
fi
if [ "$DISK_USED" -gt 80 ]; then
    echo "[$TIMESTAMP] [WARNING] Disk usage exceeded 80% (Current: ${DISK_USED}%)" >> "$LOG_FILE"
fi

# ------------------------------------------------------------------------------
# 5. 규격 로그 기록 및 로테이션 보존 정책 (최대 10MB 크기 제어)
# ------------------------------------------------------------------------------

# [요구 포맷 표준 출력 주입]
echo "[$TIMESTAMP] PID:$PID CPU:${CPU_INT}% MEM:${MEM_USED}% DISK_USED:${DISK_USED}%" >> "$LOG_FILE"

# 자체 로그 용량 트리거 분기문
if [ -f "$LOG_FILE" ]; then
    FILE_SIZE=$(wc -c < "$LOG_FILE")
    MAX_SIZE=$((10 * 1024 * 1024)) # 10MB 규격 바이트 연산
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        touch "$LOG_FILE"
        # 공용 그룹 권한 복구 및 쓰기 규칙 유지
        chown root:agent-core "$LOG_FILE"
        chmod 660 "$LOG_FILE"
    fi
fi
