# Workbook do Azure para Monitoramento de Serviços do Windows

## Visão Geral

Este Workbook do Azure é projetado para monitorar o estado dos Serviços do Windows em várias máquinas virtuais. Ele fornece insights sobre o tipo de inicialização e o estado atual dos serviços, permitindo a fácil identificação de problemas e tendências ao longo do tempo.

## Parâmetros

- **Intervalo de Tempo**: Permite a seleção do intervalo de tempo para os dados exibidos no workbook.
- **Workspace**: Seleciona o(s) workspace(s) do Log Analytics para consulta.
- **Máquinas Virtuais**: Seleciona as máquinas virtuais para monitoramento.
- **Filtro de Serviços**: Filtra os serviços a serem exibidos com base no nome.

## Visualizações

### Máquinas Virtuais - Clique em um tile para detalhes

Exibe um resumo dos serviços em cada máquina virtual, categorizados pelo tipo de inicialização (Automático, Desativado, Manual) e pelo estado atual (Em Execução, Parado).

### Estado do Serviço ao Longo do Tempo

Um gráfico de linha mostrando o estado dos serviços ao longo do tempo, permitindo a análise de tendências.

### Serviços por Tipo de Inicialização

Um gráfico de pizza exibindo a distribuição dos serviços por tipo de inicialização (Automático, Manual, Desativado).

### Serviços por Estado

Um gráfico de pizza mostrando a distribuição dos serviços pelo estado atual (Em Execução, Parado).

### Detalhes do Serviço

Uma tabela fornecendo informações detalhadas sobre cada serviço, incluindo seu nome, nome de exibição, tipo de inicialização, estado e a última vez que foi gerado.

## Consultas

O workbook usa a Linguagem de Consulta Kusto (KQL) para recuperar e processar dados do workspace do Log Analytics. Abaixo estão as principais consultas usadas:

### Consulta Base

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId in ({VirtualMachines})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| project _ResourceId, SvcStartupType
| evaluate pivot(SvcStartupType)
| extend
    Auto = iif(isempty(Auto), 0, Auto),
    Disabled = iif(isempty(Disabled), 0, Disabled),
    Manual = iif(isempty(Manual), 0, Manual)
| extend Services = Auto + Disabled + Manual
| extend Total = Services
| extend Computer = extract(@"(?i).*/Microsoft.Compute/VirtualMachines/(.*)",1,_ResourceId)
| join kind=inner (basequery
| where SvcStartupType == "Auto"
| project _ResourceId, SvcState
| evaluate pivot(SvcState)) on _ResourceId
| project-away _ResourceId1
```

### Serviços por Tipo de Inicialização

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId =~ "{VMDrillDown}"
| where {StartupType}
| where {ServiceState}
| where SvcName in ({ServiceFilter})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| summarize count() by SvcStartupType
```

### Serviços por Estado

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId =~ "{VMDrillDown}"
| where {StartupType}
| where {ServiceState}
| where SvcName in ({ServiceFilter})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| summarize count() by SvcState
```

### Detalhes do Serviço

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId =~ "{VMDrillDown}"
| where {StartupType}
| where {ServiceState}
| where SvcName in ({ServiceFilter})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| project TimeGenerated, SvcName, SvcStartupType, SvcState
```

## Como Usar

1. Abra o Portal do Azure e navegue até o seu workspace do Log Analytics.
2. Crie um novo workbook e cole o código JSON fornecido.
3. Salve o workbook e comece a monitorar seus Serviços do Windows.

## Contribuindo

Se você tiver sugestões ou melhorias, sinta-se à vontade para abrir um problema ou enviar um pull request.

## Licença

Este projeto é licenciado sob a Licença MIT.