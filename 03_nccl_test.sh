#!/bin/bash
# Modulo 3: Teste de Comunicacao NCCL (AllReduce) - Versao Universal (v12 - criterio de aprovacao + CUDA/NCCL do Modulo 1 + rodadas com e sem P2P)

set -eo pipefail

BASE_DIR="$HOME/homologacao"

ensure_dir() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        mkdir -p "$dir_path" || exit 1
    fi
}

ensure_dir "$BASE_DIR/benchmark"
ensure_dir "$BASE_DIR/logs"

LOG_FILE="$BASE_DIR/logs/03_nccl_log_de_execucao.txt"
> "$LOG_FILE"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "--- Iniciando Script de Teste NCCL (Modo Universal v12) ---"

# CUDA Toolkit e NCCL sao instalados pelo Modulo 1 (versoes alinhadas ao driver)
CUDA_HOME=/usr/local/cuda
if [ ! -x "$CUDA_HOME/bin/nvcc" ] || ! dpkg -s libnccl-dev >/dev/null 2>&1; then
    log "ERRO: CUDA Toolkit ($CUDA_HOME) ou NCCL (libnccl-dev) ausentes. Execute o Modulo 1 primeiro."
    exit 1
fi
log "CUDA: $("$CUDA_HOME/bin/nvcc" --version | grep -oE 'release [0-9.]+' || true) | NCCL: $(dpkg-query -W -f='${Version}' libnccl2 2>/dev/null || true)"

MISSING_PKGS=""
for pkg in git make; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS $pkg"
done
if [ -n "$MISSING_PKGS" ]; then
    sudo apt-get update -y &>/dev/null || log "AVISO: apt-get update falhou; seguindo com os repositorios atuais."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING_PKGS &>> "$LOG_FILE"
fi

export PATH=$CUDA_HOME/bin:$PATH

# Versao do nccl-tests: commit ou tag a fixar. Vazio = ramo principal (o commit usado fica registrado no resumo).
NCCL_TESTS_REF=""

cd "$BASE_DIR/benchmark"
if [ ! -d "nccl-tests" ]; then
    git clone https://github.com/NVIDIA/nccl-tests.git &>> "$LOG_FILE"
fi

cd nccl-tests
git fetch --all --tags &>> "$LOG_FILE" || log "AVISO: git fetch falhou; usando a copia local do nccl-tests."
if [ -n "$NCCL_TESTS_REF" ]; then
    if ! git checkout -q "$NCCL_TESTS_REF" &>> "$LOG_FILE"; then
        log "ERRO: referencia '$NCCL_TESTS_REF' do nccl-tests nao encontrada."
        exit 1
    fi
else
    DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    git checkout -q "${DEFAULT_BRANCH:-master}" &>> "$LOG_FILE" || true
    git pull --ff-only &>> "$LOG_FILE" || true
fi
NCCL_TESTS_COMMIT=$(git rev-parse --short HEAD)
log "nccl-tests: commit $NCCL_TESTS_COMMIT (referencia: ${NCCL_TESTS_REF:-ramo principal})"

# Forca compilacao SEM MPI. 
# Como o teste e local (8 GPUs na mesma placa mae), o MPI causa mais problemas do que ajuda na compilacao.
log "Compilando nccl-tests (Modo Single-Node, sem MPI)..."
# Compila explicitamente para Blackwell (sm_120) usando o CUDA e a NCCL instalados pelo Modulo 1
if make clean &>> "$LOG_FILE" && make CUDA_HOME="$CUDA_HOME" NCCL_HOME=/usr NVCC_GENCODE="-gencode=arch=compute_120,code=sm_120" &>> "$LOG_FILE"; then
    log "Compilacao concluida com sucesso."
else
    log "ERRO: Falha na compilacao. Verifique o log: $LOG_FILE"
    exit 1
fi

# Banda minima aceitavel: busbw (GB/s) da maior mensagem testada na rodada oficial (P2P desabilitado).
# 0 = apenas registra a banda, sem reprovar por desempenho (reprova somente por corrupcao de dados).
MIN_BUSBW_GBPS=0
# Tempo maximo da rodada de diagnostico com P2P habilitado (pode travar em plataformas com ACS/IOMMU)
P2P_TIMEOUT=600

NCCL_OUT_P2P="$BASE_DIR/benchmark/nccl_allreduce_p2p.txt"
NCCL_OUT="$BASE_DIR/benchmark/nccl_allreduce_nop2p.txt"
NCCL_SUMMARY="$BASE_DIR/benchmark/nccl_resumo.txt"
MOTIVOS=()

# Le uma saida do all_reduce_perf e preenche A_PEAK, A_WRONG, A_OOB, A_AVG e A_INTEG
analyze_nccl() {
    local f="$1"
    # Localiza as colunas pelo cabecalho (busbw fora-do-lugar e todas as colunas #wrong)
    read -r A_PEAK A_WRONG < <(awk '
        /#wrong/ && !h { for (i = 1; i <= NF; i++) { if ($i == "busbw" && !bw) bw = i - 1; if ($i == "#wrong") w[++n] = i - 1 } h = 1; next }
        h && $1 ~ /^[0-9]+$/ { last = $bw; for (k = 1; k <= n; k++) if ($w[k] ~ /^[0-9]+$/ && $w[k] + 0 > 0) bad++ }
        END { printf "%s %d\n", (last == "" ? "NA" : last), bad + 0 }' "$f")
    A_OOB=$(grep -E "^# *Out of bounds values" "$f" || true)
    A_AVG=$(grep -E "^# *Avg bus bandwidth" "$f" | awk -F: '{gsub(/ /, "", $2); print $2}' || true)
    if [ -z "$A_OOB" ]; then
        A_INTEG="NAO VERIFICADA"
    elif ! echo "$A_OOB" | grep -qE ":[[:space:]]*0[[:space:]]+OK" || [ "$A_WRONG" -gt 0 ]; then
        A_INTEG="CORROMPIDA"
    else
        A_INTEG="OK"
    fi
}

# ==============================================================================
# Rodada 1/2: P2P habilitado (diagnostico - travamento/indisponibilidade apenas registrados)
# ==============================================================================
log "Rodada 1/2: all_reduce_perf com P2P habilitado (diagnostico, timeout ${P2P_TIMEOUT}s)..."
P2P_RC=0
env -u NCCL_P2P_DISABLE timeout -k 30 "$P2P_TIMEOUT" ./build/all_reduce_perf -b 8 -e 4G -f 2 -g 8 2>&1 | tee "$NCCL_OUT_P2P" || P2P_RC=$?

P2P_BUSBW="N/A"
if [ "$P2P_RC" -eq 124 ] || [ "$P2P_RC" -eq 137 ]; then
    P2P_STATUS="INDISPONIVEL (travou e foi encerrado apos ${P2P_TIMEOUT}s)"
elif [ "$P2P_RC" -ne 0 ]; then
    P2P_STATUS="INDISPONIVEL (falhou com codigo $P2P_RC)"
else
    analyze_nccl "$NCCL_OUT_P2P"
    P2P_BUSBW="$A_PEAK"
    case "$A_INTEG" in
        CORROMPIDA)
            P2P_STATUS="CONCLUIDO COM CORRUPCAO DE DADOS"
            MOTIVOS+=("Corrupcao de dados entre GPUs na rodada com P2P: ${A_OOB:-sem linha de verificacao}; $A_WRONG tamanho(s) de mensagem com #wrong > 0.") ;;
        "NAO VERIFICADA")
            P2P_STATUS="INCOMPLETO (saida sem linha de verificacao)" ;;
        *)
            P2P_STATUS="OK (0 valores incorretos)" ;;
    esac
fi
log "Rodada 1/2 (P2P habilitado): $P2P_STATUS | busbw da maior mensagem: $P2P_BUSBW GB/s"

# ==============================================================================
# Rodada 2/2: P2P desabilitado (criterio oficial de aprovacao)
# ==============================================================================
log "Rodada 2/2: all_reduce_perf com P2P desabilitado (criterio oficial)..."
if NCCL_P2P_DISABLE=1 ./build/all_reduce_perf -b 8 -e 4G -f 2 -g 8 | tee "$NCCL_OUT"; then
    log "Rodada 2/2 executada ate o fim."
else
    log "ERRO: Falha na execucao do all_reduce_perf (P2P desabilitado)."
    exit 1
fi

log "--- Avaliacao do resultado NCCL ---"
analyze_nccl "$NCCL_OUT"
PEAK_BUSBW="$A_PEAK"
AVG_BUSBW="$A_AVG"
case "$A_INTEG" in
    "NAO VERIFICADA")
        MOTIVOS+=("Teste incompleto (P2P desabilitado): linha 'Out of bounds values' ausente na saida.")
        INTEGRIDADE="NAO VERIFICADA" ;;
    CORROMPIDA)
        MOTIVOS+=("Corrupcao de dados entre GPUs (P2P desabilitado): $A_OOB; $A_WRONG tamanho(s) de mensagem com #wrong > 0.")
        INTEGRIDADE="CORROMPIDA" ;;
    *)
        INTEGRIDADE="OK (0 valores incorretos)" ;;
esac

if ! [[ "$PEAK_BUSBW" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    MOTIVOS+=("Nao foi possivel ler a banda (busbw) da maior mensagem.")
elif awk -v b="$PEAK_BUSBW" -v m="$MIN_BUSBW_GBPS" 'BEGIN { exit !(m > 0 && b < m) }'; then
    MOTIVOS+=("Banda abaixo do minimo: $PEAK_BUSBW GB/s < $MIN_BUSBW_GBPS GB/s.")
fi

if [ "${#MOTIVOS[@]}" -eq 0 ]; then RESULT="APROVADO"; else RESULT="REPROVADO"; fi

{
    echo "=================================================="
    echo "RESUMO DO TESTE NCCL (all_reduce_perf)"
    echo "Host: $(hostname) | Data: $(date)"
    echo "GPUs: 8 | nccl-tests: commit $NCCL_TESTS_COMMIT (referencia: ${NCCL_TESTS_REF:-ramo principal})"
    echo "Rodada 1 - P2P habilitado (diagnostico, nao reprova se indisponivel):"
    echo "  Status: $P2P_STATUS"
    echo "  Banda (busbw) da maior mensagem: $P2P_BUSBW GB/s"
    echo "Rodada 2 - P2P desabilitado (criterio oficial):"
    echo "  Banda (busbw) da maior mensagem: $PEAK_BUSBW GB/s (minimo exigido: $MIN_BUSBW_GBPS GB/s; 0 = sem limite)"
    echo "  Banda media (Avg bus bandwidth): ${AVG_BUSBW:-N/A} GB/s"
    echo "  Integridade dos dados: $INTEGRIDADE"
    echo "RESULTADO: $RESULT"
    for m in "${MOTIVOS[@]}"; do echo "  - $m"; done
    echo "=================================================="
} > "$NCCL_SUMMARY"

while IFS= read -r line; do log "$line"; done < "$NCCL_SUMMARY"

if [ "$RESULT" = "REPROVADO" ]; then
    exit 3
fi
