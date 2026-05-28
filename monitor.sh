#!/bin/bash

# [환경 변수 설정]
if [ -z "$AGENT_HOME" ]; then
    AGENT_HOME="/home/agent-dev/agent-app"
fi
LOG_DIR="/var/log/agent-app"
LOG_FILE="$LOG_DIR/monitor.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# [Health Check] 프로세스(파일명 매칭) 및 포트 15034 생존 감시 (비정상 시 exit 1)
PID=$(pgrep -f "agent-app-linux" | paste -sd "," -)
if [ -z "$PID" ]; then
    echo "[$TIMESTAMP] [ERROR] agent-app process is not running. Initiating exit 1." >> "$LOG_FILE"
    exit 1
fi
PORT_CHECK=$(ss -tln | grep -w "15034")
if [ -z "$PORT_CHECK" ]; then
    echo "[$TIMESTAMP] [ERROR] Port 15034 is not listening. Initiating exit 1." >> "$LOG_FILE"
    exit 1
fi

# [상태 점검] 일반 권한 방화벽 활성화 점검 (비활성 시 경고만 출력, 지속)
UFW_STATUS=$(systemctl is-active ufw | grep "active")
if [ -z "$UFW_STATUS" ]; then
    echo "[$TIMESTAMP] [WARNING] UFW Firewall is inactive." >> "$LOG_FILE"
fi

# [자원 수집] bc 오타 원천 차단 정수형 변환 (CPU, MEM, ROOT DISK)
CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}')
CPU_USED=$(echo "100 - $CPU_IDLE" | bc)
CPU_INT=$(echo "$CPU_USED" | awk '{print int($1)}')
MEM_USED=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
DISK_USED=$(df / | tail -1 | awk '{print $5}' | tr -d '%')

# [임계값 경고 판단]
if [ "$CPU_INT" -gt 20 ]; then echo "[$TIMESTAMP] [WARNING] CPU usage exceeded 20% (Current: ${CPU_INT}%)" >> "$LOG_FILE"; fi
if [ "$MEM_USED" -gt 10 ]; then echo "[$TIMESTAMP] [WARNING] Memory usage exceeded 10% (Current: ${MEM_USED}%)" >> "$LOG_FILE"; fi
if [ "$DISK_USED" -gt 80 ]; then echo "[$TIMESTAMP] [WARNING] Disk usage exceeded 80% (Current: ${DISK_USED}%)" >> "$LOG_FILE"; fi

# [명세서 표준 포맷 로그 기록]
echo "[$TIMESTAMP] PID:$PID CPU:${CPU_INT}% MEM:${MEM_USED}% DISK_USED:${DISK_USED}%" >> "$LOG_FILE"


# ==============================================================================
# [로그 파일 용량 관리] 최대 10MB 크기 제한 및 최대 10개 파일 순환 유지 (Bug Fixed)
# ==============================================================================
if [ -f "$LOG_FILE" ]; then
    FILE_SIZE=$(wc -c < "$LOG_FILE")
    MAX_SIZE=$((10 * 1024 * 1024)) # 10MB (바이트 단위)
    MAX_FILES=10

    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        # 1. 가장 오래된 10번째 백업 파일(monitor.log.10)이 존재하면 삭제하여 10개 제한 유지
        if [ -f "${LOG_FILE}.${MAX_FILES}" ]; then
            rm "${LOG_FILE}.${MAX_FILES}"
        fi

        # 2. 기존 백업 파일들의 이름을 역순으로 하나씩 뒤로 밀기 (9 -> 10, 8 -> 9, ..., 1 -> 2)
        for i in $(seq $((MAX_FILES - 1)) -1 1); do
            if [ -f "${LOG_FILE}.$i" ]; then
                mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i + 1))"
            fi
        done

        # 3. 현재 10MB를 초과한 활성 로그 파일을 첫 번째 백업 파일(monitor.log.1)로 변경
        mv "$LOG_FILE" "${LOG_FILE}.1"

        # 4. 다음 로그 수집을 위한 새 로그 파일 생성 및 미션 명세 권한 부여
        touch "$LOG_FILE"
        chown root:agent-core "$LOG_FILE"
        chmod 660 "$LOG_FILE"
    fi
fi