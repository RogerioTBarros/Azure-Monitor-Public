# VMs - Disponibilidade, Performance e Inventário (pt-br)

Este workbook fornece uma visão abrangente sobre a disponibilidade, performance e inventário das suas máquinas virtuais (VMs) Azure e servidores híbridos (Azure Arc). Ele permite monitorar rapidamente o status operacional, identificar gargalos de desempenho e obter insights detalhados sobre o uso dos recursos computacionais.

## Funcionalidades Principais

- **Visão Geral de Status**: Exibe o status atual das VMs, classificando-as como saudáveis ou não saudáveis com base em critérios como conectividade e estado operacional.
- **Monitoramento de Performance**: Apresenta métricas essenciais como uso de CPU, memória e espaço em disco, permitindo identificar rapidamente recursos com alta ou baixa utilização.
- **Inventário Completo**: Lista detalhadamente todas as VMs e servidores híbridos, incluindo informações sobre sistema operacional, grupo de recursos e subscription associada.
- **Drill-down Detalhado**: Possibilidade de aprofundar a análise em máquinas específicas, visualizando gráficos históricos e métricas detalhadas.

## Como Utilizar o Workbook

Para que os dados sejam exibidos corretamente, é necessário que as máquinas estejam configuradas com o **VM Insights** (associadas a uma Data Collection Rule que popula a tabela InsightsMetrics). Caso contrário, as informações de performance não estarão disponíveis.

## Parâmetros Configuráveis pelo Usuário

O workbook oferece diversos parâmetros que podem ser ajustados conforme a necessidade:

| Parâmetro | Descrição |
|-----------|-----------|
| **Intervalo (TimeRange)** | Define o período de tempo para análise dos dados (últimas 24 horas, 7 dias, etc.). |
| **Subscription (VMs)** | Permite selecionar uma ou mais subscriptions contendo as VMs que serão analisadas. |
| **Resource Group (VMs)** | Filtra as VMs por grupos de recursos específicos. |
| **Subscription (Workspace)** | Define a subscription onde estão localizados os workspaces do Log Analytics. |
| **Resource Group (Workspace)** | Seleciona os grupos de recursos dos workspaces do Log Analytics. |
| **Workspace** | Seleciona os workspaces específicos que contêm os dados coletados das VMs. |
| **Exibir Filtros** | Habilita ou desabilita filtros adicionais para refinar a visualização dos dados. |
| **Exibir Ajuda** | Exibe ou oculta informações adicionais sobre como utilizar o workbook. |
| **Exibir Resumo** | Mostra ou oculta gráficos resumidos sobre o status geral das VMs. |
| **Thresholds de Performance** | Permite definir limites personalizados para alertas de CPU, memória, espaço em disco e heartbeat. |
| **Filtro de Servidores** | Utiliza expressões regulares para filtrar servidores específicos por nome. |
| **Tipo de Agregação** | Escolhe o tipo de agregação das métricas exibidas (média, máximo ou mínimo). |

## Cenários de Uso

- **Monitoramento Contínuo**: Utilize o workbook para acompanhar regularmente o status e desempenho das suas VMs, garantindo uma operação saudável e eficiente.
- **Troubleshooting Rápido**: Identifique rapidamente máquinas com problemas de performance ou disponibilidade, facilitando ações corretivas imediatas.
- **Planejamento de Capacidade**: Analise o uso histórico dos recursos para planejar expansões ou otimizações de infraestrutura.

## Pré-requisitos

- Máquinas configuradas com VM Insights.
- Permissões adequadas para acessar os dados dos workspaces do Log Analytics e recursos Azure.

## Como Implantar o Workbook

Para implantar corretamente este workbook no Azure, siga os passos abaixo:

1. **Arquivos Necessários**: Certifique-se de implantar ambos os arquivos fornecidos no repositório:
   - `VMs - Availability Performance and Inventory - pt-br.workbook`
   - `Detalhamento VMs.workbook`
- **Detalhamento VM**: Workbook complementar que fornece detalhes adicionais sobre cada VM individualmente.

### Importante:

- Ambos os arquivos devem ser implantados no Azure.
- Após a implantação, é necessário ajustar a referência do **Resource ID** no workbook principal para apontar corretamente para o workbook complementar (**Detalhamento VM**). Isso garante que o drill-down detalhado funcione corretamente ao clicar em "Detalhes".
- Ao implantar os 2 workbooks, colete o resource ID do workbook Detalhamento VMs, edite o arquivo principal (VMs - Availability Performance and Inventory - pt-br.workbook) e procure pelo termo `"ResourceIDWorkbookDetalhamentoVM"`. Substitua este texto pelo resource ID do workbook de detalhes implantado em seu ambiente e depois prossiga com o processo de deployment do workbook principal.. Caso haja dúvidas, por favor envie uma mensagem.

---

Este workbook é uma ferramenta essencial para administradores e equipes de operações que buscam uma visão clara e detalhada sobre o ambiente de máquinas virtuais e servidores híbridos no Azure.