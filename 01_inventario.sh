#!/bin/bash
# Modulo 1: Inventario e Preparacao do Ambiente (v13 - Driver NVIDIA automatico, DCGM 4, CUDA/NCCL alinhados ao driver, Docker/NVIDIA Container Toolkit, Auditoria PCIe e de GPUs)
# Codigos de saida: 0 = concluido | 1 = falha critica | 4 = driver NVIDIA instalado, reboot necessario

BASE_DIR="$HOME/homologacao"
mkdir -p "$BASE_DIR"/{inventario,dcgm,stress,benchmark,logs}

# Quantidade de GPUs que o servidor deve ter (padrao da homologacao)
EXPECTED_GPUS=8

LOG_FILE="$BASE_DIR/01_inventario_log_de_execucao.txt"
> "$LOG_FILE"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "--- Iniciando Script de Inventario (v13) ---"

# 0. Correcao para imagens limpas (Minimal/Server) do Ubuntu
log "Etapa: Preparacao base do sistema (apt-utils e correcao Java/Manpages) - Iniciado"
sudo apt-get update -y &>/dev/null || true

if ! dpkg -s "apt-utils" >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y apt-utils &>/dev/null || true
fi

if [ ! -d "/usr/share/man/man1" ]; then
    sudo mkdir -p /usr/share/man/man1
fi

sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y &>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a &>/dev/null || true
log "Etapa: Preparacao base do sistema - Finalizado"

check_and_install() {
    local cmd="$1"
    local pkg="$2"

    log "Etapa: Verificacao da ferramenta '$cmd' - Iniciado"
    if ! command -v "$cmd" &> /dev/null; then
        log "Etapa: Verificacao da ferramenta '$cmd' - Ausente. Instalando pacote '$pkg'..."
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" &>/tmp/err_install_${cmd}.log; then
            log "Etapa: Verificacao da ferramenta '$cmd' - Finalizado (Instalado com sucesso)"
        else
            ERR=$(tr '\n' ' ' < /tmp/err_install_${cmd}.log | sed 's/ *$//' | tail -c 250)
            log "Etapa: Verificacao da ferramenta '$cmd' - Erro: Falha na instalacao: $ERR"
        fi
    else
        log "Etapa: Verificacao da ferramenta '$cmd' - Finalizado (Ja instalado)"
    fi
}

check_and_install "wget" "wget"
check_and_install "curl" "curl"
check_and_install "lspci" "pciutils"
check_and_install "ipmitool" "ipmitool"
check_and_install "lscpu" "util-linux"
check_and_install "dmidecode" "dmidecode"

# ==============================================================================
# Repositorio oficial NVIDIA (CUDA) - usado pelo CUDA Toolkit, NCCL e DCGM
# ==============================================================================
log "Etapa: Repositorio NVIDIA CUDA (cuda-keyring) - Iniciado"
if dpkg -s cuda-keyring &>/dev/null; then
    log "Etapa: Repositorio NVIDIA CUDA (cuda-keyring) - Finalizado (Ja configurado)"
else
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID | sed -e 's/\.//g')
    if wget -q https://developer.download.nvidia.com/compute/cuda/repos/$distribution/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb \
        && sudo dpkg -i /tmp/cuda-keyring.deb &>/tmp/err_keyring.log; then
        sudo apt-get update -y &>/dev/null || true
        log "Etapa: Repositorio NVIDIA CUDA (cuda-keyring) - Finalizado (Configurado com sucesso)"
    else
        log "Etapa: Repositorio NVIDIA CUDA (cuda-keyring) - Erro: Falha ao configurar o repositorio para '$distribution'."
    fi
fi

# ==============================================================================
# Driver NVIDIA: instalado automaticamente (open kernel modules) quando ausente.
# Codigo de saida 4 = driver instalado ou pendente: REBOOT necessario.
# ==============================================================================
DRIVER_PIN=""          # opcional: fixa um branch do driver (ex.: 580); vazio = mais recente do repositorio
REBOOT_COUNTDOWN=60    # segundos de aviso antes do reboot (Ctrl+C cancela)

request_reboot() {
    log "=================================================================="
    log "REBOOT NECESSARIO: $1"
    log "Depois que o servidor voltar, execute novamente o MESMO comando para continuar a homologacao."
    log "=================================================================="
    if [ -n "$HOMOLOG_ORQUESTRADOR" ]; then
        exit 4   # o orquestrador registra o relatorio e faz o reboot
    fi
    log "ATENCAO: o servidor sera REINICIADO em ${REBOOT_COUNTDOWN}s. Pressione Ctrl+C para cancelar."
    sleep "$REBOOT_COUNTDOWN" && sudo reboot
    exit 4
}

log "Etapa: Verificacao NVIDIA Driver (nvidia-smi) - Iniciado"
PCI_NV=$(lspci -d 10de: -nn 2>/dev/null | grep -cE "\[(0300|0302)\]" || true)
if command -v nvidia-smi &> /dev/null && timeout 30 nvidia-smi -L &> /dev/null; then
    log "Etapa: Verificacao NVIDIA Driver (nvidia-smi) - Finalizado (driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1))"
elif command -v nvidia-smi &> /dev/null && dpkg -s nvidia-open &> /dev/null && [ ! -e /proc/driver/nvidia/version ]; then
    # Driver instalado (provavelmente pelo proprio script) mas modulo do kernel ainda nao carregado
    log "Etapa: Verificacao NVIDIA Driver (nvidia-smi) - Aviso: driver instalado, mas o modulo do kernel nao esta carregado."
    request_reboot "o driver NVIDIA esta instalado, mas so passa a funcionar apos reiniciar o servidor."
elif command -v nvidia-smi &> /dev/null; then
    # Driver carregado mas sem resposta: possivel GPU caida, tratado pela auditoria e pelo Modulo 2
    ERR=$(timeout 30 nvidia-smi -L 2>&1 | tr '\n' ' ' | head -c 200)
    log "Etapa: Verificacao NVIDIA Driver (nvidia-smi) - Erro: driver instalado, mas o nvidia-smi falhou: $ERR"
else
    log "Etapa: Verificacao NVIDIA Driver (nvidia-smi) - Ausente. $PCI_NV GPU(s) NVIDIA no barramento PCIe."
    if [ "$PCI_NV" -eq 0 ]; then
        log "Falha Critica: nenhuma GPU NVIDIA encontrada no barramento PCIe. Abortando."
        exit 1
    fi
    if command -v mokutil &> /dev/null && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        log "AVISO: Secure Boot habilitado. O modulo do driver pode nao carregar sem cadastrar a chave MOK; se isso ocorrer, desabilite o Secure Boot na BIOS."
    fi
    log "Etapa: Instalacao do driver NVIDIA (open kernel modules) - Iniciado"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$(uname -r)" &>/tmp/err_driver_install.log || true
    if [ -n "$DRIVER_PIN" ]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "nvidia-driver-pinning-$DRIVER_PIN" &>>/tmp/err_driver_install.log \
            || log "Etapa: Instalacao do driver NVIDIA - Aviso: nao foi possivel fixar o branch $DRIVER_PIN."
    fi
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-open &>>/tmp/err_driver_install.log; then
        log "Etapa: Instalacao do driver NVIDIA (open kernel modules) - Finalizado (instalado com sucesso)"
        request_reboot "o driver NVIDIA acabou de ser instalado e so passa a funcionar apos reiniciar o servidor."
    else
        ERR=$(tr '\n' ' ' < /tmp/err_driver_install.log | tail -c 250)
        log "Etapa: Instalacao do driver NVIDIA (open kernel modules) - Erro: $ERR"
        log "Falha Critica: nao foi possivel instalar o driver NVIDIA automaticamente. Instale-o manualmente e reinicie o servidor. Abortando."
        exit 1
    fi
fi


# ==============================================================================
# CUDA Toolkit (versao alinhada ao driver; minimo 12.8 para Blackwell) + NCCL
# ==============================================================================
MIN_CUDA_VERSION="12.8"

# Retorna sucesso se a versao $1 for maior ou igual a $2
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# Remove o CUDA antigo do Ubuntu (12.0, sem suporte a Blackwell) para evitar dois nvcc no sistema
if dpkg -s nvidia-cuda-toolkit &>/dev/null; then
    log "Etapa: Remocao do nvidia-cuda-toolkit do Ubuntu - Iniciado"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y nvidia-cuda-toolkit &>/tmp/err_remove_cuda.log; then
        log "Etapa: Remocao do nvidia-cuda-toolkit do Ubuntu - Finalizado"
    else
        ERR=$(tr '\n' ' ' < /tmp/err_remove_cuda.log | tail -c 250)
        log "Etapa: Remocao do nvidia-cuda-toolkit do Ubuntu - Erro: $ERR"
    fi
fi

# Versao maxima de CUDA suportada pelo driver (compativel com o formato antigo e o novo do driver 620+)
get_driver_cuda() {
    local v
    v=$(nvidia-smi -q 2>/dev/null | grep -oE "CUDA UMD Version *: *[0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+$" | head -n1)
    [ -z "$v" ] && v=$(nvidia-smi -q 2>/dev/null | grep -oE "CUDA Version *: *[0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+$" | head -n1)
    [ -z "$v" ] && v=$(nvidia-smi 2>/dev/null | grep -oE "CUDA (UMD )?Version: *[0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+$" | head -n1)
    if [ -z "$v" ] && command -v python3 &> /dev/null; then
        v=$(python3 -c 'import ctypes; l = ctypes.CDLL("libcuda.so.1"); x = ctypes.c_int(); l.cuDriverGetVersion(ctypes.byref(x)); print("%d.%d" % (x.value // 1000, (x.value % 1000) // 10))' 2>/dev/null)
    fi
    echo "$v"
}
DRIVER_CUDA=$(get_driver_cuda)
CUDA_VER=""
log "Etapa: Instalacao do CUDA Toolkit - Iniciado (driver suporta ate CUDA ${DRIVER_CUDA:-desconhecido})"
if [ -z "$DRIVER_CUDA" ]; then
    log "Etapa: Instalacao do CUDA Toolkit - Erro: nao foi possivel ler a versao de CUDA suportada pelo driver."
elif ! version_ge "$DRIVER_CUDA" "$MIN_CUDA_VERSION"; then
    log "ALERTA CRITICO DE SOFTWARE: o driver suporta apenas CUDA $DRIVER_CUDA (minimo $MIN_CUDA_VERSION para Blackwell). Atualize o driver NVIDIA."
else
    # Maior cuda-toolkit-X-Y do repositorio que nao ultrapasse a versao suportada pelo driver
    CUDA_VER=$(apt-cache pkgnames cuda-toolkit- 2>/dev/null | grep -E "^cuda-toolkit-[0-9]+-[0-9]+$" \
        | sed -E 's/^cuda-toolkit-([0-9]+)-([0-9]+)$/\1.\2/' | sort -V \
        | while read -r v; do version_ge "$DRIVER_CUDA" "$v" && version_ge "$v" "$MIN_CUDA_VERSION" && echo "$v"; done | tail -n1)

    if [ -z "$CUDA_VER" ]; then
        log "Etapa: Instalacao do CUDA Toolkit - Erro: nenhum cuda-toolkit entre $MIN_CUDA_VERSION e $DRIVER_CUDA disponivel no repositorio."
    else
        CUDA_PKG="cuda-toolkit-${CUDA_VER/./-}"
        if dpkg -s "$CUDA_PKG" &>/dev/null; then
            log "Etapa: Instalacao do CUDA Toolkit - Finalizado ($CUDA_PKG ja instalado)"
        elif sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$CUDA_PKG" &>/tmp/err_cuda_install.log; then
            log "Etapa: Instalacao do CUDA Toolkit - Finalizado ($CUDA_PKG instalado com sucesso)"
        else
            ERR=$(tr '\n' ' ' < /tmp/err_cuda_install.log | tail -c 250)
            log "Etapa: Instalacao do CUDA Toolkit - Erro: Falha na instalacao de $CUDA_PKG: $ERR"
            CUDA_VER=""
        fi
        # Garante que /usr/local/cuda aponte para a versao escolhida
        [ -n "$CUDA_VER" ] && [ -d "/usr/local/cuda-$CUDA_VER" ] && sudo update-alternatives --set cuda "/usr/local/cuda-$CUDA_VER" &>/dev/null || true
    fi
fi

if [ -n "$CUDA_VER" ]; then
    log "Etapa: Instalacao da NCCL (build para CUDA $CUDA_VER) - Iniciado"
    NCCL_CANDIDATES=$(apt-cache madison libnccl2 2>/dev/null | awk -F'|' '{gsub(/ /, "", $2); print $2}')
    # Preferencia: build exato para a versao do CUDA; senao, o maior build do mesmo major sem ultrapassa-la
    NCCL_VER=$(echo "$NCCL_CANDIDATES" | grep -E "\+cuda${CUDA_VER}$" | sort -V | tail -n1)
    if [ -z "$NCCL_VER" ]; then
        NCCL_VER=$(echo "$NCCL_CANDIDATES" | grep -E "\+cuda${CUDA_VER%%.*}\.[0-9]+$" \
            | while read -r v; do version_ge "$CUDA_VER" "${v##*+cuda}" && echo "$v"; done | sort -V | tail -n1)
    fi
    NCCL_INSTALLED=$(dpkg-query -W -f='${Version}' libnccl2 2>/dev/null || true)

    if [ -z "$NCCL_VER" ]; then
        log "Etapa: Instalacao da NCCL - Erro: nenhuma versao de libnccl2 compativel com CUDA $CUDA_VER no repositorio."
    elif [ "$NCCL_INSTALLED" = "$NCCL_VER" ] && dpkg -s libnccl-dev &>/dev/null; then
        log "Etapa: Instalacao da NCCL - Finalizado ($NCCL_VER ja instalada)"
    elif sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "libnccl2=$NCCL_VER" "libnccl-dev=$NCCL_VER" &>/tmp/err_nccl_install.log; then
        log "Etapa: Instalacao da NCCL - Finalizado ($NCCL_VER instalada com sucesso)"
    else
        ERR=$(tr '\n' ' ' < /tmp/err_nccl_install.log | tail -c 250)
        log "Etapa: Instalacao da NCCL - Erro: Falha na instalacao de $NCCL_VER: $ERR"
    fi
fi

# ==============================================================================
# DCGM 4 (pacote alinhado a versao principal do CUDA do driver; migra do DCGM 3.x)
# ==============================================================================
DRIVER_CUDA_MAJOR="${DRIVER_CUDA%%.*}"
DCGM_PKG="datacenter-gpu-manager-4-cuda${DRIVER_CUDA_MAJOR}"
log "Etapa: Verificacao de instalacao do DCGM 4 ($DCGM_PKG) - Iniciado"
if [ -z "$DRIVER_CUDA_MAJOR" ]; then
    log "Etapa: Verificacao de instalacao do DCGM 4 - Erro: versao de CUDA do driver desconhecida; nao e possivel escolher o pacote."
elif dpkg -s "$DCGM_PKG" &>/dev/null; then
    log "Etapa: Verificacao de instalacao do DCGM 4 ($DCGM_PKG) - Finalizado (Ja instalado)"
else
    # Migracao: remove o DCGM 3.x conforme o procedimento oficial da NVIDIA
    if dpkg -s datacenter-gpu-manager &>/dev/null || dpkg -s datacenter-gpu-manager-config &>/dev/null; then
        log "Etapa: Migracao do DCGM 3.x para o DCGM 4 - Removendo pacotes antigos..."
        sudo systemctl stop nvidia-dcgm &>/dev/null || true
        if sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y datacenter-gpu-manager datacenter-gpu-manager-config &>/tmp/err_dcgm_purge.log; then
            log "Etapa: Migracao do DCGM 3.x para o DCGM 4 - DCGM 3.x removido"
        else
            ERR=$(tr '\n' ' ' < /tmp/err_dcgm_purge.log | tail -c 250)
            log "Etapa: Migracao do DCGM 3.x para o DCGM 4 - Aviso: falha ao remover o DCGM 3.x: $ERR"
        fi
    fi

    log "Etapa: Verificacao de instalacao do DCGM 4 ($DCGM_PKG) - Ausente. Iniciando instalacao oficial..."
    sudo apt-get update -y &>/dev/null || true
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends "$DCGM_PKG" &>/tmp/err_dcgm_install.log; then
        sudo systemctl enable --now nvidia-dcgm &>/dev/null || true
        log "Etapa: Verificacao de instalacao do DCGM 4 ($DCGM_PKG) - Finalizado (Instalado com sucesso)"
    else
        ERR=$(tr '\n' ' ' < /tmp/err_dcgm_install.log | tail -c 250)
        log "Etapa: Verificacao de instalacao do DCGM 4 ($DCGM_PKG) - Erro: Falha na instalacao: $ERR"
    fi
fi

# Garante que o servico DCGM (nv-hostengine) esteja ativo apos reboot
if command -v dcgmi &> /dev/null; then
    log "Etapa: Inicializacao do servico DCGM (nvidia-dcgm) - Iniciado"
    if sudo dcgmi discovery -l &>/dev/null; then
        log "Etapa: Inicializacao do servico DCGM (nvidia-dcgm) - Finalizado (Ja estava ativo)"
    else
        sudo systemctl enable --now nvidia-dcgm &>/dev/null || true
        DCGM_READY=false
        for i in {1..5}; do
            if sudo dcgmi discovery -l &>/dev/null; then
                DCGM_READY=true
                break
            fi
            sleep 1
        done

        if [ "$DCGM_READY" = false ] && command -v nv-hostengine &> /dev/null; then
            sudo nv-hostengine &>/dev/null &
            sleep 2
            sudo dcgmi discovery -l &>/dev/null && DCGM_READY=true
        fi

        if [ "$DCGM_READY" = true ]; then
            log "Etapa: Inicializacao do servico DCGM (nvidia-dcgm) - Finalizado (Servico iniciado com sucesso)"
        else
            log "Etapa: Inicializacao do servico DCGM (nvidia-dcgm) - Aviso: Nao foi possivel conectar ao host engine."
        fi
    fi
fi

# ==============================================================================
# Docker + NVIDIA Container Toolkit (necessarios para o Modulo 5 - vLLM)
# ==============================================================================
NVIDIA_CTK_VERSION="1.20.2-1"

log "Etapa: Verificacao do Docker - Iniciado"
if ! command -v docker &> /dev/null; then
    log "Etapa: Verificacao do Docker - Ausente. Instalando pacote 'docker.io'..."
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io &>/tmp/err_docker_install.log; then
        log "Etapa: Verificacao do Docker - Finalizado (Instalado com sucesso)"
    else
        ERR=$(tr '\n' ' ' < /tmp/err_docker_install.log | tail -c 250)
        log "Etapa: Verificacao do Docker - Erro: Falha na instalacao: $ERR"
    fi
else
    log "Etapa: Verificacao do Docker - Finalizado (Ja instalado)"
fi
if command -v docker &> /dev/null; then
    sudo systemctl enable --now docker &>/dev/null || log "Etapa: Servico Docker - Aviso: nao foi possivel ativar o servico."
fi

log "Etapa: Verificacao do NVIDIA Container Toolkit (nvidia-ctk) - Iniciado"
if ! command -v nvidia-ctk &> /dev/null; then
    log "Etapa: Verificacao do NVIDIA Container Toolkit (nvidia-ctk) - Ausente. Configurando repositorio oficial e instalando versao $NVIDIA_CTK_VERSION..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg2 &>/dev/null || true
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -y &>/dev/null || true

    CTK_PKGS="nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1"
    CTK_PINNED=""
    for p in $CTK_PKGS; do CTK_PINNED="$CTK_PINNED $p=$NVIDIA_CTK_VERSION"; done

    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $CTK_PINNED &>/tmp/err_ctk_install.log; then
        log "Etapa: Verificacao do NVIDIA Container Toolkit (nvidia-ctk) - Finalizado (Instalada a versao $NVIDIA_CTK_VERSION)"
    elif sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $CTK_PKGS &>>/tmp/err_ctk_install.log; then
        log "Etapa: Verificacao do NVIDIA Container Toolkit (nvidia-ctk) - Aviso: versao $NVIDIA_CTK_VERSION indisponivel no repositorio; instalada a versao mais recente."
    else
        ERR=$(tr '\n' ' ' < /tmp/err_ctk_install.log | tail -c 250)
        log "Etapa: Verificacao do NVIDIA Container Toolkit (nvidia-ctk) - Erro: Falha na instalacao: $ERR"
    fi
else
    log "Etapa: Verificacao do NVIDIA Container Toolkit (nvidia-ctk) - Finalizado (Ja instalado)"
fi

if command -v docker &> /dev/null && command -v nvidia-ctk &> /dev/null; then
    # Configura o runtime NVIDIA no Docker apenas se ainda nao estiver registrado (evita reiniciar o Docker a toa)
    log "Etapa: Configuracao do runtime NVIDIA no Docker - Iniciado"
    # Verifica o runtime registrado (a saida completa do docker info cita "nvidia" mesmo sem o runtime configurado)
    if sudo docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
        log "Etapa: Configuracao do runtime NVIDIA no Docker - Finalizado (Ja configurado)"
    elif sudo nvidia-ctk runtime configure --runtime=docker &>/tmp/err_ctk_config.log && sudo systemctl restart docker &>>/tmp/err_ctk_config.log; then
        log "Etapa: Configuracao do runtime NVIDIA no Docker - Finalizado (Configurado e Docker reiniciado)"
    else
        ERR=$(tr '\n' ' ' < /tmp/err_ctk_config.log | tail -c 250)
        log "Etapa: Configuracao do runtime NVIDIA no Docker - Erro: $ERR"
    fi

    # Valida se o container enxerga todas as GPUs esperadas (requisito do Modulo 5)
    log "Etapa: Validacao de GPUs dentro do container Docker - Iniciado"
    CONTAINER_OUT=$(sudo docker run --rm --gpus all ubuntu nvidia-smi -L 2>&1 || true)
    CONTAINER_GPUS=$(echo "$CONTAINER_OUT" | grep -cE "^GPU [0-9]+:" || true)
    if [ "$CONTAINER_GPUS" -lt "$EXPECTED_GPUS" ]; then
        # Autocorrecao: reconfigura o runtime NVIDIA, reinicia o Docker e tenta mais uma vez
        log "Etapa: Validacao de GPUs dentro do container Docker - Aviso: $CONTAINER_GPUS/$EXPECTED_GPUS GPUs; reconfigurando o runtime NVIDIA e tentando novamente..."
        sudo nvidia-ctk runtime configure --runtime=docker &>>/tmp/err_ctk_config.log
        sudo systemctl restart docker &>>/tmp/err_ctk_config.log
        sleep 5
        CONTAINER_OUT=$(sudo docker run --rm --gpus all ubuntu nvidia-smi -L 2>&1 || true)
        CONTAINER_GPUS=$(echo "$CONTAINER_OUT" | grep -cE "^GPU [0-9]+:" || true)
    fi
    if [ "$CONTAINER_GPUS" -ge "$EXPECTED_GPUS" ]; then
        log "Etapa: Validacao de GPUs dentro do container Docker - Finalizado ($CONTAINER_GPUS/$EXPECTED_GPUS GPUs visiveis)"
    else
        ERR=$(echo "$CONTAINER_OUT" | tr '\n' ' ' | tail -c 250)
        log "ALERTA CRITICO DE CONTAINER: apenas $CONTAINER_GPUS/$EXPECTED_GPUS GPUs visiveis dentro do Docker. O Modulo 5 (vLLM) vai falhar. Detalhe: $ERR"
    fi
else
    log "ALERTA CRITICO DE CONTAINER: Docker ou NVIDIA Container Toolkit indisponivel. O Modulo 5 (vLLM) nao podera ser executado."
fi

# Funcao aprimorada de coleta: captura stdout + stderr e nunca deixa "Erro: " vazio
collect_data() {
    local step_name="$1"
    local command_to_run="$2"
    local output_file="$3"

    log "Etapa: $step_name - Iniciado"
    if eval "$command_to_run" > "$output_file" 2>&1; then
        log "Etapa: $step_name - Finalizado"
    else
        ERR=$(tr '\n' ' ' < "$output_file" | sed 's/ *$//' | head -c 250)
        [ -z "$ERR" ] && ERR="Codigo de retorno diferente de zero sem mensagem."
        log "Etapa: $step_name - Erro: $ERR"
    fi
}

collect_data "Coleta Data" "date -Is" "$BASE_DIR/inventario/data.txt"
collect_data "Coleta NVIDIA SMI Q" "nvidia-smi -q" "$BASE_DIR/inventario/nvidia-smi-q.txt"
collect_data "Coleta Topologia NVIDIA" "nvidia-smi topo -m" "$BASE_DIR/inventario/topologia.txt"
collect_data "Coleta Lista de GPUs" "nvidia-smi -L" "$BASE_DIR/inventario/gpus.txt"
collect_data "Coleta Status PCIe" "nvidia-smi --query-gpu=index,name,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,memory.total,power.limit --format=csv" "$BASE_DIR/inventario/pcie_status.txt"

if command -v dcgmi &> /dev/null; then
    collect_data "Coleta DCGM Discovery" "sudo dcgmi discovery -l" "$BASE_DIR/inventario/dcgm-discovery.txt"
    collect_data "Coleta DCGM Version" "dcgmi --version; dpkg -l 'datacenter-gpu-manager*' | grep '^ii'" "$BASE_DIR/inventario/dcgm-version.txt"
fi

if [ -x /usr/local/cuda/bin/nvcc ]; then
    collect_data "Coleta CUDA Version" "/usr/local/cuda/bin/nvcc --version" "$BASE_DIR/inventario/cuda-version.txt"
fi
collect_data "Coleta NCCL Version" "dpkg-query -W -f='\${Package} \${Version}\n' libnccl2 libnccl-dev" "$BASE_DIR/inventario/nccl-version.txt"

if command -v docker &> /dev/null; then
    collect_data "Coleta Docker / NVIDIA Container Toolkit Version" "docker --version; nvidia-ctk --version" "$BASE_DIR/inventario/docker-version.txt"
fi

collect_data "Coleta Kernel Info" "uname -a" "$BASE_DIR/inventario/kernel.txt"
collect_data "Coleta CPU Info" "lscpu" "$BASE_DIR/inventario/lscpu.txt"
collect_data "Coleta Memoria RAM" "free -h" "$BASE_DIR/inventario/free.txt"
collect_data "Coleta Discos" "lsblk" "$BASE_DIR/inventario/lsblk.txt"
collect_data "Coleta Dispositivos PCI" "lspci -nn" "$BASE_DIR/inventario/lspci.txt"

if command -v ipmitool &> /dev/null; then
    collect_data "Coleta IPMI SEL (Logs BMC)" "sudo ipmitool sel elist" "$BASE_DIR/inventario/ipmi_sel.txt"
fi

# ==============================================================================
# Validacao do link PCIe de cada GPU (largura atual e geracao maxima do link)
# A geracao ATUAL cai com a GPU ociosa (economia de energia), por isso valida-se
# a geracao MAXIMA do link; a geracao sob carga e verificada na telemetria.
# A geracao esperada e o maximo suportado pela propria GPU (ex.: L40S = Gen4,
# RTX PRO 6000 Blackwell = Gen5): reprova quando a plataforma limita a GPU.
# EXPECTED_PCIE_GEN so e usado se o driver nao informar o maximo da GPU.
# ==============================================================================
EXPECTED_PCIE_GEN=5
EXPECTED_PCIE_WIDTH=16
PCIE_FAIL=0

PCIE_FIELDS="index,pci.bus_id,pcie.link.gen.max,pcie.link.width.current,pcie.link.gen.gpumax"
nvidia-smi --query-gpu=pcie.link.gen.gpumax --format=csv,noheader &> /dev/null || PCIE_FIELDS="index,pci.bus_id,pcie.link.gen.max,pcie.link.width.current"

log "--- Validacao do Link PCIe (esperado: geracao maxima suportada pela GPU, x$EXPECTED_PCIE_WIDTH) ---"
while IFS=', ' read -r idx bus gen_max width_cur gpu_gen_max; do
    exp_gen="$EXPECTED_PCIE_GEN"
    [[ "$gpu_gen_max" =~ ^[0-9]+$ ]] && exp_gen="$gpu_gen_max"
    if ! [[ "$gen_max" =~ ^[0-9]+$ && "$width_cur" =~ ^[0-9]+$ ]]; then
        log "GPU $idx ($bus): ERRO - nao foi possivel ler o link PCIe (gen_max=$gen_max, width=$width_cur)"
        PCIE_FAIL=$((PCIE_FAIL + 1))
    elif [ "$width_cur" -lt "$EXPECTED_PCIE_WIDTH" ] || [ "$gen_max" -lt "$exp_gen" ]; then
        log "GPU $idx ($bus): FALHA - link Gen$gen_max x$width_cur (esperado Gen$exp_gen x$EXPECTED_PCIE_WIDTH)"
        PCIE_FAIL=$((PCIE_FAIL + 1))
    else
        log "GPU $idx ($bus): OK - Gen$gen_max x$width_cur (maximo da GPU: Gen$exp_gen)"
    fi
done < <(nvidia-smi --query-gpu="$PCIE_FIELDS" --format=csv,noheader,nounits 2>/dev/null)

# ==============================================================================
# Auditoria de Integridade Pos-Coleta (Alerta imediato de GPU caida/Reboot)
# ==============================================================================
log "--- Auditoria de Integridade do Hardware ---"
PCI_GPUS=$(lspci -d 10de: -nn 2>/dev/null | grep -cE "\[(0300|0302)\]" || true)
SMI_GPUS=$(grep -cE "^GPU [0-9]+:" "$BASE_DIR/inventario/gpus.txt" 2>/dev/null || true)
RECOVERY_NEEDED=$(grep "GPU Recovery Action" "$BASE_DIR/inventario/nvidia-smi-q.txt" 2>/dev/null | grep -v "None" || true)

log "GPUs esperadas: $EXPECTED_GPUS | GPUs no barramento PCIe (lspci): $PCI_GPUS | GPUs saudaveis no driver: $SMI_GPUS"

if [ "$PCI_GPUS" -lt "$EXPECTED_GPUS" ]; then
    log "ALERTA CRITICO DE HARDWARE: Esperadas $EXPECTED_GPUS GPUs, mas apenas $PCI_GPUS aparecem no barramento PCIe!"
    log "RECOMENDACAO: GPU ausente do barramento. Verifique encaixe/riser, cabos de energia e configuracao PCIe na BIOS. Um reboot pode nao resolver."
elif [ "$SMI_GPUS" -lt "$PCI_GPUS" ] || grep -qiE "Unknown Error|Unable to determine" "$BASE_DIR/inventario/gpus.txt" 2>/dev/null; then
    log "ALERTA CRITICO DE HARDWARE: Nem todas as GPUs estao acessiveis pelo driver! Verifique $BASE_DIR/inventario/gpus.txt"
    log "RECOMENDACAO: Execute um REBOOT FISICO no servidor antes de iniciar qualquer teste."
elif [ -n "$RECOVERY_NEEDED" ]; then
    log "ALERTA CRITICO DE DRIVER: Uma ou mais GPUs exigem reinicializacao (GPU Recovery Action != None)."
    log "RECOMENDACAO: Execute um REBOOT FISICO no servidor antes de iniciar qualquer teste."
elif [ "$PCIE_FAIL" -gt 0 ]; then
    log "ALERTA CRITICO DE PCIe: $PCIE_FAIL GPU(s) com link degradado. Verifique encaixe/riser, slot e configuracao PCIe na BIOS."
else
    log "STATUS DO HARDWARE: SAUDAVEL ($SMI_GPUS/$EXPECTED_GPUS GPUs operacionais e sem pendencia de reboot)."
fi

log "--- Script de Inventario Concluido ---"
