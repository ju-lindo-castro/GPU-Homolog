#!/bin/bash
# Modulo 2: Diagnostico DCGM Completo (v11 - Gatekeeper de Saude PCIe/Hardware + Execucao como root + Avaliacao do JSON FAIL/WARN + deteccao de driver ausente + identificacao da GPU em falha)
# Uso: ./02_dcgm_diag_completo.sh [NIVEL_MAXIMO] (Padrao: 4. Ex: ./02_dcgm_diag_completo.sh 2)
# Codigos de saida: 0 = aprovado | 1 = erro de software/utilitario | 2 = GPU caiu do barramento ou travou/pendente de reset (reboot obrigatorio) | 3 = hardware reprovado no diagnostico

MAX_LEVEL=${1:-4}
# Quantidade de GPUs que o servidor deve ter (padrao da homologacao)
EXPECTED_GPUS=8

# Garante execucao como root: necessario para ler o dmesg (Ubuntu restringe a usuarios comuns)
# e para nao depender do cache do sudo (~15 min) durante testes longos
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Mantem os arquivos na home do usuario que chamou o script, mesmo rodando como root
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
BASE_DIR="$REAL_HOME/homologacao"

mkdir -p "$BASE_DIR/dcgm"
# Devolve a posse dos arquivos gerados ao usuario em qualquer saida do script
trap 'chown -R "$REAL_USER": "$BASE_DIR" 2>/dev/null' EXIT

FULL_LOG="$BASE_DIR/dcgm/diag_execucao_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$FULL_LOG"
}

# ==============================================================================
# Gatekeeper de Hardware: Detecta GPU caida do barramento ou estado de Reboot
# ==============================================================================
# Identifica as GPUs marcadas para reset (indice, PCI e serial), usando o inventario do Modulo 1
identify_recovery_gpus() {
    nvidia-smi -q 2>/dev/null | awk -v inv="$BASE_DIR/inventario/pcie_status.txt" '
        BEGIN { while ((getline l < inv) > 0) { split(l, a, /, */); if (a[1] ~ /^[0-9]+$/) idx[tolower(a[3])] = a[1] } }
        /^GPU [0-9A-Fa-f]+:/ { bus = tolower($2); serial = "?" }
        /^    Serial Number/ { s = $0; sub(/.*: */, "", s); serial = s }
        /GPU Recovery Action/ && !/None/ { act = $0; sub(/.*: */, "", act); printf "GPU %s (PCI %s, serial %s): Recovery Action = %s\n", ((bus in idx) ? idx[bus] : "?"), bus, serial, act }'
}

check_gpu_health() {
    local fase="$1"
    GPU_FAIL_DESC=""
    log "Verificando integridade fisica e do driver das GPUs ($fase)..."

    # 1. Contagem fisica no barramento PCIe (Vendor NVIDIA 10de, classes 0300/0302)
    local pci_count
    pci_count=$(lspci -d 10de: -nn 2>/dev/null | grep -cE "\[(0300|0302)\]" || true)

    # 2. Consulta lista de GPUs ativas no driver
    local smi_list
    local smi_rc=0
    smi_list=$(nvidia-smi -L 2>&1) || smi_rc=$?

    local active_count
    active_count=$(echo "$smi_list" | grep -cE "^GPU [0-9]+:" || true)

    if [ "$smi_rc" -ne 0 ] || echo "$smi_list" | grep -qiE "Unknown Error|Unable to determine|fallen off|No devices"; then
        log "======================================================================"
        log "FALHA CRITICA DE HARDWARE DETECTADA ($fase)!"
        log "Uma ou mais GPUs cairam do barramento PCIe ou perderam o device handle."
        log "Detalhes do nvidia-smi -L:"
        echo "$smi_list" | tee -a "$FULL_LOG"
        log "GPUs no barramento PCIe (lspci): $pci_count | GPUs ativas no driver: $active_count"
        log "ACAO OBRIGATORIA: Execute um REBOOT FISICO (Hard Reboot) no servidor."
        log "Nao tente reiniciar o servico DCGM antes de reiniciar a maquina."
        log "======================================================================"
        GPU_FAIL_DESC="GPU caiu do barramento PCIe ou perdeu o device handle"
        return 1
    fi

    if [ "$pci_count" -lt "$EXPECTED_GPUS" ] || [ "$active_count" -lt "$EXPECTED_GPUS" ]; then
        log "======================================================================"
        log "FALHA CRITICA DE HARDWARE DETECTADA ($fase)!"
        log "Esperadas $EXPECTED_GPUS GPUs | Barramento PCIe (lspci): $pci_count | Driver (nvidia-smi): $active_count"
        log "ACAO OBRIGATORIA: Verifique a GPU ausente (encaixe/riser, energia, BIOS) e faca um REBOOT FISICO antes de continuar."
        log "======================================================================"
        GPU_FAIL_DESC="GPU ausente (PCIe: $pci_count, driver: $active_count, esperadas: $EXPECTED_GPUS)"
        return 1
    fi

    if [ "$pci_count" -gt 0 ] && [ "$active_count" -lt "$pci_count" ]; then
        log "======================================================================"
        log "FALHA CRITICA DE HARDWARE DETECTADA ($fase)!"
        log "Divergencia de barramento: lspci detectou $pci_count GPUs, mas o driver so enxerga $active_count."
        log "ACAO OBRIGATORIA: Execute um REBOOT FISICO (Hard Reboot) no servidor."
        log "======================================================================"
        GPU_FAIL_DESC="GPU visivel no PCIe mas inacessivel ao driver (PCIe: $pci_count, driver: $active_count)"
        return 1
    fi

    # 3. Verifica se o driver sinalizou necessidade de Reboot (GPU Recovery Action)
    local recovery_status
    recovery_status=$(nvidia-smi -q 2>/dev/null | grep "GPU Recovery Action" | grep -v "None" || true)
    if [ -n "$recovery_status" ]; then
        local failed_gpus
        failed_gpus=$(identify_recovery_gpus)
        log "======================================================================"
        log "FALHA CRITICA: GPU TRAVADA / PENDENTE DE RESET ($fase)!"
        log "O driver NVIDIA marcou GPU(s) para reset (GPU Recovery Action diferente de None):"
        if [ -n "$failed_gpus" ]; then
            while IFS= read -r l; do log "  GPU EM FALHA: $l"; done <<< "$failed_gpus"
        else
            echo "$recovery_status" | tee -a "$FULL_LOG"
        fi
        log "ACAO OBRIGATORIA: Execute um REBOOT FISICO (Hard Reboot) no servidor."
        log "======================================================================"
        GPU_FAIL_DESC="GPU travada e pendente de reset (Recovery Action)${failed_gpus:+: $(echo "$failed_gpus" | sed 's/: Recovery Action = .*//' | paste -sd ';' | sed 's/;/; /g')}"
        return 1
    fi

    # 4. Verifica erros fatais recentes no Kernel (Xid 79 = fallen off the bus, PCIe Bus Error)
    local kernel_fatal
    kernel_fatal=$(dmesg -T 2>/dev/null | grep -iE "GPU has fallen off the bus|NVRM: Xid.*: (48|61|62|63|64|79|94|95|119|120)|PCIe Bus Error.*severity=Uncorrected" | tail -n 5 || true)
    if [ -n "$kernel_fatal" ]; then
        log "AVISO CRITICO DE KERNEL ($fase): Eventos graves detectados no dmesg:"
        echo "$kernel_fatal" | tee -a "$FULL_LOG"
        if echo "$kernel_fatal" | grep -qiE "fallen off the bus|Xid.*: 79"; then
            log "ACAO OBRIGATORIA: GPU caiu do barramento (Xid 79). Reinicie o servidor antes de continuar."
            GPU_FAIL_DESC="GPU caiu do barramento PCIe (Xid 79)"
            return 1
        fi
    fi

    log "Saude das GPUs validada: $active_count/$EXPECTED_GPUS GPUs operacionais (PCIe: $pci_count | Recovery Action: None)."
    return 0
}

# ==============================================================================
# Avaliacao do resultado JSON do DCGM (compativel com DCGM 3.x e 4.x)
# Extrai uma linha por falha/aviso: teste <TAB> GPU <TAB> FAIL|WARN <TAB> mensagem
# ==============================================================================
read -r -d '' JQ_PROG <<'JQEOF'
[ .. | objects | select(has("name") and has("results")) ] | .[] | .name as $t
| .results[]?
| select((.status // "") | test("^(fail|warn)"; "i"))
| (.gpu_id // .gpu_ids // .entity_id // "-" | tostring) as $g
| (.status | ascii_upcase | .[0:4]) as $s
| ((.warnings // .info // []) | if type == "array" then . else [.] end
   | map(if type == "object" then (.warning // .message // tojson) else tostring end)
   | if length == 0 then ["(sem mensagem)"] else . end)[]
| "\($t)\t\($g)\t\($s)\t\(gsub("[\\r\\n\\t]+"; " "))"
JQEOF

# Classifica um aviso (WARN) como BENIGNO (registra e continua) ou MALIGNO (reprova).
# Avisos nao catalogados sao tratados como MALIGNOS por seguranca.
classify_warning() {
    local msg="${1,,}"
    case "$msg" in
        *persistence*)
            echo "BENIGNO|Persistence Mode desligado: afeta apenas o tempo de inicializacao da GPU, nao a saude do hardware." ;;
        *"not supported"*|*unsupported*|*"not available on this"*)
            echo "BENIGNO|Teste ou recurso nao suportado neste modelo de GPU; nao indica defeito." ;;
        *"mig mode"*|*"mig is enabled"*|*"mig enabled"*)
            echo "BENIGNO|GPU em modo MIG: o teste foi limitado pela configuracao, nao por defeito." ;;
        *ecc*|*dbe*|*sbe*|*remap*|*retire*)
            echo "MALIGNO|Erros de memoria (ECC / remapeamento de linhas): indica falha ou degradacao da VRAM." ;;
        *xid*)
            echo "MALIGNO|Erro Xid reportado pelo driver durante o teste: falha de GPU, memoria ou barramento." ;;
        *thermal*|*temperature*|*throttl*|*slowdown*)
            echo "MALIGNO|Throttling termico ou de clock: refrigeracao/fluxo de ar insuficiente ou sensor anormal." ;;
        *pcie*|*replay*|*"pci "*)
            echo "MALIGNO|Problema no barramento PCIe (replays, banda ou link degradado): verificar slot, riser e BIOS." ;;
        *nvlink*)
            echo "MALIGNO|Erro ou degradacao de NVLink entre GPUs." ;;
        *power*)
            echo "MALIGNO|Consumo ou limite de energia fora do esperado: verificar fontes, cabos e power capping." ;;
        *bandwidth*|*threshold*|*below*|*performance*|*gflops*)
            echo "MALIGNO|Desempenho abaixo do minimo esperado pelo DCGM (computacao ou banda de memoria)." ;;
        *)
            echo "MALIGNO|Aviso nao catalogado: tratado como maligno por seguranca. Revise e, se for benigno, adicione o padrao em classify_warning." ;;
    esac
}

# Le o JSON de um nivel e preenche DIAG_FAILS, DIAG_MALIGN e DIAG_BENIGN.
# Retorna 1 se o arquivo estiver vazio ou nao for um JSON valido.
evaluate_dcgm_json() {
    local json="$1" lines test gpu status msg cls tipo motivo
    DIAG_FAILS=0; DIAG_MALIGN=0; DIAG_BENIGN=0
    [ -s "$json" ] || return 1
    lines=$(jq -r "$JQ_PROG" "$json" 2>/dev/null) || return 1
    while IFS=$'\t' read -r test gpu status msg; do
        [ -z "$test" ] && continue
        if [ "$status" = "FAIL" ]; then
            DIAG_FAILS=$((DIAG_FAILS + 1))
            log "  [FAIL] Teste: $test | GPU: $gpu | Motivo: $msg"
        else
            cls=$(classify_warning "$msg"); tipo="${cls%%|*}"; motivo="${cls#*|}"
            if [ "$tipo" = "BENIGNO" ]; then
                DIAG_BENIGN=$((DIAG_BENIGN + 1))
            else
                DIAG_MALIGN=$((DIAG_MALIGN + 1))
            fi
            log "  [WARN $tipo] Teste: $test | GPU: $gpu | Mensagem: $msg"
            log "      Motivacao: $motivo"
        fi
    done <<< "$lines"
    return 0
}

log "--- Iniciando Diagnostico DCGM Sequencial (Niveis 1 a $MAX_LEVEL) ---"

# Passo 0a: Sem driver nao ha o que diagnosticar (nao confundir com GPU caida do barramento)
if ! command -v nvidia-smi &> /dev/null; then
    log "ERRO DE SOFTWARE: nvidia-smi nao encontrado - o driver NVIDIA nao esta instalado."
    log "Execute o Modulo 1 (instala o driver automaticamente). Nao e necessario reboot fisico por este motivo."
    exit 1
fi

# Passo 0b: Verifica se o hardware ja nao esta degradado antes mesmo de tocar no DCGM
if ! check_gpu_health "Pre-Check Inicial"; then
    exit 2
fi

# Auto-Fix 1: Dependencias do NVVS (Resolucao do Signal 11 em sistemas multi-NUMA) + jq para leitura do JSON
log "Verificando bibliotecas de topologia (NUMA) para o NVVS e o jq..."
sudo apt-get update -y &>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libnuma1 numactl jq &>/dev/null || true

if ! command -v jq &> /dev/null; then
    log "ERRO DE SOFTWARE: jq nao encontrado e nao foi possivel instala-lo (necessario para avaliar o resultado do DCGM)."
    exit 1
fi

if ! command -v dcgmi &> /dev/null; then
    log "ERRO DE SOFTWARE: dcgmi nao encontrado. Execute o Modulo 1 primeiro."
    exit 1
fi

# Auto-Fix 2: NVIDIA Persistence Mode
log "Ativando NVIDIA Persistence Mode..."
if ! sudo nvidia-smi -pm 1 &>/dev/null; then
    log "AVISO: Falha ao ativar Persistence Mode."
fi

# Auto-Fix 3: Inicializacao limpa e validada do servico DCGM
log "Reiniciando servico nvidia-dcgm..."
sudo systemctl stop nvidia-dcgm &>/dev/null || true
sudo pkill -9 -f "nv-hostengine|dcgmi|nvvs" 2>/dev/null || true
sudo rm -rf /tmp/dcgm* /var/run/dcgm* 2>/dev/null || true
sudo systemctl start nvidia-dcgm

MOTOR_ONLINE=false
for i in {1..5}; do
    if sudo dcgmi discovery -l &>/dev/null; then
        MOTOR_ONLINE=true
        log "Motor DCGM online e comunicando via socket padrao."
        break
    fi
    log "Aguardando motor DCGM responder (tentativa $i/5)..."
    sleep 3
done

if [ "$MOTOR_ONLINE" = false ]; then
    log "ERRO DE SERVICO: O motor nvidia-dcgm nao respondeu. Verificando se houve queda de GPU..."
    check_gpu_health "Pos-Falha Motor DCGM" || exit 2
    exit 1
fi

# Execucao dos niveis solicitados
TOTAL_BENIGN=0
for LEVEL in $(seq 1 "$MAX_LEVEL"); do
    log "=================================================="
    log "Executando Nivel $LEVEL..."
    if [ "$LEVEL" -ge 3 ]; then
        log "NOTA: Nivel $LEVEL aplica estresse intenso e pode derrubar GPUs instaveis no barramento PCIe."
    fi
    log "=================================================="

    OUTPUT_FILE="$BASE_DIR/dcgm/diag-level${LEVEL}_$(date +%Y%m%d_%H%M%S).json"

    DIAG_RC=0
    sudo dcgmi diag -r "$LEVEL" --json > "$OUTPUT_FILE" 2>>"$FULL_LOG" || DIAG_RC=$?

    # 1. Avalia o conteudo do JSON (o codigo de saida sozinho nao distingue hardware de software)
    JSON_OK=false
    if evaluate_dcgm_json "$OUTPUT_FILE"; then
        JSON_OK=true
        TOTAL_BENIGN=$((TOTAL_BENIGN + DIAG_BENIGN))
        if [ "$DIAG_FAILS" -gt 0 ] || [ "$DIAG_MALIGN" -gt 0 ]; then
            log "=================================================="
            log "REPROVADO NO NIVEL $LEVEL: $DIAG_FAILS falha(s) e $DIAG_MALIGN aviso(s) maligno(s). Detalhes acima e em: $OUTPUT_FILE"
            if ! check_gpu_health "Pos-Reprovacao Nivel $LEVEL"; then
                log "DIAGNOSTICO FINAL: O Nivel $LEVEL reprovou e deixou GPU(s) em falha: ${GPU_FAIL_DESC:-estado de GPU degradado}."
                exit 2
            fi
            log "DIAGNOSTICO FINAL: Hardware reprovado no diagnostico DCGM (GPUs ainda visiveis no barramento)."
            exit 3
        fi
    fi

    # 2. dcgmi com erro e sem falha de teste identificavel no JSON: falha do utilitario ou queda de GPU
    if [ "$DIAG_RC" -ne 0 ]; then
        log "ERRO: dcgmi retornou codigo $DIAG_RC no Nivel $LEVEL sem falhas de teste identificaveis no JSON (JSON valido: $JSON_OK)."
        log "Output parcial salvo em: $OUTPUT_FILE"
        if ! check_gpu_health "Pos-Falha Nivel $LEVEL"; then
            log "DIAGNOSTICO FINAL: O Nivel $LEVEL deixou GPU(s) em falha: ${GPU_FAIL_DESC:-estado de GPU degradado}."
            log "Nao re-execute o script sem antes fazer um Reboot completo no servidor."
            exit 2
        fi
        log "DIAGNOSTICO FINAL: As GPUs continuam visiveis no barramento. A falha foi interna do utilitario DCGM/NVVS."
        sudo pkill -9 -f "dcgmi diag|nvvs" 2>/dev/null || true
        exit 1
    fi

    if [ "$JSON_OK" = false ]; then
        log "ERRO: dcgmi retornou sucesso, mas o JSON do Nivel $LEVEL esta vazio ou invalido: $OUTPUT_FILE"
        exit 1
    fi

    # 3. Mesmo com o teste aprovado, valida se nenhuma GPU entrou em estado de Reboot durante o teste
    if ! check_gpu_health "Pos-Nivel $LEVEL"; then
        log "DIAGNOSTICO FINAL: O Nivel $LEVEL deixou GPU(s) em falha: ${GPU_FAIL_DESC:-estado de GPU degradado}."
        exit 2
    fi

    log "Nivel $LEVEL concluido com sucesso ($DIAG_BENIGN aviso(s) benigno(s)). Resultados salvos em: $OUTPUT_FILE"
    sleep 5
done

log "=================================================="
log "Todos os niveis solicitados (1 a $MAX_LEVEL) do Diagnostico DCGM foram concluidos com sucesso! Avisos benignos registrados: $TOTAL_BENIGN"
