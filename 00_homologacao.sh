#!/bin/bash
# Modulo 0: Orquestrador da Homologacao (v2 - execucao direto do GitHub)
# Executa todos os modulos no fluxo recomendado (mesmo que algum falhe), coleta as metricas e
# gera o relatorio APROVADO/REPROVADO com um pacote de todos os arquivos da execucao.
# Se os modulos 01-05 nao estiverem no mesmo diretorio, baixa-os do repositorio GitHub.
#
# Uso direto da nuvem (recomendado dentro de tmux/screen: a bateria completa leva varias horas):
#   curl -fsSL https://raw.githubusercontent.com/ju-lindo-castro/GPU-Homolog/main/00_homologacao.sh | sudo bash -s -- -t <HF_TOKEN>
# Uso local:
#   ./00_homologacao.sh -t <HF_TOKEN> [-b <branch/tag>]

# Todo o script fica dentro deste bloco: o bash le o arquivo inteiro antes de executar,
# o que torna seguro rodar via "curl ... | sudo bash"
{

# ==============================================================================
# Configuracao
# ==============================================================================
DCGM_LEVEL=4
EXPECTED_GPUS=8
EXPECTED_PCIE_GEN=5
MAX_GPU_TEMP_C=90                         # temperatura maxima aceitavel da GPU no burn-in
LOAD_UTIL_PCT=50                          # amostras com uso >= este valor contam como "sob carga"
CRITICAL_XIDS="48 61 62 63 64 74 79 92 94 95 119 120 154"

# Repositorio de onde os modulos sao baixados quando nao estao no mesmo diretorio
REPO_RAW="${GPU_HOMOLOG_RAW:-https://raw.githubusercontent.com/ju-lindo-castro/GPU-Homolog}"
REPO_REF="main"
MODULES="01_inventario.sh 02_dcgm_diag_completo.sh 03_nccl_test.sh 04_telemetria.sh 05_vllm_benchmark.sh"

usage() { echo "Uso: 00_homologacao.sh -t <HF_TOKEN> [-b <branch/tag>]"; exit 1; }

HF_TOKEN_ARG=""
while getopts ":t:b:h" opt; do
    case "$opt" in
        t) HF_TOKEN_ARG="$OPTARG" ;;
        b) REPO_REF="$OPTARG" ;;
        *) usage ;;
    esac
done
if [ -z "$HF_TOKEN_ARG" ]; then
    echo "ERRO: o token do Hugging Face e obrigatorio (-t)."
    usage
fi

# Roda como root do comeco ao fim (sem depender do cache do sudo durante horas)
if [ "$EUID" -ne 0 ]; then
    if [ -f "$0" ]; then
        exec sudo "$0" "$@"
    fi
    echo "ERRO: execute como root. Exemplo: curl -fsSL $REPO_RAW/$REPO_REF/00_homologacao.sh | sudo bash -s -- -t <HF_TOKEN>"
    exit 1
fi

# Garante USER definido (pode vir vazio em cron/ambientes minimos); os modulos 2 e 4 tambem dependem dele
export USER="${USER:-$(id -un)}"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
BASE_DIR="$REAL_HOME/homologacao"
HOST=$(hostname)
TS=$(date +%Y%m%d_%H%M%S)
REPORT_DIR="$BASE_DIR/relatorios"
REPORT="$REPORT_DIR/relatorio_${HOST}_${TS}.txt"
ORCH_LOG="$REPORT_DIR/00_orquestrador_${HOST}_${TS}.log"
TARBALL="$REPORT_DIR/homologacao_${HOST}_${TS}.tar.gz"
STAMP="$REPORT_DIR/.inicio_${TS}"
mkdir -p "$REPORT_DIR"
touch "$STAMP"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$ORCH_LOG"; }
fmt_dur() { printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }
# Arquivo mais recente de um padrao, gerado nesta execucao
newest() { find "$1" -maxdepth 1 -name "$2" -newer "$STAMP" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-; }

# ==============================================================================
# Localiza os modulos: mesmo diretorio do orquestrador ou download do GitHub
# ==============================================================================
SCRIPT_DIR=""
if [ -f "$0" ]; then
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
    for m in $MODULES; do [ -f "$SCRIPT_DIR/$m" ] || SCRIPT_DIR=""; done
fi
if [ -n "$SCRIPT_DIR" ]; then
    chmod +x "$SCRIPT_DIR"/0[1-5]_*.sh 2>/dev/null
    log "Modulos locais encontrados em $SCRIPT_DIR"
else
    SCRIPT_DIR="$BASE_DIR/scripts"
    mkdir -p "$SCRIPT_DIR"
    log "Baixando os modulos de $REPO_RAW/$REPO_REF para $SCRIPT_DIR ..."
    for m in $MODULES; do
        if curl -fsSL --retry 3 "$REPO_RAW/$REPO_REF/$m" -o "$SCRIPT_DIR/$m.tmp" 2>>"$ORCH_LOG" \
            || wget -q --tries=3 "$REPO_RAW/$REPO_REF/$m" -O "$SCRIPT_DIR/$m.tmp" 2>>"$ORCH_LOG"; then
            mv "$SCRIPT_DIR/$m.tmp" "$SCRIPT_DIR/$m"
            chmod +x "$SCRIPT_DIR/$m"
            log "  $m baixado."
        else
            rm -f "$SCRIPT_DIR/$m.tmp"
            log "ERRO: nao foi possivel baixar $m de $REPO_RAW/$REPO_REF (repositorio privado ou sem acesso a internet?)."
            exit 1
        fi
    done
fi

declare -A ST_STATUS ST_DUR ST_DESC
STAGES=()
MOTIVOS=()
AVISOS=()
START_EPOCH=$(date +%s)
TELEMETRY_ON=false

# Executa um modulo, mostra a saida na tela e grava no log do orquestrador. Retorna o codigo do modulo.
run_stage() {
    local id="$1" desc="$2" t0 rc
    shift 2
    STAGES+=("$id"); ST_DESC[$id]="$desc"
    log "=================================================="
    log "ETAPA $id: $desc - Iniciada"
    t0=$(date +%s)
    ( cd "$SCRIPT_DIR" && HOME="$REAL_HOME" HF_TOKEN="$HF_TOKEN_ARG" "$@" ) < /dev/null 2>&1 | tee -a "$ORCH_LOG"
    rc=${PIPESTATUS[0]}
    ST_DUR[$id]=$(($(date +%s) - t0))
    log "ETAPA $id: $desc - Finalizada (codigo $rc, duracao $(fmt_dur "${ST_DUR[$id]}"))"
    return "$rc"
}

stop_telemetry() {
    if [ "$TELEMETRY_ON" = true ]; then
        "$SCRIPT_DIR/04_telemetria.sh" stop 2>&1 | tee -a "$ORCH_LOG"
        TELEMETRY_ON=false
    fi
}
trap 'log "Orquestrador interrompido pelo usuario."; stop_telemetry; chown -R "$REAL_USER": "$BASE_DIR" 2>/dev/null; exit 130' INT TERM

log "--- Homologacao iniciada em $HOST ---"

# ==============================================================================
# Etapa 1: Inventario e auditoria de hardware
# ==============================================================================
run_stage 1 "Inventario e auditoria de hardware" ./01_inventario.sh
RC=$?
INV_LOG="$BASE_DIR/01_inventario_log_de_execucao.txt"
INV_ALERTS=$(grep "ALERTA CRITICO" "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] //')
if [ "$RC" -ne 0 ]; then
    ST_STATUS[1]="FALHOU"; MOTIVOS+=("Inventario: o modulo terminou com codigo $RC (ver log).")
elif [ -n "$INV_ALERTS" ]; then
    ST_STATUS[1]="REPROVADO"
    while IFS= read -r a; do MOTIVOS+=("Inventario: $a"); done <<< "$INV_ALERTS"
else
    ST_STATUS[1]="APROVADO"
fi
while IFS= read -r e; do [ -n "$e" ] && AVISOS+=("Inventario: $e"); done < <(grep -E " - Erro:| - Aviso:" "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] //')

# ==============================================================================
# Etapa 2: Telemetria (inicio)
# ==============================================================================
"$SCRIPT_DIR/04_telemetria.sh" stop >/dev/null 2>&1   # encerra uma telemetria manual esquecida, se houver
if run_stage 2 "Telemetria (inicio)" ./04_telemetria.sh start; then
    ST_STATUS[2]="OK"; TELEMETRY_ON=true
    { read -r TEL_CSV; read -r TEL_KLOG; } < /run/homologacao-telemetria.files
else
    ST_STATUS[2]="FALHOU"
    MOTIVOS+=("Telemetria nao iniciou: temperatura, throttling e PCIe sob carga nao puderam ser verificados.")
fi

# ==============================================================================
# Etapa 3: Diagnostico DCGM
# ==============================================================================
run_stage 3 "Diagnostico DCGM (niveis 1 a $DCGM_LEVEL)" ./02_dcgm_diag_completo.sh "$DCGM_LEVEL"
RC=$?
DCGM_LOG=$(newest "$BASE_DIR/dcgm" "diag_execucao_*.log")
case "$RC" in
    0) ST_STATUS[3]="APROVADO" ;;
    2) ST_STATUS[3]="REPROVADO"; MOTIVOS+=("DCGM: GPU caiu do barramento ou exige reboot (codigo 2).") ;;
    3) ST_STATUS[3]="REPROVADO"; MOTIVOS+=("DCGM: hardware reprovado no diagnostico (codigo 3). Detalhes na secao DCGM.") ;;
    *) ST_STATUS[3]="FALHOU";    MOTIVOS+=("DCGM: erro de software/utilitario (codigo $RC); diagnostico incompleto.") ;;
esac

# ==============================================================================
# Etapa 4: NCCL
# ==============================================================================
run_stage 4 "Teste NCCL (AllReduce, com e sem P2P)" ./03_nccl_test.sh
RC=$?
NCCL_SUM="$BASE_DIR/benchmark/nccl_resumo.txt"
[ "$NCCL_SUM" -nt "$STAMP" ] || NCCL_SUM=""
case "$RC" in
    0) ST_STATUS[4]="APROVADO" ;;
    3) ST_STATUS[4]="REPROVADO"
       while IFS= read -r a; do MOTIVOS+=("NCCL: ${a#  - }"); done < <(grep "^  - " "${NCCL_SUM:-/dev/null}") ;;
    *) ST_STATUS[4]="FALHOU"; MOTIVOS+=("NCCL: erro de execucao (codigo $RC); teste incompleto.") ;;
esac

# ==============================================================================
# Etapa 5: Benchmark vLLM
# ==============================================================================
run_stage 5 "Benchmark de inferencia vLLM" ./05_vllm_benchmark.sh
RC=$?
VLLM_SUM=$(newest "$BASE_DIR/benchmark" "vllm_resumo_*.txt")
if [ "$RC" -eq 0 ]; then
    ST_STATUS[5]="APROVADO"
else
    ST_STATUS[5]="FALHOU"; MOTIVOS+=("vLLM: o benchmark falhou (codigo $RC). Ver log completo em $BASE_DIR/logs.")
fi
VLLM_TPUT=$(grep -i "Throughput" "${VLLM_SUM:-/dev/null}" 2>/dev/null | tail -n1 | sed 's/^ *//')

# ==============================================================================
# Etapa 6: Telemetria (fim) e analise do burn-in
# ==============================================================================
if [ "$TELEMETRY_ON" = true ]; then
    STAGES+=(6); ST_DESC[6]="Telemetria (fim) e analise do burn-in"
    log "=================================================="
    log "ETAPA 6: ${ST_DESC[6]}"
    stop_telemetry
    ST_DUR[6]=0
    ST_STATUS[6]="APROVADO"

    # Uma linha por GPU: gpu tmax tmem n_amostras n_term n_hwslow n_brake n_swpower gen_max_carga n_carga ecc_max
    TEL_TABLE=$(awk -F', *' -v load="$LOAD_UTIL_PCT" '
        function hex2dec(h,   i, c, v) { h = tolower(h); sub(/^0x/, "", h); v = 0
            for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)); if (c == 0) return -1; v = v * 16 + c - 1 }
            return v }
        function bit(v, b) { return int(v / b) % 2 }
        function num(x) { return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        {
            g = $col["index"]; if (g == "") next
            seen[g] = 1; n[g]++
            if (("temperature.gpu" in col) && num($col["temperature.gpu"])) { v = $col["temperature.gpu"] + 0; if (!(g in tmax) || v > tmax[g]) tmax[g] = v }
            if (("temperature.memory" in col) && num($col["temperature.memory"])) { v = $col["temperature.memory"] + 0; if (!(g in tmem) || v > tmem[g]) tmem[g] = v }
            if ("clocks_event_reasons.active" in col) {
                r = hex2dec($col["clocks_event_reasons.active"])
                if (r > 0) {
                    if (bit(r, 32) || bit(r, 64)) term[g]++      # SW/HW Thermal Slowdown
                    if (bit(r, 8))  hws[g]++                      # HW Slowdown
                    if (bit(r, 128)) brk[g]++                     # HW Power Brake
                    if (bit(r, 4))  swp[g]++                      # SW Power Cap (normal sob carga plena)
                }
            }
            if (("utilization.gpu" in col) && num($col["utilization.gpu"]) && $col["utilization.gpu"] + 0 >= load) {
                nl[g]++
                if (("pcie.link.gen.current" in col) && num($col["pcie.link.gen.current"])) { v = $col["pcie.link.gen.current"] + 0; if (!(g in gen) || v > gen[g]) gen[g] = v }
            }
            if (("ecc.errors.uncorrected.volatile.total" in col) && num($col["ecc.errors.uncorrected.volatile.total"])) { v = $col["ecc.errors.uncorrected.volatile.total"] + 0; if (!(g in ecc) || v > ecc[g]) ecc[g] = v }
        }
        END { for (g in seen) printf "%s %s %s %d %d %d %d %d %s %d %s\n", g, (g in tmax ? tmax[g] : "NA"), (g in tmem ? tmem[g] : "NA"), n[g], term[g], hws[g], brk[g], swp[g], (g in gen ? gen[g] : "NA"), nl[g], (g in ecc ? ecc[g] : "NA") }
    ' "$TEL_CSV" 2>/dev/null | sort -n)

    if [ -z "$TEL_TABLE" ]; then
        ST_STATUS[6]="FALHOU"; MOTIVOS+=("Telemetria: nenhuma amostra coletada; burn-in nao verificado.")
    fi
    TEL_GPUS=0
    while read -r g tmax tmem ns nterm nhws nbrk nswp genmax nload eccmax; do
        [ -z "$g" ] && continue
        TEL_GPUS=$((TEL_GPUS + 1))
        if [ "$tmax" != "NA" ] && awk -v t="$tmax" -v m="$MAX_GPU_TEMP_C" 'BEGIN { exit !(t > m) }'; then
            ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g atingiu ${tmax} C (maximo aceitavel: $MAX_GPU_TEMP_C C).")
        fi
        if [ "$nterm" -gt 0 ]; then
            ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g com throttling termico em $nterm amostra(s).")
        fi
        if [ "$nhws" -gt 0 ] || [ "$nbrk" -gt 0 ]; then
            ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g com HW Slowdown/Power Brake em $((nhws + nbrk)) amostra(s) (energia ou sinal de hardware).")
        fi
        if [ "$nload" -eq 0 ] || [ "$genmax" = "NA" ]; then
            AVISOS+=("Telemetria: GPU $g sem amostras sob carga (>= ${LOAD_UTIL_PCT}% de uso); geracao PCIe sob carga nao verificada.")
        elif [ "$genmax" -lt "$EXPECTED_PCIE_GEN" ]; then
            ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g nao passou de PCIe Gen$genmax sob carga (esperado Gen$EXPECTED_PCIE_GEN).")
        fi
        if [ "$eccmax" != "NA" ] && [ "$eccmax" -gt 0 ]; then
            ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g com $eccmax erro(s) ECC nao corrigido(s).")
        fi
    done <<< "$TEL_TABLE"
    if [ -n "$TEL_TABLE" ] && [ "$TEL_GPUS" -lt "$EXPECTED_GPUS" ]; then
        ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: apenas $TEL_GPUS de $EXPECTED_GPUS GPUs apareceram nas amostras.")
    fi

    # Log do kernel (o coletor le o buffer desde o boot: inclui eventos anteriores aos testes)
    XID_SUMMARY=$(grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null | grep -oE "Xid \([^)]*\): [0-9]+" | awk '{print $NF}' | sort -n | uniq -c | awk '{printf "Xid %s (%sx)  ", $2, $1}')
    for x in $(grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null | grep -oE "Xid \([^)]*\): [0-9]+" | awk '{print $NF}' | sort -un); do
        if [[ " $CRITICAL_XIDS " == *" $x "* ]]; then
            ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Kernel: Xid critico $x registrado (ver log do kernel).")
        else
            AVISOS+=("Kernel: Xid $x registrado (nao critico; pode ter sido causado por aplicacao).")
        fi
    done
    if grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null | grep -qi "fallen off the bus"; then
        ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Kernel: GPU caiu do barramento (\"fallen off the bus\").")
    fi
    NSMI_HANGS=$(grep -c "\[telemetria\] ALERTA: nvidia-smi" "$TEL_KLOG" 2>/dev/null)
    if [ "${NSMI_HANGS:-0}" -gt 0 ]; then
        ST_STATUS[6]="REPROVADO"; MOTIVOS+=("Telemetria: nvidia-smi deixou de responder $NSMI_HANGS vez(es) (GPU travada ou caida).")
    fi
    log "ETAPA 6: ${ST_DESC[6]} - Finalizada (${ST_STATUS[6]})"
fi

# ==============================================================================
# Relatorio final
# ==============================================================================
END_EPOCH=$(date +%s)
if [ "${#MOTIVOS[@]}" -eq 0 ]; then VERDICT="APROVADO"; else VERDICT="REPROVADO"; fi

SYS_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | head -n1)
SYS_MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -n1)
SYS_SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | head -n1)
BIOS_VER=$(dmidecode -s bios-version 2>/dev/null | head -n1)
DRIVER_VER=$(grep -m1 "Driver Version" "$BASE_DIR/inventario/nvidia-smi-q.txt" 2>/dev/null | awk -F: '{gsub(/ /, "", $2); print $2}')
CUDA_VER=$(grep -oE "release [0-9.]+" "$BASE_DIR/inventario/cuda-version.txt" 2>/dev/null | awk '{print $2}')
NCCL_VER=$(awk '/^libnccl2 /{print $2}' "$BASE_DIR/inventario/nccl-version.txt" 2>/dev/null)
DCGM_VER=$(grep -m1 -i "version" "$BASE_DIR/inventario/dcgm-version.txt" 2>/dev/null | sed 's/^ *//')
VLLM_IMG=$(grep -m1 "^Imagem:" "${VLLM_SUM:-/dev/null}" 2>/dev/null | sed 's/^Imagem: //')
NCCLT_COMMIT=$(grep -m1 "nccl-tests: commit" "${NCCL_SUM:-/dev/null}" 2>/dev/null | sed 's/.*nccl-tests: //')

{
    echo "=================================================================="
    echo "RELATORIO DE HOMOLOGACAO - GPU SERVER"
    echo "=================================================================="
    echo "Host:      $HOST"
    echo "Servidor:  ${SYS_VENDOR:-?} ${SYS_MODEL:-?} | Serial: ${SYS_SERIAL:-?} | BIOS: ${BIOS_VER:-?}"
    echo "Inicio:    $(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S')"
    echo "Fim:       $(date -d "@$END_EPOCH" '+%Y-%m-%d %H:%M:%S') (duracao total: $(fmt_dur $((END_EPOCH - START_EPOCH))))"
    echo ""
    echo ">>> RESULTADO FINAL: $VERDICT <<<"
    if [ "${#MOTIVOS[@]}" -gt 0 ]; then
        echo "Motivos da reprovacao:"
        for m in "${MOTIVOS[@]}"; do echo "  - $m"; done
    fi
    if [ "${#AVISOS[@]}" -gt 0 ]; then
        echo "Avisos (nao reprovam):"
        for a in "${AVISOS[@]}"; do echo "  - $a"; done
    fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "ETAPAS"
    echo "------------------------------------------------------------------"
    for id in "${STAGES[@]}"; do
        printf "  [%-9s] %s. %-45s %s\n" "${ST_STATUS[$id]:-?}" "$id" "${ST_DESC[$id]}" "$(fmt_dur "${ST_DUR[$id]:-0}")"
    done
    echo ""
    echo "------------------------------------------------------------------"
    echo "HARDWARE (Modulo 1)"
    echo "------------------------------------------------------------------"
    grep -E "GPUs esperadas:|GPU [0-9]+ \(.*\): (OK|FALHA|ERRO)|Validacao de GPUs dentro do container|STATUS DO HARDWARE|ALERTA CRITICO" "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] /  /'
    echo ""
    echo "------------------------------------------------------------------"
    echo "DIAGNOSTICO DCGM (Modulo 2, nivel $DCGM_LEVEL)"
    echo "------------------------------------------------------------------"
    if [ -n "$DCGM_LOG" ]; then
        grep -E "\[FAIL\]|\[WARN |Motivacao:|REPROVADO|DIAGNOSTICO FINAL|concluido com sucesso|concluidos com sucesso|FALHA CRITICA" "$DCGM_LOG" | sed -E 's/^\[[^]]*\] /  /'
    else
        echo "  (log do diagnostico nao encontrado)"
    fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "NCCL (Modulo 3)"
    echo "------------------------------------------------------------------"
    if [ -n "$NCCL_SUM" ]; then grep -v "^=====" "$NCCL_SUM" | sed 's/^/  /'; else echo "  (resumo do NCCL nao encontrado)"; fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "INFERENCIA vLLM (Modulo 5) - throughput apenas registrado"
    echo "------------------------------------------------------------------"
    echo "  ${VLLM_TPUT:-(throughput nao encontrado)}"
    echo ""
    echo "------------------------------------------------------------------"
    echo "TELEMETRIA DO BURN-IN (Modulo 4) - limite: ${MAX_GPU_TEMP_C} C"
    echo "------------------------------------------------------------------"
    if [ -n "${TEL_TABLE:-}" ]; then
        printf "  %-4s %-9s %-9s %-9s %-11s %-11s %-12s %-9s\n" "GPU" "Temp max" "Mem max" "Amostras" "Thr.termico" "HW slow/brk" "PCIe (carga)" "ECC n/c"
        while read -r g tmax tmem ns nterm nhws nbrk nswp genmax nload eccmax; do
            printf "  %-4s %-9s %-9s %-9s %-11s %-11s %-12s %-9s\n" "$g" "${tmax}C" "${tmem}C" "$ns" "$nterm" "$((nhws + nbrk))" "Gen$genmax" "$eccmax"
        done <<< "$TEL_TABLE"
        echo "  Eventos Xid no log do kernel (desde o boot): ${XID_SUMMARY:-nenhum}"
    else
        echo "  (telemetria indisponivel)"
    fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "VERSOES"
    echo "------------------------------------------------------------------"
    echo "  Driver NVIDIA: ${DRIVER_VER:-?} | CUDA: ${CUDA_VER:-?} | NCCL: ${NCCL_VER:-?}"
    echo "  DCGM: ${DCGM_VER:-?}"
    echo "  vLLM: ${VLLM_IMG:-?}"
    echo "  nccl-tests: ${NCCLT_COMMIT:-?}"
    echo ""
    echo "Arquivos completos: $TARBALL"
    echo "=================================================================="
} > "$REPORT"

cat "$REPORT" | tee -a "$ORCH_LOG"

# ==============================================================================
# Pacote com todos os arquivos desta execucao (sem dataset e sem codigo do nccl-tests)
# ==============================================================================
( cd "$BASE_DIR" && find 01_inventario_log_de_execucao.txt inventario dcgm stress benchmark logs relatorios \
      -type f -newer "$STAMP" ! -path 'benchmark/nccl-tests/*' ! -name 'ShareGPT*' ! -name '*.tar.gz' 2>/dev/null \
  | tar -czf "$TARBALL" -T - ) 2>>"$ORCH_LOG"
chown -R "$REAL_USER": "$BASE_DIR" 2>/dev/null
[ -d "$REAL_HOME/.cache/huggingface" ] && chown -R "$REAL_USER": "$REAL_HOME/.cache/huggingface" 2>/dev/null

rm -f "$STAMP"
chown -R "$REAL_USER": "$REPORT_DIR" 2>/dev/null

log "Relatorio: $REPORT"
log "Pacote com todos os arquivos: $TARBALL"
log "--- Homologacao concluida: $VERDICT ---"
[ "$VERDICT" = "APROVADO" ] && exit 0 || exit 3
}
