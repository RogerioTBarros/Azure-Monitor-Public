# Azure Tag Management Workbook - pt-BR

## Visão Geral

Este workbook do Azure Monitor fornece uma solução abrangente para gerenciamento e monitoramento de tags de recursos no Azure. Desenvolvido em português brasileiro, oferece múltiplas visualizações e funcionalidades para ajudar na governança e organização dos recursos Azure através de tags.

## 🏷️ Funcionalidades

### 1. **Recursos sem Tags**
- **Gráfico de Pizza**: Visualização geral da proporção de recursos com e sem tags
- **Lista Detalhada**: Tabela completa dos recursos que não possuem tags configuradas
- **Exportação**: Capacidade de exportar dados para Excel
- **Navegação Direta**: Links diretos para os recursos no portal Azure

### 2. **Lista de Tags**
- **Inventário Completo**: Lista todas as tags utilizadas no tenant com contagem de recursos
- **Drill-down Interativo**: Seleção de tags para visualizar valores específicos
- **Top 100 Valores**: Visualização dos valores mais utilizados para cada tag
- **Filtros**: Capacidade de filtrar e pesquisar tags específicas

### 3. **Busca de Recursos por Tag**
- **Pesquisa por Regex**: Suporte a expressões regulares para busca avançada
- **Múltiplas Tags**: Possibilidade de buscar por múltiplas tags simultaneamente
- **Visualização Detalhada**: Exibição completa dos recursos encontrados

### 4. **Busca de Valores por Tag**
- **Pesquisa Específica**: Busca por valores específicos de uma tag determinada
- **Tiles Visuais**: Representação visual dos valores mais comuns
- **Drill-down**: Navegação dos valores para os recursos específicos

## 🔧 Como Usar

### Pré-requisitos
- Acesso ao Azure Monitor
- Permissões de leitura nos recursos Azure
- Azure Workbooks habilitado

### Instalação
1. Faça o download do arquivo `Azure Tag Management - pt-br.workbook`
2. No portal Azure, navegue até **Azure Monitor > Workbooks**
3. Clique em **+ Novo** e selecione **Editor Avançado**
4. Cole o conteúdo do arquivo JSON
5. Clique em **Aplicar** e depois **Salvar**

### Navegação
O workbook utiliza um sistema de abas para organizar as diferentes funcionalidades:

- **Lista de Tags**: Exploração geral do inventário de tags
- **Recursos sem tags**: Identificação de recursos não taggeados
- **Busca de recursos por tag**: Pesquisa avançada por recursos
- **Busca de valores por tag**: Análise detalhada de valores específicos

## 📊 Visualizações Disponíveis

### Gráficos
- **Gráfico de Pizza**: Proporção recursos com/sem tags
- **Tiles**: Representação visual de valores de tags
- **Tabelas Interativas**: Listas detalhadas com links de navegação

### Formatação
- **Links Diretos**: Navegação direta para recursos no portal Azure
- **Ícones Contextuais**: Identificação visual por tipo de recurso
- **Códigos de Cores**: Diferenciação visual de estados (com/sem tags)

## 🎯 Casos de Uso

### Governança
- **Auditoria de Tags**: Identificar recursos sem tags obrigatórias
- **Padronização**: Verificar consistência nos valores de tags
- **Compliance**: Garantir aderência às políticas organizacionais

### Gestão de Custos
- **Centro de Custo**: Rastrear recursos por departamento/projeto
- **Ambiente**: Separar recursos de produção, desenvolvimento e teste
- **Owner**: Identificar responsáveis pelos recursos

### Operações
- **Manutenção**: Agrupar recursos para operações em lote
- **Backup**: Identificar recursos críticos para backup
- **Monitoramento**: Configurar alertas baseados em tags

## 📋 Queries KQL Principais

O workbook utiliza várias queries KQL otimizadas:

### Recursos sem Tags
```kql
resources
| extend Tagged = iif(isnull(['tags']) or ['tags'] == "{}","Não","Sim")
| where Tagged == "Não"
| project id, type, subscriptionId, resourceGroup
```

### Lista de Tags
```kql
resources
| where isnotnull(['tags'])
| project id, ['tags']
| mv-expand ['tags']
| extend TagName = extract('"(.+?)":', 1, tostring(tags))
| where TagName notcontains "hidden-"
| summarize Recursos = count() by TagName
```

### Busca por Tags
```kql
resources
| where tags matches regex @'{TagNameSearch}'
| extend TagValue = tostring(tags.['{TagNameSearch}'])
| summarize Ocorrencias = count() by TagValue
```

## 🔍 Filtros e Parâmetros

### Parâmetros Disponíveis
- **TagNameFilter**: Filtro por nome específico de tag
- **TagValueDrillDown**: Drill-down por valor de tag
- **TagNameSearch**: Busca textual por tags
- **TagNameForResourcesSearch**: Busca com regex por recursos

### Recursos de Filtro
- **Regex Support**: Suporte completo a expressões regulares
- **Case Insensitive**: Buscas não são case-sensitive
- **Wildcard**: Uso de wildcards para buscas amplas

## 📈 Performance e Limites

### Otimizações
- **Row Limits**: Limite de 10.000 linhas por tabela para performance
- **Top 100**: Limitação nos valores mais comuns para carregamento rápido
- **Filtros Indexados**: Uso de índices para consultas rápidas

### Recomendações
- Use filtros específicos para grandes tenants
- Considere exportar dados para análises extensivas
- Execute consultas em horários de menor uso

## 🤝 Contribuição

### Como Contribuir
1. Faça um fork do repositório
2. Crie uma branch para sua feature (`git checkout -b feature/nova-funcionalidade`)
3. Commit suas mudanças (`git commit -m 'Adiciona nova funcionalidade'`)
4. Push para a branch (`git push origin feature/nova-funcionalidade`)
5. Abra um Pull Request

### Padrões de Código
- Mantenha consultas KQL otimizadas
- Use nomes descritivos em português brasileiro
- Documente novas funcionalidades
- Teste em diferentes tenants antes de submeter

## 📄 Licença

Este projeto está licenciado sob a Licença MIT - veja o arquivo [LICENSE](LICENSE) para detalhes.

## 📞 Suporte

Para dúvidas, problemas ou sugestões:
- Abra uma [Issue](../../issues) no repositório
- Entre em contato com a equipe de Azure Monitor

## 📚 Recursos Adicionais

- [Documentação do Azure Resource Graph](https://docs.microsoft.com/azure/governance/resource-graph/)
- [Melhores Práticas para Tags](https://docs.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging)
- [Azure Monitor Workbooks](https://docs.microsoft.com/azure/azure-monitor/visualize/workbooks-overview)
- [KQL Reference](https://docs.microsoft.com/azure/data-explorer/kusto/query/)

---

**Versão**: 1.0  
**Última Atualização**: Setembro 2025  
**Compatibilidade**: Azure Monitor, Azure Resource Graph  
**Idioma**: Português Brasileiro