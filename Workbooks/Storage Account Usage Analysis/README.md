# Análise de Uso de Storage Accounts com Private Endpoints

Workbook do Azure Monitor para identificar Storage Accounts que possuem Private Endpoints e analisar seus padrões de uso, ajudando a identificar contas sem uso como candidatas à remoção ou realocação.

## Objetivo

Em ambientes com muitos Private Endpoints, a maioria costuma pertencer a Storage Accounts. Este workbook ajuda a responder:

- **Quais Storage Accounts possuem Private Endpoints?**
- **Estão sendo utilizados?** (via métricas de Transactions)
- **Qual o ambiente (Produção, Desenvolvimento, etc.)?** (via tags `ambiente`/`environment`)
- **Em quais VNETs estão conectados?**
- **Qual o volume de dados armazenado?** (via UsedCapacity)

## Tabs

| Tab | Descrição |
|-----|-----------|
| **📋 Inventário** | Grid com todos os Storage Accounts que possuem PEs, mostrando ambiente, VNET, sub-rede, assinatura, grupo de recursos, tipo, SKU. Tiles de resumo. |
| **📊 Análise de Uso** | Selecione Storage Accounts para ver métricas do Azure Monitor: **Transactions**, **UsedCapacity**, **Ingress**, **Egress** ao longo do tempo. |
| **🏷️ Por Ambiente** | Distribuição por tag de ambiente. Pie chart + grid resumo + detalhe agrupado. |

## Métricas Utilizadas

| Métrica | Agregação | O que mostra |
|---------|-----------|--------------|
| **Transactions** | Sum | Total de requisições ao storage. **0 = não está sendo usado** |
| **UsedCapacity** | Average | Volume de dados armazenados (bytes) |
| **Ingress** | Sum | Volume de dados recebidos |
| **Egress** | Sum | Volume de dados enviados |

> **Fonte**: [Métricas do Azure Storage no Azure Monitor](https://learn.microsoft.com/pt-br/azure/storage/common/storage-metrics-in-azure-monitor)

## Requisitos

- **Acesso mínimo**: Role **Reader** nas assinaturas (inclui `Microsoft.Insights/metrics/read`)
- **Tags suportadas**: `ambiente`, `Ambiente`, `AMBIENTE`, `environment`, `Environment`, `ENVIRONMENT`
- **Idioma**: Português (Brasil)

## Como Usar

1. Abra o workbook no Azure Portal
2. Selecione as assinaturas desejadas
3. Na tab **Inventário**, veja todos os Storage Accounts com PEs
4. Na tab **Análise de Uso**, selecione contas específicas para verificar métricas
5. Contas com **0 Transactions** durante 30 dias são candidatas à remoção
6. Na tab **Por Ambiente**, priorize ambientes de dev/hml para análise

## Como Identificar Contas para Remoção

1. **Transactions = 0** por 30+ dias → ninguém está acessando
2. **UsedCapacity > 0** com **Transactions = 0** → dados armazenados sem acesso ativo (verificar se precisa migrar)
3. **UsedCapacity = 0** com **Transactions = 0** → candidato direto à remoção
4. **Ambiente = dev/hml/stg** → priorizar análise de ambientes não-produtivos

> ⚠️ **Atenção**: Sempre verifique se não existem processos batch, pipelines ou backups que acessam a conta periodicamente antes de remover.

## Instalação

1. Acesse o [Azure Portal](https://portal.azure.com)
2. Navegue até **Monitor** → **Workbooks** → **New**
3. Clique no editor avançado (`</>`)
4. Cole o conteúdo do arquivo `.workbook`
5. Clique em **Apply** e depois **Save**

## Estrutura do Repositório

```
Storage Account Usage Analysis/
├── Analise-Uso-Storage-Accounts-PTBR.workbook   # Workbook em PT-BR
└── README.md                                      # Esta documentação
```
