Collecting workspace information# VMs - Availability Performance and Inventory Workbook

## Visão Geral

Este workbook foi desenvolvido para fornecer uma visão abrangente sobre a disponibilidade e performance de máquinas virtuais (VMs) no Azure, tanto para servidores Windows quanto Linux. Ele utiliza o VM Insights para coletar e exibir dados de performance, permitindo que os usuários monitorem e analisem o estado de suas VMs de forma eficiente.

## Funcionalidades

### Parâmetros de Filtro

O workbook permite a configuração de diversos parâmetros de filtro para personalizar a visualização dos dados:

- **Intervalo de Tempo (TimeRangeParam)**: Define o período de tempo para a análise dos dados.
- **Subscription**: Permite selecionar uma ou mais assinaturas do Azure.
- **Resource Group**: Filtra os dados por grupos de recursos específicos.
- **Workspace**: Seleciona workspaces específicos para análise.
- **Exibir Filtros (ShowFilters)**: Controla a visibilidade dos filtros.
- **Exibir Ajuda (ShowHelp)**: Controla a visibilidade das instruções de uso.
- **Exibir Resumo (ShowSummary)**: Controla a visibilidade do resumo dos dados.

### Resumo

O resumo fornece uma visão geral do estado das VMs, incluindo:

- **Status (Azure)**: Exibe a quantidade de VMs saudáveis e não saudáveis.
- **Tipos de Máquina**: Mostra a distribuição dos tipos de máquinas (Azure VM e ARC Server).
- **Sistema Operacional**: Apresenta a distribuição dos sistemas operacionais das VMs.

### Lista de VMs

Uma tabela detalhada lista todas as VMs, permitindo a visualização de informações como:

- **Status (Azure)**
- **Disponibilidade (HeartbeatState)**
- **Performance (PerfState)**
- **Recurso (id)**
- **Subscription**
- **Resource Group**
- **Sistema Operacional (OSType)**
- **Último Heartbeat**
- **Uso de CPU (% CPU)**
- **Uso de Memória (% Mem)**
- **Uso de Disco (% OSDisk)**

### Performance e Estatísticas

Esta seção inclui gráficos e tabelas que detalham a performance das VMs:

- **Top 5 Recursos com Maior Utilização**: Exibe as VMs com maior uso de CPU, memória e disco.
- **Top 5 Recursos com Menor Utilização**: Exibe as VMs com menor uso de CPU, memória e disco.
- **Gráficos de Linha**: Mostram a média, máximo e mínimo de uso de CPU e memória ao longo do tempo.

## Utilidade

Este workbook é uma ferramenta poderosa para administradores de sistemas e engenheiros de DevOps que precisam monitorar a saúde e a performance de suas VMs no Azure. Ele oferece uma interface intuitiva para filtrar e visualizar dados críticos, ajudando na identificação de problemas e na otimização do desempenho das VMs.

## Como Utilizar

Para que os dados de performance sejam exibidos corretamente, é necessário que as máquinas estejam configuradas com o VM Insights e associadas à Data Collection Rule que popula a tabela InsightsMetrics. Caso contrário, os dados não serão exibidos.

## Conclusão

O workbook "VMs - Availability Performance and Inventory" é essencial para qualquer equipe que gerencia VMs no Azure, proporcionando insights valiosos sobre a disponibilidade e performance das máquinas virtuais, facilitando a tomada de decisões informadas e a manutenção da infraestrutura em ótimo estado.