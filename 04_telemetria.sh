#!/bin/bash
# Modulo 4: Telemetria em Background - Versao Universal (v9 - start/stop/status, log de kernel continuo, timeout e metricas estendidas)
# Uso: ./04_telemetria.sh start | stop | status

# Garante execucao como root: necessario para ler o dmesg (Ubuntu restringe a usuarios comuns)
# e para nao depender do cache do sudo (~15 min) durante a coleta prolongada
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Mantem os arquivos na home do usuario que chamou o script, mesmo rodando como root
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
BASE_DIR="$REAL_HOME/homologacao"
STRESS_DIR="$BASE_DIR/stress"

PID_FILE="/run/homologacao-telemetria.pid"
STATE_FILE="/run/homologacao-telemetria.files"
INTERVAL=5

# Metricas desejadas. As que o driver/GPU nao suportar sao descartadas na inicializacao.
METRICS="index,temperature.gpu,temperature.memory,power.draw,power.limit,utilization.gpu,utilization.memory,memory.used,clocks.sm,clocks.mem,clocks_event_reasons.active,pcie.link.gen.current,pcie.link.width.current,ecc.errors.uncorrected.volatile.total"
BASIC_METRICS="index,temperature.gpu,power.draw,utilization.gpu,utilization.memory"

now() { date +'%Y-%m-%d %H:%M:%S'; }

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# ==============================================================================
# Coletor (roda em background, iniciado pelo 'start')
# ==============================================================================
run_collector() {
    local csv="$1" klog="$2" fields="" f out rc ts kpid

    echo "[$(now)] [telemetria] Iniciada (PID $$). Intervalo: ${INTERVAL}s." >> "$klog"

    # Valida cada metrica individualmente: um campo nao suportado derrubaria a consulta inteira
    for f in ${METRICS//,/ }; do
        if timeout 10 nvidia-smi --query-gpu="$f" --format=csv,noheader >/dev/null 2>&1; then
            fields="${fields:+$fields,}$f"
        else
            echo "[$(now)] [telemetria] Metrica '$f' nao suportada neste driver/GPU; descartada." >> "$klog"
        fi
    done
    if [ -z "$fields" ]; then
        fields="$BASIC_METRICS"
        echo "[$(now)] [telemetria] ALERTA: nvidia-smi nao respondeu na inicializacao; usando metricas basicas." >> "$klog"
    fi
    echo "timestamp,$fields" > "$csv"

    # Coletor continuo do log do kernel: acrescenta cada evento (nunca sobrescreve)
    ( dmesg -wT 2>&1 | grep --line-buffered -iE "NVRM|Xid|PCIe Bus Error|GPU has fallen off the bus|AER" >> "$klog" ) &
    kpid=$!

    # Encerramento limpo ao receber TERM/INT (enviado pelo 'stop')
    trap 'pkill -P "$kpid" 2>/dev/null; kill "$kpid" 2>/dev/null; echo "[$(now)] [telemetria] Encerrada." >> "$klog"; rm -f "$PID_FILE" "$STATE_FILE"; exit 0' TERM INT

    while true; do
        ts=$(now)
        out=$(timeout 10 nvidia-smi --query-gpu="$fields" --format=csv,noheader,nounits 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            while IFS= read -r line; do
                echo "$ts,$line" >> "$csv"
            done <<< "$out"
        elif [ "$rc" -eq 124 ]; then
            echo "[$ts] [telemetria] ALERTA: nvidia-smi nao respondeu em 10s (possivel GPU travada ou caida do barramento)." >> "$klog"
        else
            echo "[$ts] [telemetria] ALERTA: nvidia-smi falhou (rc=$rc): $(echo "$out" | tr '\n' ' ' | head -c 200)" >> "$klog"
        fi
        # 'sleep & wait' permite que o TERM seja tratado imediatamente
        sleep "$INTERVAL" & wait $!
    done
}

# ==============================================================================
# Comandos
# ==============================================================================
cmd_start() {
    if is_running; then
        echo "Telemetria ja esta em execucao (PID $(cat "$PID_FILE")). Use '$0 stop' antes de iniciar outra."
        exit 1
    fi
    mkdir -p "$STRESS_DIR"
    local ts csv klog
    ts=$(date +'%Y%m%d_%H%M%S')
    csv="$STRESS_DIR/04_telemetria_${ts}.csv"
    klog="$STRESS_DIR/04_kernel_${ts}.log"
    : > "$csv"
    : > "$klog"
    chown "$REAL_USER": "$BASE_DIR" "$STRESS_DIR" "$csv" "$klog"

    nohup setsid "$0" _run "$csv" "$klog" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
    printf '%s\n%s\n' "$csv" "$klog" > "$STATE_FILE"

    sleep 2
    if is_running; then
        echo "Telemetria iniciada em background (PID $(cat "$PID_FILE"))."
        echo "  Metricas (CSV): $csv"
        echo "  Log do kernel:  $klog"
    else
        echo "ERRO: a telemetria nao iniciou. Verifique $klog"
        rm -f "$PID_FILE" "$STATE_FILE"
        exit 1
    fi
}

cmd_stop() {
    if ! is_running; then
        echo "Telemetria nao esta em execucao."
        rm -f "$PID_FILE" "$STATE_FILE"
        exit 0
    fi
    local pid files
    pid=$(cat "$PID_FILE")
    files=$(cat "$STATE_FILE" 2>/dev/null)
    kill -TERM "$pid"
    for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        pkill -KILL -s "$pid" 2>/dev/null
        echo "Aviso: a telemetria nao respondeu ao encerramento normal e foi finalizada a forca."
    fi
    # Garante que nenhum processo da sessao da telemetria (ex.: coletor do dmesg) fique orfao
    pkill -KILL -s "$pid" 2>/dev/null
    rm -f "$PID_FILE" "$STATE_FILE"
    echo "Telemetria encerrada. Arquivos gerados:"
    echo "$files" | sed 's/^/  /'
}

cmd_status() {
    if is_running; then
        local csv klog
        { read -r csv; read -r klog; } < "$STATE_FILE"
        echo "Telemetria EM EXECUCAO (PID $(cat "$PID_FILE"))."
        echo "  Metricas (CSV): $csv ($(($(wc -l < "$csv") - 1)) amostras)"
        echo "  Log do kernel:  $klog ($(grep -vc '\[telemetria\]' "$klog") eventos do kernel)"
    else
        echo "Telemetria PARADA."
    fi
}

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    _run)   run_collector "$2" "$3" ;;
    *)      echo "Uso: $0 {start|stop|status}"; exit 1 ;;
esac
