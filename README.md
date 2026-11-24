# GPU Homolog

Protocolo automatizado de homologação, diagnóstico e benchmark para servidores de IA com múltiplas GPUs NVIDIA (referência: Dell PowerEdge XE7745 com 8× NVIDIA RTX PRO 6000 Blackwell).

A bateria de testes verifica:

- **Saúde do hardware:** GPUs presentes, link PCIe, diagnóstico oficial NVIDIA DCGM.
- **Estabilidade térmica e elétrica (burn-in):** temperatura, throttling, ECC e eventos Xid sob carga.
- **Comunicação entre GPUs:** banda e integridade de dados com NCCL AllReduce.
- **Desempenho real de inferência:** Llama 3.3 70B no vLLM com Tensor Parallelism 8.

Ao final, o orquestrador gera um relatório **APROVADO / REPROVADO** com os motivos e um pacote com todas as evidências.

---

## Pré-requisitos

1. Ubuntu 24.04 (recomendado), x86_64.
2. Acesso root ou sudo.
3. Driver proprietário NVIDIA instalado (`nvidia-smi` funcional), com suporte a **CUDA 12.8 ou superior** (exigência da arquitetura Blackwell).
4. Token do Hugging Face com permissão *Read*, em uma conta que tenha aceitado a licença do modelo `meta-llama/Llama-3.3-70B-Instruct`.
5. Acesso à internet: repositórios apt (Ubuntu, NVIDIA CUDA, NVIDIA Container Toolkit), GitHub, Docker Hub e Hugging Face.

Todo o restante (CUDA Toolkit, NCCL, DCGM 4, Docker, NVIDIA Container Toolkit, jq etc.) é instalado automaticamente pelo Módulo 1.

---

## Início rápido

```bash
git clone https://github.com/ju-lindo-castro/GPU-Homolog.git
cd GPU-Homolog
chmod +x *.sh

# A bateria completa leva várias horas: rode dentro de tmux ou screen
tmux new -s homologacao
./00_homologacao.sh -t <HF_TOKEN>
```

Os resultados ficam em `~/homologacao/relatorios/`.

---

## Scripts

| Arquivo | Módulo | Função |
|---|---|---|
| `00_homologacao.sh` | 0 · Orquestrador | Executa todos os módulos em sequência, analisa a telemetria e gera o relatório final |
| `01_inventario.sh` | 1 · Inventário | Instala dependências, coleta o inventário e audita GPUs, PCIe e containers |
| `02_dcgm_diag_completo.sh` | 2 · DCGM | Diagnóstico oficial NVIDIA (níveis 1 a 4), com avaliação de FAIL/WARN |
| `03_nccl_test.sh` | 3 · NCCL | Banda e integridade da comunicação entre GPUs, com e sem P2P |
| `04_telemetria.sh` | 4 · Telemetria | Coleta em background de temperatura, energia, clocks, PCIe, ECC e log do kernel |
| `05_vllm_benchmark.sh` | 5 · vLLM | Benchmark de inferência com Llama 3.3 70B (TP=8) |

Todos os scripts devem ficar no mesmo diretório.

---

## Fluxo de execução

### Opção 1 — Automatizada (recomendada)

```bash
./00_homologacao.sh -t <HF_TOKEN>
```

O orquestrador roda como root do começo ao fim e executa **todos os módulos, mesmo que algum falhe**. Em um host com problema relatado pelo cliente, todas as evidências são importantes. A sequência é:

1. Inventário e auditoria de hardware (Módulo 1)
2. Início da telemetria (Módulo 4)
3. Diagnóstico DCGM, níveis 1 a 4 (Módulo 2)
4. Teste NCCL (Módulo 3)
5. Benchmark vLLM (Módulo 5)
6. Fim da telemetria e análise do burn-in

Arquivos gerados em `~/homologacao/relatorios/`:

| Arquivo | Conteúdo |
|---|---|
| `relatorio_<host>_<data>.txt` | Veredito e motivos, status e duração de cada etapa, resumo de cada teste, tabela térmica por GPU, versões de software, fabricante, modelo, serial e BIOS do servidor |
| `homologacao_<host>_<data>.tar.gz` | Todos os arquivos gerados na execução (sem o dataset e sem o código do nccl-tests) |
| `00_orquestrador_<host>_<data>.log` | Saída completa de todos os módulos |

### Opção 2 — Manual (módulo a módulo)

1. `./01_inventario.sh`: prossiga somente se o log terminar com `STATUS DO HARDWARE: SAUDAVEL` e sem nenhum `ALERTA CRITICO`.
2. `./04_telemetria.sh start`
3. `./02_dcgm_diag_completo.sh 4`: prossiga somente com código de saída `0`.
4. `./03_nccl_test.sh`: prossiga somente com código de saída `0`.
5. `export HF_TOKEN=<seu_token>` e, em seguida, `./05_vllm_benchmark.sh`
6. `./04_telemetria.sh stop`

Para conferir o código de saída de um módulo, execute `echo $?` logo após o término.

---

## Critérios de reprovação

O servidor é **REPROVADO** se ocorrer qualquer um dos itens abaixo.

| Origem | Critério |
|---|---|
| Inventário | Menos de 8 GPUs no PCIe ou no driver; GPU com link abaixo de Gen5 x16; GPU pendente de reboot (*Recovery Action*); container Docker sem acesso às 8 GPUs |
| DCGM | Qualquer teste com `FAIL`; qualquer `WARN` maligno (ECC, Xid, throttling, PCIe, energia, desempenho abaixo do limite ou aviso não catalogado); GPU caiu do barramento |
| NCCL | Corrupção de dados (`#wrong` ≠ 0 ou `Out of bounds values` ≠ 0) em qualquer rodada; teste incompleto; banda abaixo de `MIN_BUSBW_GBPS` (se definido) |
| vLLM | Falha na execução do benchmark |
| Telemetria | GPU acima de **90 °C**; throttling térmico, HW Slowdown ou Power Brake; GPU que não atinge PCIe Gen5 sob carga; erros ECC não corrigidos; `nvidia-smi` sem resposta |
| Kernel | Xid crítico (48, 61, 62, 63, 64, 74, 79, 92, 94, 95, 119, 120, 154) ou *GPU has fallen off the bus* |

Ficam **apenas registrados**, sem reprovar: o throughput do vLLM, a banda do NCCL (enquanto `MIN_BUSBW_GBPS=0`), a indisponibilidade de P2P, os avisos benignos do DCGM (Persistence Mode, recurso não suportado, modo MIG) e os Xids não críticos.

> O log do kernel é lido desde o boot, então inclui eventos anteriores aos testes. Isso é útil para investigar reclamações do cliente.

---

## Detalhes dos módulos

### Módulo 1 — Inventário e preparação do ambiente

- Configura o repositório oficial NVIDIA CUDA e instala o **CUDA Toolkit** e a **NCCL** na versão alinhada ao CUDA suportado pelo driver (mínimo 12.8). Remove o `nvidia-cuda-toolkit` do Ubuntu, que não suporta Blackwell.
- Instala o **DCGM 4** (`datacenter-gpu-manager-4-cuda<major>`), migrando automaticamente do DCGM 3.x.
- Instala o **Docker** e o **NVIDIA Container Toolkit** (versão fixa `1.20.2-1`) e confirma que um container enxerga as 8 GPUs.
- Coleta o inventário: `nvidia-smi -q`, topologia, PCIe, CPU, memória, discos, `lspci`, IPMI SEL e versões de software.
- Audita a quantidade de GPUs (`EXPECTED_GPUS=8`), o link PCIe de cada GPU (Gen5 x16) e o estado de *Recovery Action*.

### Módulo 2 — Diagnóstico DCGM

```bash
./02_dcgm_diag_completo.sh [NIVEL_MAXIMO]   # padrão: 4
```

- Executa os níveis 1 a 4 em sequência. Os níveis 3 e 4 geram estresse intenso e podem levar horas.
- Antes e depois de cada nível, verifica a saúde das GPUs: contagem no PCIe e no driver, *Recovery Action* e Xid crítico no `dmesg`.
- Lê o JSON de cada nível e lista cada falha ou aviso com o teste, a GPU e a motivação. Avisos benignos são registrados e o teste continua. Para tratar um novo aviso como benigno, adicione o padrão na função `classify_warning`.
- Eleva-se automaticamente para root.

> Em GPUs que não são de datacenter (como a RTX PRO 6000), o DCGM tem funcionalidade limitada e alguns testes podem ser reportados como não suportados. Na primeira execução em um novo modelo, revise o JSON para confirmar quais testes rodaram.

### Módulo 3 — NCCL AllReduce

- Compila o `nccl-tests` para Blackwell (`sm_120`) usando o CUDA e a NCCL do Módulo 1.
- **Rodada 1, com P2P (diagnóstico):** timeout de 10 minutos. Se travar ou falhar, é registrada como "P2P indisponível". Em plataformas com ACS/IOMMU (como o XE7745) o P2P nativo pode ser restrito.
- **Rodada 2, sem P2P (`NCCL_P2P_DISABLE=1`):** é o critério oficial de aprovação.
- Gera `benchmark/nccl_resumo.txt` com a banda das duas rodadas, a integridade dos dados e o commit do `nccl-tests` usado.

### Módulo 4 — Telemetria em background

```bash
./04_telemetria.sh start    # inicia em background
./04_telemetria.sh status   # estado, PID, amostras e eventos de kernel
./04_telemetria.sh stop     # encerra de forma limpa
```

- A cada 5 segundos grava em CSV: temperatura da GPU e da memória, consumo e limite de energia, uso, memória usada, clocks, motivo de redução de clock, geração e largura do PCIe e erros ECC não corrigidos.
- Métricas não suportadas pelo driver ou pela GPU são descartadas na inicialização. Cada chamada ao `nvidia-smi` tem timeout de 10 segundos.
- Um coletor contínuo do `dmesg` acrescenta cada evento NVRM, Xid, AER e PCIe ao log do kernel, sem sobrescrever.

### Módulo 5 — Benchmark de inferência vLLM

- Executa `vllm bench throughput` com o Llama 3.3 70B Instruct, TP=8 e 1.000 prompts do dataset ShareGPT.
- Usa a imagem fixa `vllm/vllm-openai:v0.34.0`, para que os resultados sejam comparáveis entre homologações. A imagem e o digest ficam registrados no resumo.
- O token é lido da variável `HF_TOKEN`; o orquestrador a preenche a partir do `-t`.

---

## Estrutura de diretórios gerada

```
~/homologacao/
├── 01_inventario_log_de_execucao.txt   # Log da preparação e da auditoria de hardware
├── inventario/                         # Hardware, kernel, topologia, PCIe e versões
├── dcgm/                               # JSON de cada nível e log do Módulo 2
├── stress/                             # CSV de telemetria e log do kernel (Módulo 4)
├── benchmark/                          # Saídas e resumos do NCCL e do vLLM, dataset, nccl-tests
├── logs/                               # Log de execução do NCCL e log completo do vLLM
└── relatorios/                         # Relatório final, pacote .tar.gz e log do orquestrador
```

---

## Códigos de saída

| Código | Significado |
|---|---|
| `0` | Aprovado |
| `1` | Erro de software ou de execução (teste incompleto) |
| `2` | GPU caiu do barramento (reboot físico obrigatório). Usado pelo Módulo 2. |
| `3` | Hardware reprovado |

---

## Parâmetros configuráveis

Constantes no início de cada script:

| Constante | Arquivo | Padrão | Descrição |
|---|---|---|---|
| `EXPECTED_GPUS` | 00, 01, 02 | `8` | Quantidade de GPUs esperada |
| `EXPECTED_PCIE_GEN` / `EXPECTED_PCIE_WIDTH` | 01 (`GEN` também em 00) | `5` / `16` | Link PCIe esperado |
| `MIN_CUDA_VERSION` | 01 | `12.8` | CUDA mínimo suportado pelo driver |
| `NVIDIA_CTK_VERSION` | 01 | `1.20.2-1` | Versão do NVIDIA Container Toolkit |
| `MAX_GPU_TEMP_C` | 00 | `90` | Temperatura máxima aceitável no burn-in |
| `LOAD_UTIL_PCT` | 00 | `50` | Uso mínimo para uma amostra contar como "sob carga" |
| `CRITICAL_XIDS` | 00 | ver script | Xids que reprovam o servidor |
| `MIN_BUSBW_GBPS` | 03 | `0` | Banda mínima do NCCL sem P2P (`0` = apenas registra) |
| `P2P_TIMEOUT` | 03 | `600` | Tempo máximo, em segundos, da rodada com P2P |
| `NCCL_TESTS_REF` | 03 | vazio | Commit ou tag do nccl-tests (vazio = ramo principal) |
| `INTERVAL` | 04 | `5` | Intervalo da telemetria, em segundos |
| `VLLM_IMAGE` | 05 | `vllm/vllm-openai:v0.34.0` | Imagem do vLLM |

---

## Próximos passos

- Definir `MIN_BUSBW_GBPS` e uma referência de throughput do vLLM a partir de um servidor aprovado.
- Definir a forma de entrega automática do relatório e do pacote de evidências.
