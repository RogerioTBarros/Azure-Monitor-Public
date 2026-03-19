# Análise de Uso de Storage Accounts com Private Endpoints

Workbook do Azure Monitor para identificar Storage Accounts que possuem Private Endpoints, organizados **por VNET** — já que o limite de PEs é por VNET (1.000/VNET). Permite análise de uso via métricas do Azure Monitor para identificar contas sem uso como candidatas à remoção ou realocação.

## Problema

Em ambientes com milhares de Storage Accounts (5k+), cada um com Private Endpoints, é difícil ter visibilidade sobre quais contas realmente estão em uso. Como o limite de PEs é por VNET, a navegação centrada em VNET é essencial para:

- **Quais VNETs estão próximas do limite de PEs?** (% do limite de 1.000)
- **Quais Storage Accounts estão em cada VNET?** (drill-down por clique)
- **Estão sendo utilizados?** (via métricas de Transactions — clique para ver)
- **Qual o ambiente?** (via tags `ambiente`/`environment`)

## Tabs

| Tab | Descrição |
|-----|-----------|
| **📋 Inventário por VNET** | Grid de VNETs com contagem de Storage Accounts, PEs (storage e total), % do limite de 1.000. Clique em uma VNET para drill-down nos Storage Accounts. |
| **📊 Análise de Uso** | Dropdown de VNET → grid de Storage Accounts filtrada → clique em uma conta → métricas de **Transactions**, **UsedCapacity**, **Ingress**, **Egress**. |
| **🏷️ Por Ambiente** | Distribuição por tag de ambiente. Pie chart + grid resumo + detalhe agrupado. |

## Fluxo de Análise

```
1. Tab Inventário     →  Selecione a VNET com mais PEs
2. Grid de detalhes   →  Veja os Storage Accounts nessa VNET (agrupados por ambiente)
3. Tab Análise de Uso →  Selecione a mesma VNET no dropdown
4. Grid de contas     →  Clique em uma conta para carregar métricas
5. Métricas           →  Transactions=0 por 30d → candidata à remoção
```

## Métricas Utilizadas

| Métrica | Agregação | O que mostra |
|---------|-----------|--------------|
| **Transactions** | Sum | Total de requisições ao storage. **0 = não está sendo usado** |
| **UsedCapacity** | Average | Volume de dados armazenados (bytes) |
| **Ingress** | Sum | Volume de dados recebidos |
| **Egress** | Sum | Volume de dados enviados |

> **Fonte**: [Métricas do Azure Storage no Azure Monitor](https://learn.microsoft.com/pt-br/azure/storage/common/storage-metrics-in-azure-monitor)

## Navegação para Ambientes Grandes (5.000+ contas)

O workbook usa navegação em camadas para lidar com grande volume de contas:

1. **VNET como filtro primário** — reduz 5k+ para ~10-200 contas por VNET
2. **Grid com filtro** — busca textual dentro da grid filtrada
3. **Clique para métricas** — carrega métricas apenas para a conta clicada (evita sobrecarga)

### Evolução Futura: ARM Data Source + Merge

Para trazer métricas (ex: total de Transactions) **direto na grid** sem precisar clicar, é possível usar:

1. **Azure Resource Manager data source** do Workbook para chamar `GET {resourceId}/providers/Microsoft.Insights/metrics?metricnames=Transactions&interval=FULL&aggregation=total` para cada conta na VNET
2. **Merge step** para combinar os resultados do ARG (inventário) com os do ARM (métricas) em uma única grid

Referências:
- [Parameters as Datasets (CloudSMA)](https://www.cloudsma.com/2023/10/advanced-azure-workbooks-parameters-as-datasets/)
- [Workbooks Data Sources — Merge](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources#merge)
- [Workbooks Data Sources — Azure Resource Manager](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources#azure-resource-manager)

## Requisitos

- **Acesso mínimo**: Role **Reader** nas assinaturas (inclui `Microsoft.Insights/metrics/read`)
- **Tags suportadas**: `ambiente`, `Ambiente`, `AMBIENTE`, `environment`, `Environment`, `ENVIRONMENT`
- **Idioma**: Português (Brasil)

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
