#!/bin/bash
# Modulo 5: Benchmark de Inferencia (vLLM Llama-3.3-70B) - v11 (pipefail + deteccao de falha + imagem vLLM fixa + dataset explicito + permissoes do cache HF + modelo configuravel)

set -eo pipefail

BASE_DIR="$HOME/homologacao"
mkdir -p "$BASE_DIR/benchmark"
mkdir -p "$BASE_DIR/logs"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FULL_LOG="$BASE_DIR/logs/vllm_full_${TIMESTAMP}.log"
SUMMARY_LOG="$BASE_DIR/benchmark/vllm_resumo_${TIMESTAMP}.txt"

# Versao fixa da imagem do vLLM (garante resultados comparaveis entre homologacoes)
VLLM_IMAGE="vllm/vllm-openai:v0.34.0"
# Modelo do benchmark (restrito no Hugging Face: a conta do token precisa ter acesso aprovado)
VLLM_MODEL="meta-llama/Llama-3.3-70B-Instruct"

echo "Iniciando Teste de Inferencia vLLM (Llama 3.3 70B)..." | tee -a "$FULL_LOG"
echo "Data: $(date)" | tee -a "$FULL_LOG"

if ! command -v docker &> /dev/null; then
    echo "Erro: Docker nao encontrado. Execute o Modulo 1 primeiro." | tee -a "$FULL_LOG"
    exit 1
fi

if [ -z "$HF_TOKEN" ]; then
    read -p "Insira o seu Hugging Face Access Token: " HF_TOKEN
fi

if [ ! -f "$BASE_DIR/benchmark/ShareGPT_V3_unfiltered_cleaned_split.json" ]; then
    echo "Baixando dataset no diretorio de benchmark..." | tee -a "$FULL_LOG"
    wget -q --show-progress -O "$BASE_DIR/benchmark/ShareGPT_V3_unfiltered_cleaned_split.json" https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
fi

# Cache do Hugging Face: criado pelo usuario antes do container (senao o Docker o cria como root)
# e devolvido ao usuario ao final, mesmo em caso de falha
HF_CACHE="$HOME/.cache/huggingface"
mkdir -p "$HF_CACHE"
trap 'sudo chown -R "$(id -u):$(id -g)" "$HF_CACHE" 2>/dev/null || true' EXIT

echo "Executando o container oficial do vLLM com acesso a todas as GPUs..." | tee -a "$FULL_LOG"

# Fix: O espaco falso (NBSP) e a quebra de linha mal formatada foram corrigidos no comando docker run.
if sudo docker run --rm --gpus all --ipc=host     --entrypoint /bin/bash     -v "$HF_CACHE":/root/.cache/huggingface     -v "$BASE_DIR/benchmark":/workspace     -w /workspace     -e HF_TOKEN="$HF_TOKEN"     -e NCCL_P2P_DISABLE=1     "$VLLM_IMAGE"     -c "vllm bench throughput --backend vllm --model $VLLM_MODEL --tensor-parallel-size 8 --dataset-name sharegpt --dataset-path ShareGPT_V3_unfiltered_cleaned_split.json --num-prompts 1000" 2>&1 | tee -a "$FULL_LOG"; then
    echo "Benchmark de Inferencia concluido!" | tee -a "$FULL_LOG"
else
    echo "ERRO: O benchmark vLLM falhou. Verifique o log completo: $FULL_LOG" | tee -a "$FULL_LOG"
    exit 1
fi

echo "==================================================" > "$SUMMARY_LOG"
echo "RESUMO DO BENCHMARK DE INFERENCIA (vLLM)" >> "$SUMMARY_LOG"
echo "Modelo: $VLLM_MODEL (TP=8)" >> "$SUMMARY_LOG"
echo "Imagem: $VLLM_IMAGE | Digest: $(sudo docker image inspect --format '{{index .RepoDigests 0}}' "$VLLM_IMAGE" 2>/dev/null || echo desconhecido)" >> "$SUMMARY_LOG"
echo "Data da execucao: $(date)" >> "$SUMMARY_LOG"
echo "Host: $(hostname)" >> "$SUMMARY_LOG"
echo "==================================================" >> "$SUMMARY_LOG"

if grep -iq "Throughput" "$FULL_LOG"; then
    grep -i "Throughput" "$FULL_LOG" >> "$SUMMARY_LOG"
else
    echo "Metrica de Throughput nao encontrada de forma explicita no log completo." >> "$SUMMARY_LOG"
fi

echo "==================================================" >> "$SUMMARY_LOG"
echo "Log completo salvo em: $FULL_LOG" >> "$SUMMARY_LOG"

echo ""
cat "$SUMMARY_LOG"
