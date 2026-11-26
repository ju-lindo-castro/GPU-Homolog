#!/bin/bash
# Modulo 0: Orquestrador da Homologacao (v8 - plataforma nao pronta e configuracao separadas de hardware (INCONCLUSIVO) + eventos do BMC + execucao direto do GitHub + instalacao do driver com reboot + PCIe pelo maximo da GPU + diagnostico de P2P/IOMMU + GPU em falha e consequencias + DCGM em triagem/estresse + linha do tempo)
# Executa os modulos no fluxo recomendado: inventario, telemetria, DCGM triagem (niveis 1-2), NCCL,
# vLLM e DCGM estresse (niveis 3-4). Uma falha de teste nao interrompe a bateria; so quando uma GPU
# entra em falha (travada ou fora do barramento) as etapas seguintes deixam de ser executadas.
# Ao final gera o relatorio APROVADO/REPROVADO/INCONCLUSIVO, com linha do tempo, e um pacote de todos os arquivos.
# ATENCAO: altera o sistema (pacotes, servicos, kernel e reboot). Use somente em servidor dedicado ao teste,
# reinstalado antes e depois da homologacao.
# Se os modulos 01-05 nao estiverem no mesmo diretorio, baixa-os do repositorio GitHub.
# Se o driver NVIDIA estiver ausente, o Modulo 1 o instala e o servidor e REINICIADO (com aviso);
# depois do reboot, basta executar o mesmo comando novamente.
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
DCGM_LEVEL=4                              # nivel maximo do DCGM (a etapa de estresse roda os niveis acima da triagem)
DCGM_TRIAGE_LEVEL=2                       # niveis 1..N rodam no inicio, como triagem rapida, antes do NCCL e do vLLM
EXPECTED_GPUS=8
EXPECTED_PCIE_GEN=5                       # usado so se o driver nao informar a geracao maxima de cada GPU
MAX_GPU_TEMP_C=90                         # temperatura maxima aceitavel da GPU no burn-in
LOAD_UTIL_PCT=50                          # amostras com uso >= este valor contam como "sob carga"
REBOOT_COUNTDOWN=60                       # segundos de aviso antes do reboot apos instalar o driver
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
# Identifica uma GPU pelo endereco PCI (ex.: 0000:21:00) usando o inventario coletado no inicio
gpu_id_from_pci() {
    local key idx serial
    key=$(echo "$1" | tr 'A-F' 'a-f' | sed -E 's/^[0-9a-f]+:([0-9a-f]{2}:[0-9a-f]{2}).*/\1/')
    idx=$(awk -F', *' -v k=":$key" 'NR > 1 && index(tolower($3), k) {print $1; exit}' "$BASE_DIR/inventario/pcie_status.txt" 2>/dev/null)
    serial=$(awk -v k=":$key" 'tolower($0) ~ /^gpu [0-9a-f]+:/ {f = index(tolower($0), k) > 0} f && /^    Serial Number/ {sub(/.*: */, ""); print; exit}' "$BASE_DIR/inventario/nvidia-smi-q.txt" 2>/dev/null)
    echo "GPU ${idx:-?} (PCI $1, serial ${serial:-?})"
}
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

declare -A ST_STATUS ST_DUR ST_DESC ST_T0 ST_T1
STAGES=()
MOTIVOS=()
AVISOS=()
CONSEQ=()          # etapas e falhas causadas por uma GPU que ja estava em falha (nao sao problemas independentes)
PENDENCIAS=()      # etapas nao executadas por configuracao do ambiente (nao avaliam o hardware)
GPU_FAILED=false
FAIL_STAGE=""      # etapa em que a GPU entrou em falha (falha primaria)
FAIL_EPOCH=""      # quando a falha foi detectada
FAIL_DESC=""
START_EPOCH=$(date +%s)
TELEMETRY_ON=false

# Executa um modulo, mostra a saida na tela e grava no log do orquestrador. Retorna o codigo do modulo.
run_stage() {
    local id="$1" desc="$2" t0 rc
    shift 2
    STAGES+=("$id"); ST_DESC[$id]="$desc"
    log "=================================================="
    log "ETAPA $id: $desc - Iniciada"
    t0=$(date +%s); ST_T0[$id]=$t0
    ( cd "$SCRIPT_DIR" && HOME="$REAL_HOME" HF_TOKEN="$HF_TOKEN_ARG" HOMOLOG_ORQUESTRADOR=1 "$@" ) < /dev/null 2>&1 | tee -a "$ORCH_LOG"
    rc=${PIPESTATUS[0]}
    ST_T1[$id]=$(date +%s)
    ST_DUR[$id]=$((ST_T1[$id] - t0))
    log "ETAPA $id: $desc - Finalizada (codigo $rc, duracao $(fmt_dur "${ST_DUR[$id]}"))"
    return "$rc"
}

# Registra a falha primaria de GPU: as etapas seguintes nao sao executadas
mark_gpu_failure() {
    GPU_FAILED=true; FAIL_STAGE="$1"; FAIL_DESC="$2"; FAIL_EPOCH=$(date +%s)
}

# Etapa nao executada porque uma GPU ja estava em falha (evita horas de testes sobre hardware quebrado)
skip_stage() {
    local id="$1" desc="$2"
    STAGES+=("$id"); ST_DESC[$id]="$desc"; ST_STATUS[$id]="NAO EXECUTADO"; ST_DUR[$id]=0
    CONSEQ+=("$desc: nao executado porque a GPU entrou em falha na etapa $FAIL_STAGE (${ST_DESC[$FAIL_STAGE]}).")
    log "ETAPA $id: $desc - NAO EXECUTADA (GPU em falha desde a etapa $FAIL_STAGE)"
}

# Etapa nao executada por configuracao do ambiente (pacote ausente, token sem acesso etc.): nao avalia o hardware
skip_config_stage() {
    local id="$1" desc="$2" motivo="$3"
    STAGES+=("$id"); ST_DESC[$id]="$desc"; ST_STATUS[$id]="NAO EXECUTADO"; ST_DUR[$id]=0
    PENDENCIAS+=("$desc: $motivo")
    log "ETAPA $id: $desc - NAO EXECUTADA ($motivo)"
}

# Verifica a saude das GPUs depois de uma etapa (Modulo 2 --health). Retorna 1 se uma GPU entrou em falha.
post_stage_health() {
    local id="$1" name="$2" out rc diag
    log "Verificando a saude das GPUs apos a etapa $id..."
    out=$(cd "$SCRIPT_DIR" && HOME="$REAL_HOME" ./02_dcgm_diag_completo.sh --health 2>&1 < /dev/null); rc=$?
    echo "$out" | tee -a "$ORCH_LOG" >/dev/null
    case "$rc" in
        0) log "GPUs saudaveis apos a etapa $id."; return 0 ;;
        2) diag=$(echo "$out" | grep -m1 -oE "DIAGNOSTICO FINAL: .*" | sed -E 's/^DIAGNOSTICO FINAL: GPU\(s\) em falha: //; s/\.$//')
           echo "$out" | grep -E "FALHA CRITICA|GPU EM FALHA|DIAGNOSTICO FINAL" | sed -E 's/^\[[^]]*\] //' | while IFS= read -r l; do log "  $l"; done
           ST_STATUS[$id]="REPROVADO"
           MOTIVOS+=("$name: GPU entrou em falha durante a etapa: ${diag:-estado de GPU degradado} (reboot obrigatorio).")
           mark_gpu_failure "$id" "${diag:-estado de GPU degradado}"
           return 1 ;;
        *) AVISOS+=("$name: nao foi possivel verificar a saude das GPUs apos a etapa (codigo $rc).")
           return 0 ;;
    esac
}

# Avalia o resultado de uma execucao do Modulo 2 (triagem ou estresse)
eval_dcgm() {
    local id="$1" rc="$2" dlog="$3" name="$4" diag p2p iommu
    case "$rc" in
        0) ST_STATUS[$id]="APROVADO" ;;
        2) ST_STATUS[$id]="REPROVADO"
           diag=$(grep -m1 -oE "DIAGNOSTICO FINAL: .*" "$dlog" 2>/dev/null | sed 's/^DIAGNOSTICO FINAL: //; s/\.$//')
           MOTIVOS+=("$name: ${diag:-GPU caiu do barramento ou ficou pendente de reset} (codigo 2; reboot obrigatorio).")
           mark_gpu_failure "$id" "${diag:-GPU caiu do barramento ou ficou pendente de reset}" ;;
        3) ST_STATUS[$id]="REPROVADO"; MOTIVOS+=("$name: hardware reprovado no diagnostico (codigo 3). Detalhes na secao DCGM.")
           # Falhas de P2P costumam vir da plataforma (IOMMU/ACS), nao de uma GPU com defeito
           p2p=$(grep -cE "\[FAIL\] Teste: pcie .*peer-to-peer" "$dlog" 2>/dev/null)
           if [ "${p2p:-0}" -gt 0 ]; then
               iommu=$(grep -m1 -oE "IOMMU: [^|]+" "$INV_LOG" 2>/dev/null | sed 's/ *$//')
               MOTIVOS+=("$name: $p2p falha(s) de P2P (dados corrompidos entre GPUs). Causa mais comum: IOMMU em modo de traducao ou ACS, nao uma GPU com defeito (${iommu:-IOMMU: nao verificado}). Recomendacao: iommu=pt no kernel ou IOMMU desligado na BIOS; depois validar com 'sudo dcgmi diag -r pcie'.")
           fi ;;
        *) # Plataforma nao pronta (Fabric Manager / CUDA sem inicializar): o hardware nao foi avaliado
           diag=$(grep -m1 -oE "PLATAFORMA NAO PRONTA[^:]*: .*" "$dlog" 2>/dev/null | sed -E 's/^[^:]*: //')
           if [ -n "$diag" ]; then
               ST_STATUS[$id]="NAO EXECUTADO"
               PENDENCIAS+=("$name: plataforma nao pronta, hardware nao avaliado ($diag).")
           else
               ST_STATUS[$id]="FALHOU"; MOTIVOS+=("$name: erro de software/utilitario (codigo $rc); diagnostico incompleto.")
           fi ;;
    esac
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
# Alertas de software/container sao configuracao do ambiente (pendencias); os demais sao de hardware
INV_ALERTS=$(grep "ALERTA CRITICO" "$INV_LOG" 2>/dev/null | grep -vE "ALERTA CRITICO DE (SOFTWARE|CONTAINER)" | sed -E 's/^\[[^]]*\] //')
while IFS= read -r a; do [ -n "$a" ] && PENDENCIAS+=("Inventario: $a"); done < <(grep -E "ALERTA CRITICO DE (SOFTWARE|CONTAINER)" "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] //')
if [ "$RC" -ne 0 ]; then
    ST_STATUS[1]="FALHOU"; MOTIVOS+=("Inventario: o modulo terminou com codigo $RC (ver log).")
elif [ -n "$INV_ALERTS" ]; then
    ST_STATUS[1]="REPROVADO"
    while IFS= read -r a; do MOTIVOS+=("Inventario: $a"); done <<< "$INV_ALERTS"
else
    ST_STATUS[1]="APROVADO"
fi
# Com o sistema de pacotes quebrado, os erros de cada instalacao repetem a mesma causa: fica so o aviso principal
while IFS= read -r e; do [ -n "$e" ] && AVISOS+=("Inventario: $e"); done < <(grep -E " - Erro:| - Aviso:|AVISO DE PLATAFORMA|AVISO DE SOFTWARE" "$INV_LOG" 2>/dev/null | grep -v "sistema de pacotes quebrado (ver AVISO" | sed -E 's/^\[[^]]*\] //')

# Relatorio curto para execucoes interrompidas antes dos testes (driver pendente ou ausente)
short_report() {
    local status="$1" motivo="$2"
    {
        echo "=================================================================="
        echo "RELATORIO DE HOMOLOGACAO - GPU SERVER"
        echo "=================================================================="
        echo "Host:      $HOST"
        echo "Servidor:  $(dmidecode -s system-manufacturer 2>/dev/null | head -n1) $(dmidecode -s system-product-name 2>/dev/null | head -n1) | Serial: $(dmidecode -s system-serial-number 2>/dev/null | head -n1)"
        echo "Data:      $(date '+%Y-%m-%d %H:%M:%S')"
        echo "GPUs NVIDIA no barramento PCIe (lspci): $(lspci -d 10de: -nn 2>/dev/null | grep -cE "\[(0300|0302)\]")"
        echo ""
        echo ">>> RESULTADO: $status <<<"
        echo "  - $motivo"
        echo ""
        echo "Ultimas linhas do inventario:"
        tail -n 15 "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] /  /'
        echo "=================================================================="
    } > "$REPORT"
    cat "$REPORT" | tee -a "$ORCH_LOG"
    chown -R "$REAL_USER": "$BASE_DIR" 2>/dev/null
    log "Relatorio: $REPORT"
}

# Driver NVIDIA recem-instalado pelo Modulo 1: avisa e reinicia o servidor
if [ "$RC" -eq 4 ]; then
    short_report "PENDENTE - REBOOT NECESSARIO" "O driver NVIDIA foi instalado e so funciona apos reiniciar. Depois do reboot, execute novamente o mesmo comando."
    log "=================================================================="
    log "ATENCAO: o servidor sera REINICIADO em ${REBOOT_COUNTDOWN}s para carregar o driver NVIDIA. Pressione Ctrl+C para cancelar."
    log "Depois do reboot, execute novamente o MESMO comando para continuar a homologacao."
    log "=================================================================="
    sleep "$REBOOT_COUNTDOWN"
    log "Reiniciando o servidor..."
    reboot
    exit 4
fi

# Servidor em uso ou plataforma nao pronta (ex.: Fabric Manager sem concluir): os testes dariam falsas reprovacoes
INV_NAO_EXEC=$(grep -m1 "NAO EXECUTADO:" "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] //; s/^NAO EXECUTADO: //')
if [ -n "$INV_NAO_EXEC" ]; then
    short_report "NAO EXECUTADO" "$INV_NAO_EXEC"
    rm -f "$STAMP"
    exit 1
fi

# Sem driver funcional nenhum teste pode rodar: encerra com a causa real, em vez de reprovacoes enganosas
if ! command -v nvidia-smi &> /dev/null || ! timeout 30 nvidia-smi -L &> /dev/null; then
    if ! command -v nvidia-smi &> /dev/null; then
        short_report "NAO EXECUTADO" "Driver NVIDIA ausente e a instalacao automatica falhou (ver inventario). Os testes nao foram executados."
    else
        short_report "NAO EXECUTADO" "O driver NVIDIA esta instalado, mas o nvidia-smi nao responde (driver nao carregado ou GPU inacessivel). Verifique o log do inventario e o dmesg."
    fi
    rm -f "$STAMP"
    exit 1
fi

# ==============================================================================
# Verificacao previa do acesso ao modelo do vLLM (segundos, em vez de descobrir horas depois)
# ==============================================================================
VLLM_MODEL=$(grep -m1 -oE '^VLLM_MODEL="[^"]+"' "$SCRIPT_DIR/05_vllm_benchmark.sh" 2>/dev/null | cut -d'"' -f2)
VLLM_PRE=""
if [ -n "$VLLM_MODEL" ]; then
    HF_CODE=$(curl -s -o /dev/null -w '%{http_code}' -I -L --max-time 30 -H "Authorization: Bearer $HF_TOKEN_ARG" \
        "https://huggingface.co/$VLLM_MODEL/resolve/main/config.json" 2>/dev/null)
    case "$HF_CODE" in
        200) log "Token do Hugging Face: acesso ao modelo $VLLM_MODEL confirmado." ;;
        401|403) VLLM_PRE="o token do Hugging Face nao tem acesso ao modelo $VLLM_MODEL (HTTP $HF_CODE). Solicite acesso ao modelo na conta do token ou use outro token."
                 log "ATENCAO: $VLLM_PRE O benchmark vLLM nao sera executado." ;;
        *) AVISOS+=("vLLM: nao foi possivel verificar o acesso ao modelo $VLLM_MODEL (HTTP ${HF_CODE:-sem resposta}); o benchmark sera tentado assim mesmo.") ;;
    esac
fi

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
# Etapa 3: DCGM triagem (niveis rapidos; aponta GPU ja defeituosa antes dos testes de carga)
# ==============================================================================
TRI_MAX=$(( DCGM_LEVEL < DCGM_TRIAGE_LEVEL ? DCGM_LEVEL : DCGM_TRIAGE_LEVEL ))
run_stage 3 "DCGM triagem (niveis 1 a $TRI_MAX)" ./02_dcgm_diag_completo.sh 1 "$TRI_MAX"
RC=$?
DCGM_LOG_T=$(newest "$BASE_DIR/dcgm" "diag_execucao_*.log")
eval_dcgm 3 "$RC" "$DCGM_LOG_T" "DCGM triagem"

# ==============================================================================
# Etapa 4: NCCL
# ==============================================================================
NCCL_SUM=""
PKG_CAUSE=""; grep -q "AVISO DE SOFTWARE: sistema de pacotes quebrado" "$INV_LOG" 2>/dev/null && PKG_CAUSE=" (sistema de pacotes quebrado: ver inventario)"
if [ "$GPU_FAILED" = true ]; then
    skip_stage 4 "Teste NCCL (AllReduce, com e sem P2P)"
elif [ ! -x /usr/local/cuda/bin/nvcc ] || ! dpkg -s libnccl-dev &>/dev/null; then
    skip_config_stage 4 "Teste NCCL (AllReduce, com e sem P2P)" "CUDA Toolkit ou NCCL nao instalados${PKG_CAUSE}."
else
    NCCL_ERR=""
    run_stage 4 "Teste NCCL (AllReduce, com e sem P2P)" ./03_nccl_test.sh
    RC=$?
    NCCL_SUM="$BASE_DIR/benchmark/nccl_resumo.txt"
    [ "$NCCL_SUM" -nt "$STAMP" ] || NCCL_SUM=""
    case "$RC" in
        0) ST_STATUS[4]="APROVADO" ;;
        3) ST_STATUS[4]="REPROVADO"
           while IFS= read -r a; do MOTIVOS+=("NCCL: ${a#  - }"); done < <(grep "^  - " "${NCCL_SUM:-/dev/null}") ;;
        *) ST_STATUS[4]="FALHOU"; NCCL_ERR="NCCL: erro de execucao (codigo $RC); teste incompleto." ;;
    esac
    # Se uma GPU travou durante o NCCL, a falha primaria e esta etapa (e nao um erro de execucao)
    if post_stage_health 4 "NCCL"; then
        [ -n "${NCCL_ERR:-}" ] && MOTIVOS+=("$NCCL_ERR")
    fi
fi

# ==============================================================================
# Etapa 5: Benchmark vLLM
# ==============================================================================
VLLM_SUM=""
if [ "$GPU_FAILED" = true ]; then
    skip_stage 5 "Benchmark de inferencia vLLM"
elif ! command -v docker &>/dev/null || ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    skip_config_stage 5 "Benchmark de inferencia vLLM" "Docker ou runtime NVIDIA do Docker indisponivel${PKG_CAUSE}."
elif [ -n "$VLLM_PRE" ]; then
    skip_config_stage 5 "Benchmark de inferencia vLLM" "$VLLM_PRE"
else
    run_stage 5 "Benchmark de inferencia vLLM" ./05_vllm_benchmark.sh
    RC=$?
    VLLM_SUM=$(newest "$BASE_DIR/benchmark" "vllm_resumo_*.txt")
    if [ "$RC" -eq 0 ]; then
        ST_STATUS[5]="APROVADO"
    else
        ST_STATUS[5]="FALHOU"
    fi
    if post_stage_health 5 "vLLM" && [ "$RC" -ne 0 ]; then
        MOTIVOS+=("vLLM: o benchmark falhou (codigo $RC). Ver log completo em $BASE_DIR/logs.")
    fi
fi
VLLM_TPUT=$(grep -i "Throughput" "${VLLM_SUM:-/dev/null}" 2>/dev/null | tail -n1 | sed 's/^ *//')

# ==============================================================================
# Etapa 6: DCGM estresse (niveis longos; os que mais derrubam GPUs instaveis)
# ==============================================================================
DCGM_LOG_S=""
if [ "$DCGM_LEVEL" -gt "$TRI_MAX" ]; then
    if [ "$GPU_FAILED" = true ]; then
        skip_stage 6 "DCGM estresse (niveis $((TRI_MAX + 1)) a $DCGM_LEVEL)"
    else
        run_stage 6 "DCGM estresse (niveis $((TRI_MAX + 1)) a $DCGM_LEVEL)" ./02_dcgm_diag_completo.sh "$((TRI_MAX + 1))" "$DCGM_LEVEL"
        RC=$?
        DCGM_LOG_S=$(newest "$BASE_DIR/dcgm" "diag_execucao_*.log")
        [ "$DCGM_LOG_S" = "$DCGM_LOG_T" ] && DCGM_LOG_S=""
        eval_dcgm 6 "$RC" "$DCGM_LOG_S" "DCGM estresse"
    fi
fi

# ==============================================================================
# Etapa 7: Telemetria (fim) e analise do burn-in
# ==============================================================================
if [ "$TELEMETRY_ON" = true ]; then
    STAGES+=(7); ST_DESC[7]="Telemetria (fim) e analise do burn-in"
    log "=================================================="
    log "ETAPA 7: ${ST_DESC[7]}"
    ST_T0[7]=$(date +%s)
    stop_telemetry
    ST_STATUS[7]="APROVADO"

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
        ST_STATUS[7]="FALHOU"; MOTIVOS+=("Telemetria: nenhuma amostra coletada; burn-in nao verificado.")
    fi
    # Geracao PCIe maxima suportada por cada GPU (ex.: L40S = Gen4, Blackwell = Gen5).
    # Vem do inventario, coletado com as GPUs saudaveis; a consulta ao vivo so e usada se faltar.
    declare -A GPU_GEN_MAX
    while read -r gi gg; do
        GPU_GEN_MAX[$gi]=$gg
    done < <(grep -oE "GPU [0-9]+ \(.*(maximo da GPU:|esperado) Gen[0-9]+" "$INV_LOG" 2>/dev/null | sed -E 's/^GPU ([0-9]+) .*Gen([0-9]+)$/\1 \2/')
    if [ "${#GPU_GEN_MAX[@]}" -eq 0 ]; then
        while IFS=', ' read -r gi gg; do
            [[ "$gg" =~ ^[0-9]+$ ]] && GPU_GEN_MAX[$gi]=$gg
        done < <(timeout 30 nvidia-smi --query-gpu=index,pcie.link.gen.gpumax --format=csv,noheader,nounits 2>/dev/null)
    fi
    TEL_GPUS=0
    while read -r g tmax tmem ns nterm nhws nbrk nswp genmax nload eccmax; do
        [ -z "$g" ] && continue
        TEL_GPUS=$((TEL_GPUS + 1))
        if [ "$tmax" != "NA" ] && awk -v t="$tmax" -v m="$MAX_GPU_TEMP_C" 'BEGIN { exit !(t > m) }'; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g atingiu ${tmax} C (maximo aceitavel: $MAX_GPU_TEMP_C C).")
        fi
        if [ "$nterm" -gt 0 ]; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g com throttling termico em $nterm amostra(s).")
        fi
        if [ "$nhws" -gt 0 ] || [ "$nbrk" -gt 0 ]; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g com HW Slowdown/Power Brake em $((nhws + nbrk)) amostra(s) (energia ou sinal de hardware).")
        fi
        if [ "$nload" -eq 0 ] || [ "$genmax" = "NA" ]; then
            AVISOS+=("Telemetria: GPU $g sem amostras sob carga (>= ${LOAD_UTIL_PCT}% de uso); geracao PCIe sob carga nao verificada.")
        elif [ "$genmax" -lt "${GPU_GEN_MAX[$g]:-$EXPECTED_PCIE_GEN}" ]; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g nao passou de PCIe Gen$genmax sob carga (esperado Gen${GPU_GEN_MAX[$g]:-$EXPECTED_PCIE_GEN}).")
        fi
        if [ "$eccmax" != "NA" ] && [ "$eccmax" -gt 0 ]; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Telemetria: GPU $g com $eccmax erro(s) ECC nao corrigido(s).")
        fi
    done <<< "$TEL_TABLE"
    if [ -n "$TEL_TABLE" ] && [ "$TEL_GPUS" -lt "$EXPECTED_GPUS" ]; then
        ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Telemetria: apenas $TEL_GPUS de $EXPECTED_GPUS GPUs apareceram nas amostras.")
    fi

    # Log do kernel (o coletor le o buffer desde o boot: inclui eventos anteriores aos testes)
    XID_SUMMARY=$(grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null | grep -oE "Xid \([^)]*\): [0-9]+" | awk '{print $NF}' | sort -n | uniq -c | awk '{printf "Xid %s (%sx)  ", $2, $1}')
    # ------------------------------------------------------------------
    # Linha do tempo: cada evento do kernel e da telemetria e associado a etapa
    # (e ao nivel do DCGM) em que ocorreu, para separar causa e consequencia
    # ------------------------------------------------------------------
    # Inicio de cada nivel do DCGM ("epoch nivel"), lido dos logs do Modulo 2
    DCGM_LEVEL_STARTS=$(for f in "$DCGM_LOG_T" "$DCGM_LOG_S"; do [ -n "$f" ] && grep -oE "^\[[0-9-]+ [0-9:]+\] Executando Nivel [0-9]+" "$f" 2>/dev/null; done \
        | sed -E 's/^\[([^]]+)\] Executando Nivel ([0-9]+)$/\1|\2/' \
        | while IFS='|' read -r t l; do e=$(date -d "$t" +%s 2>/dev/null) && echo "$e $l"; done | sort -n)
    # Rotulo da etapa em que um instante (epoch) caiu
    stage_at() {
        local e="$1" id lvl
        if [ "$e" -lt "$START_EPOCH" ]; then echo "antes do inicio da homologacao"; return; fi
        for id in "${STAGES[@]}"; do
            [ -n "${ST_T0[$id]:-}" ] || continue
            if [ "$e" -ge "${ST_T0[$id]}" ] && [ "$e" -le "${ST_T1[$id]}" ]; then
                lvl=""
                if [ "$id" = 3 ] || [ "$id" = 6 ]; then
                    lvl=$(echo "$DCGM_LEVEL_STARTS" | awk -v e="$e" '$1 != "" && $1 <= e {l = $2} END {print l}')
                fi
                echo "etapa $id, ${ST_DESC[$id]}${lvl:+, nivel $lvl}"; return
            fi
        done
        echo "entre etapas"
    }
    fmt_ts() { date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
    TIMELINE=""

    # Xids: uma linha por "epoch|xid|pci|ocorrencias|etapa" (agrupadas por segundo, para nao travar com tempestades de Xid)
    XID_ROWS=""
    while read -r cnt rest; do
        IFS='|' read -r t x xpci <<< "$rest"
        e=$(date -d "$t" +%s 2>/dev/null) || continue
        XID_ROWS+="$e|$x|$xpci|$cnt|$(stage_at "$e")"$'\n'
    done < <(grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null \
        | sed -nE 's/^\[([^]]+)\] .*Xid \(PCI:([0-9A-Fa-f:.]+)\): ([0-9]+).*/\1|\3|\2/p' | sort | uniq -c)
    # Por Xid e GPU: total, primeira ocorrencia e etapas em que apareceu
    XID_GROUPS=$(printf '%s' "$XID_ROWS" | sort -t'|' -k1,1n | awk -F'|' '
        $1 != "" { k = $2 "|" $3
          if (!(k in first)) { first[k] = $1; ord[++n] = k }
          tot[k] += $4
          if (index(";" st[k] ";", ";" $5 ";") == 0) st[k] = st[k] (st[k] == "" ? "" : ";") $5 }
        END { for (i = 1; i <= n; i++) { k = ord[i]; print k "|" tot[k] "|" first[k] "|" st[k] } }')
    # Cada Xid e identificado pela GPU (indice, PCI e serial), com horario e etapa
    while IFS='|' read -r x xpci tot first sts; do
        [ -z "$x" ] && continue
        detail="$tot ocorrencia(s), primeira em $(fmt_ts "$first"), durante: ${sts//;/ | }"
        if [[ " $CRITICAL_XIDS " == *" $x "* ]]; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Kernel: Xid critico $x na $(gpu_id_from_pci "$xpci"): $detail.")
        else
            AVISOS+=("Kernel: Xid $x na $(gpu_id_from_pci "$xpci") (nao critico; pode ter sido causado por aplicacao): $detail.")
        fi
    done <<< "$XID_GROUPS"
    # Linha do tempo: primeira ocorrencia de cada Xid/GPU em cada etapa
    while IFS='|' read -r e x xpci cnt st; do
        [ -z "$e" ] && continue
        TIMELINE+="$e|Xid $x na $(gpu_id_from_pci "$xpci") (${cnt}x) - $st"$'\n'
    done < <(printf '%s' "$XID_ROWS" | sort -t'|' -k1,1n | awk -F'|' '
        $1 != "" { k = $2 "|" $3 "|" $5; if (!(k in f)) { f[k] = $1; ord[++n] = k } c[k] += $4 }
        END { for (i = 1; i <= n; i++) { k = ord[i]; split(k, a, "|"); print f[k] "|" a[1] "|" a[2] "|" c[k] "|" a[3] } }')

    FALLEN_TS=$(grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null | grep -i "fallen off the bus" | head -n1 | sed -nE 's/^\[([^]]+)\].*/\1/p')
    if grep -v '\[telemetria\]' "$TEL_KLOG" 2>/dev/null | grep -qi "fallen off the bus"; then
        FALLEN_E=$(date -d "$FALLEN_TS" +%s 2>/dev/null)
        if [ -n "$FALLEN_E" ]; then
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Kernel: GPU caiu do barramento (\"fallen off the bus\"), primeira em $(fmt_ts "$FALLEN_E"), durante: $(stage_at "$FALLEN_E").")
            TIMELINE+="$FALLEN_E|GPU caiu do barramento (fallen off the bus) - $(stage_at "$FALLEN_E")"$'\n'
        else
            ST_STATUS[7]="REPROVADO"; MOTIVOS+=("Kernel: GPU caiu do barramento (\"fallen off the bus\").")
        fi
    fi

    # nvidia-smi sem resposta na telemetria: antes da falha primaria e sinal precoce; depois, consequencia
    HANG_ROWS=$(grep -oE "^\[[0-9-]+ [0-9:]+\] \[telemetria\] ALERTA: nvidia-smi" "$TEL_KLOG" 2>/dev/null \
        | sed -E 's/^\[([^]]+)\].*/\1/' | while read -r t; do date -d "$t" +%s 2>/dev/null; done)
    NSMI_HANGS=$(printf '%s' "$HANG_ROWS" | grep -c . )
    if [ "${NSMI_HANGS:-0}" -gt 0 ]; then
        FAIL_T0="${ST_T0[$FAIL_STAGE]:-${FAIL_EPOCH:-}}"
        H_BEFORE=0; H_AFTER=0; H_FIRST_BEFORE=""; H_FIRST_AFTER=""
        while read -r e; do
            [ -z "$e" ] && continue
            if [ "$GPU_FAILED" = true ] && [ -n "$FAIL_T0" ] && [ "$e" -ge "$FAIL_T0" ]; then
                H_AFTER=$((H_AFTER + 1)); [ -z "$H_FIRST_AFTER" ] && H_FIRST_AFTER="$e"
            else
                H_BEFORE=$((H_BEFORE + 1)); [ -z "$H_FIRST_BEFORE" ] && H_FIRST_BEFORE="$e"
            fi
        done <<< "$HANG_ROWS"
        if [ "$H_BEFORE" -gt 0 ]; then
            ST_STATUS[7]="REPROVADO"
            if [ "$GPU_FAILED" = true ]; then
                MOTIVOS+=("Telemetria: nvidia-smi deixou de responder $H_BEFORE vez(es) antes da falha da GPU (sinal precoce), a primeira em $(fmt_ts "$H_FIRST_BEFORE"), durante: $(stage_at "$H_FIRST_BEFORE").")
            else
                MOTIVOS+=("Telemetria: nvidia-smi deixou de responder $H_BEFORE vez(es) (GPU travada ou caida), a primeira em $(fmt_ts "$H_FIRST_BEFORE"), durante: $(stage_at "$H_FIRST_BEFORE").")
            fi
        fi
        if [ "$H_AFTER" -gt 0 ]; then
            CONSEQ+=("Telemetria: nvidia-smi deixou de responder $H_AFTER vez(es) a partir de $(fmt_ts "$H_FIRST_AFTER"), efeito da GPU em falha.")
        fi
        # Linha do tempo: primeira falta de resposta e quantidade em cada etapa
        while IFS='|' read -r e cnt st; do
            [ -z "$e" ] && continue
            TIMELINE+="$e|nvidia-smi sem resposta na telemetria (${cnt}x) - $st"$'\n'
        done < <(while read -r e; do [ -n "$e" ] && echo "$e|$(stage_at "$e")"; done <<< "$HANG_ROWS" \
            | awk -F'|' '{ if (!($2 in f)) { f[$2] = $1; ord[++n] = $2 } c[$2]++ } END { for (i = 1; i <= n; i++) print f[ord[i]] "|" c[ord[i]] "|" ord[i] }')
    fi
    ST_T1[7]=$(date +%s); ST_DUR[7]=$((ST_T1[7] - ST_T0[7]))
    log "ETAPA 7: ${ST_DESC[7]} - Finalizada (${ST_STATUS[7]})"
fi

# ==============================================================================
# Eventos do BMC (SEL): o que surgiu durante o teste x historico anterior
# Os registros novos sao identificados pelo id (independe do relogio do BMC, que pode estar errado).
# ==============================================================================
SEL_START="$BASE_DIR/inventario/ipmi_sel.txt"
SEL_END="$REPORT_DIR/ipmi_sel_fim_${HOST}_${TS}.txt"
SEL_CRIT_RE="Critical Interrupt|Bus (Fatal|Uncorrectable|Correctable) Error|Uncorrectable|Machine Check|IERR|Thermal Trip|Predictive [Ff]ailure|Failure detected|AC lost|Redundancy Lost|Transition to Critical|Non-recoverable|PCI (PERR|SERR)|Correctable ECC|Watchdog"
SEL_DURING=""; SEL_HIST=""; SEL_NOTE=""
# "id|data|tipo: evento" de cada registro critico do SEL
sel_crit() {
    awk -F'|' -v re="$SEL_CRIT_RE" '{
        id = $1; gsub(/ /, "", id); d = $2; gsub(/^ +| +$/, "", d)
        t = $4; gsub(/#0x[0-9a-fA-F]+/, "", t); gsub(/^ +| +$/, "", t); e = $5; gsub(/^ +| +$/, "", e)
        x = t ": " e
        if (id != "" && x ~ re && x !~ /graceful/) print id "|" d "|" x }' "$1" 2>/dev/null
}
# Agrupa "data|descricao" em "Nx descricao (de A a B)"
sel_group() {
    awk -F'|' '{ k = $2; c[k]++; if (!(k in f)) f[k] = $1; l[k] = $1 }
        END { for (k in c) printf "%dx %s (%s%s)\n", c[k], k, f[k], (l[k] != f[k] ? " a " l[k] : "") }' | sort -rn
}
if command -v ipmitool &>/dev/null; then
    timeout 120 ipmitool sel elist > "$SEL_END" 2>/dev/null
    if [ -s "$SEL_END" ] && [ -s "$SEL_START" ]; then
        START_IDS=$(awk -F'|' '{id = $1; gsub(/ /, "", id); if (id != "") print id}' "$SEL_START")
        SEL_DURING=$(sel_crit "$SEL_END" | while IFS='|' read -r id d desc; do grep -qxF "$id" <<< "$START_IDS" || echo "$d|$desc"; done | sel_group)
        SEL_HIST=$(sel_crit "$SEL_START" | cut -d'|' -f2- | sel_group)
        while IFS= read -r e; do [ -n "$e" ] && AVISOS+=("BMC: evento critico registrado DURANTE o teste: $e"); done <<< "$SEL_DURING"
    else
        SEL_NOTE="SEL do BMC indisponivel no inicio ou no fim do teste."
    fi
else
    SEL_NOTE="ipmitool indisponivel: eventos do BMC nao verificados."
fi

# ==============================================================================
# Relatorio final
# ==============================================================================
END_EPOCH=$(date +%s)
# REPROVADO: falha de hardware/criterio. INCONCLUSIVO: nada reprovou, mas etapas nao rodaram por configuracao.
if [ "${#MOTIVOS[@]}" -gt 0 ]; then VERDICT="REPROVADO"
elif [ "${#PENDENCIAS[@]}" -gt 0 ]; then VERDICT="INCONCLUSIVO"
else VERDICT="APROVADO"; fi
if [ "$GPU_FAILED" = true ]; then
    TIMELINE+="$FAIL_EPOCH|FALHA PRIMARIA detectada ao fim da etapa $FAIL_STAGE (${ST_DESC[$FAIL_STAGE]}): $FAIL_DESC"$'\n'
fi

SYS_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | head -n1)
SYS_MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -n1)
SYS_SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | head -n1)
BIOS_VER=$(dmidecode -s bios-version 2>/dev/null | head -n1)
DRIVER_VER=$(grep -m1 -E "^ *(KMD Version|Driver Version)" "$BASE_DIR/inventario/nvidia-smi-q.txt" 2>/dev/null | awk -F: '{print $2}' | awk '{print $1}')
DRIVER_CUDA=$(grep -m1 -E "^ *(CUDA UMD Version|CUDA Version)" "$BASE_DIR/inventario/nvidia-smi-q.txt" 2>/dev/null | awk -F: '{print $2}' | awk '{print $1}')
GPU_MODELS=$(grep -oE "^GPU [0-9]+: [^(]+" "$BASE_DIR/inventario/gpus.txt" 2>/dev/null | sed -E 's/^GPU [0-9]+: //; s/ +$//' | sort | uniq -c | awk '{c = $1; $1 = ""; sub(/^ /, ""); printf "%s%sx %s", (NR > 1 ? ", " : ""), c, $0}')
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
    echo "GPUs:      ${GPU_MODELS:-?}"
    echo "Inicio:    $(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S')"
    echo "Fim:       $(date -d "@$END_EPOCH" '+%Y-%m-%d %H:%M:%S') (duracao total: $(fmt_dur $((END_EPOCH - START_EPOCH))))"
    echo ""
    echo ">>> RESULTADO FINAL: $VERDICT <<<"
    if [ "${#MOTIVOS[@]}" -gt 0 ]; then
        echo "Motivos da reprovacao:"
        for m in "${MOTIVOS[@]}"; do echo "  - $m"; done
    fi
    if [ "${#PENDENCIAS[@]}" -gt 0 ]; then
        echo "Nao executado por configuracao do ambiente (o hardware nao foi avaliado nestes itens; corrija e repita):"
        for c in "${PENDENCIAS[@]}"; do echo "  - $c"; done
    fi
    if [ "${#CONSEQ[@]}" -gt 0 ]; then
        echo "Falhas em consequencia da GPU em falha (nao indicam problemas independentes):"
        for c in "${CONSEQ[@]}"; do echo "  - $c"; done
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
        printf "  [%-13s] %s. %-45s %s\n" "${ST_STATUS[$id]:-?}" "$id" "${ST_DESC[$id]}" "$(fmt_dur "${ST_DUR[$id]:-0}")"
    done
    echo ""
    echo "------------------------------------------------------------------"
    echo "LINHA DO TEMPO"
    echo "------------------------------------------------------------------"
    echo "  Etapas:"
    for id in "${STAGES[@]}"; do
        if [ -n "${ST_T0[$id]:-}" ]; then
            printf "    %s - %s  %s. %s\n" "$(date -d "@${ST_T0[$id]}" '+%Y-%m-%d %H:%M:%S')" "$(date -d "@${ST_T1[$id]}" '+%H:%M:%S')" "$id" "${ST_DESC[$id]}"
        else
            printf "    %-31s  %s. %s\n" "(${ST_STATUS[$id]:-nao executada})" "$id" "${ST_DESC[$id]}"
        fi
    done
    if [ -n "$TIMELINE" ]; then
        echo "  Eventos (horario do primeiro registro em cada etapa):"
        printf '%s' "$TIMELINE" | sort -t'|' -k1,1n | while IFS='|' read -r e txt; do
            [ -n "$e" ] && printf "    %s  %s\n" "$(date -d "@$e" '+%Y-%m-%d %H:%M:%S')" "$txt"
        done
    else
        echo "  Eventos: nenhum Xid, falta de resposta do nvidia-smi ou falha de GPU registrados."
    fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "HARDWARE (Modulo 1)"
    echo "------------------------------------------------------------------"
    grep -E "GPUs esperadas:|GPU [0-9]+ \(.*\): (OK|FALHA|ERRO)|Validacao de GPUs dentro do container|IOMMU: |AVISO DE PLATAFORMA|STATUS DO HARDWARE|ALERTA CRITICO" "$INV_LOG" 2>/dev/null | sed -E 's/^\[[^]]*\] /  /'
    echo ""
    for dsec in 3 6; do
        [ -n "${ST_DESC[$dsec]:-}" ] || continue
        [ "$dsec" = 3 ] && dlog="$DCGM_LOG_T" || dlog="$DCGM_LOG_S"
        echo "------------------------------------------------------------------"
        echo "DIAGNOSTICO ${ST_DESC[$dsec]} (Modulo 2)"
        echo "------------------------------------------------------------------"
        if [ -n "$dlog" ]; then
            grep -E "\[FAIL\]|\[WARN |Motivacao:|REPROVADO|DIAGNOSTICO FINAL|concluido com sucesso|concluidos com sucesso|FALHA CRITICA|GPU EM FALHA" "$dlog" | sed -E 's/^\[[^]]*\] /  /'
        elif [ "${ST_STATUS[$dsec]}" = "NAO EXECUTADO" ]; then
            echo "  (nao executado: GPU em falha desde a etapa $FAIL_STAGE)"
        else
            echo "  (log do diagnostico nao encontrado)"
        fi
        echo ""
    done
    echo "------------------------------------------------------------------"
    echo "NCCL (Modulo 3)"
    echo "------------------------------------------------------------------"
    if [ -n "$NCCL_SUM" ]; then grep -v "^=====" "$NCCL_SUM" | sed 's/^/  /'
    elif [ "${ST_STATUS[4]}" = "NAO EXECUTADO" ]; then echo "  (nao executado: GPU em falha desde a etapa $FAIL_STAGE)"
    else echo "  (resumo do NCCL nao encontrado)"; fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "INFERENCIA vLLM (Modulo 5) - throughput apenas registrado"
    echo "------------------------------------------------------------------"
    if [ "${ST_STATUS[5]}" = "NAO EXECUTADO" ]; then echo "  (nao executado: GPU em falha desde a etapa $FAIL_STAGE)"
    else echo "  ${VLLM_TPUT:-(throughput nao encontrado)}"; fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "TELEMETRIA DO BURN-IN (Modulo 4) - limite: ${MAX_GPU_TEMP_C} C"
    echo "------------------------------------------------------------------"
    if [ -n "${TEL_TABLE:-}" ]; then
        printf "  %-4s %-9s %-9s %-9s %-11s %-11s %-12s %-9s\n" "GPU" "Temp max" "Mem max" "Amostras" "Thr.termico" "HW slow/brk" "PCIe (carga)" "ECC n/c"
        while read -r g tmax tmem ns nterm nhws nbrk nswp genmax nload eccmax; do
            [ "$tmax" = "NA" ] && tmax="N/A" || tmax="${tmax}C"
            [ "$tmem" = "NA" ] && tmem="N/A" || tmem="${tmem}C"
            [ "$genmax" = "NA" ] && genmax="N/A" || genmax="Gen$genmax"
            [ "$eccmax" = "NA" ] && eccmax="N/A"
            printf "  %-4s %-9s %-9s %-9s %-11s %-11s %-12s %-9s\n" "$g" "$tmax" "$tmem" "$ns" "$nterm" "$((nhws + nbrk))" "$genmax" "$eccmax"
        done <<< "$TEL_TABLE"
        echo "  Eventos Xid no log do kernel (desde o boot): ${XID_SUMMARY:-nenhum}"
    else
        echo "  (telemetria indisponivel)"
    fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "EVENTOS DO BMC (SEL)"
    echo "------------------------------------------------------------------"
    if [ -n "$SEL_NOTE" ]; then
        echo "  $SEL_NOTE"
    else
        if [ -n "$SEL_DURING" ]; then
            echo "  Durante o teste: $(echo "$SEL_DURING" | wc -l) tipo(s) de evento critico:"
            echo "$SEL_DURING" | sed 's/^/    /'
        else
            echo "  Durante o teste: nenhum evento critico"
        fi
        echo "  Historico anterior ao teste (datas do relogio do BMC):"
        if [ -n "$SEL_HIST" ]; then echo "$SEL_HIST" | head -n 15 | sed 's/^/    /'; else echo "    nenhum evento critico"; fi
    fi
    echo ""
    echo "------------------------------------------------------------------"
    echo "VERSOES"
    echo "------------------------------------------------------------------"
    echo "  Driver NVIDIA: ${DRIVER_VER:-?} (CUDA suportado pelo driver: ${DRIVER_CUDA:-?}) | CUDA Toolkit: ${CUDA_VER:-?} | NCCL: ${NCCL_VER:-?}"
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
case "$VERDICT" in
    APROVADO) exit 0 ;;
    INCONCLUSIVO) exit 1 ;;
    *) exit 3 ;;
esac
}
