# Notas de Design

Por que esta solução foi construída assim, o que foi medido em vez de presumido, e quais
alternativas foram consideradas.

🌐 [English](../en-us/design-notes.md) · **Português (pt-BR)**

Cada afirmação abaixo traz sua fonte. Os achados marcados como **medido** foram verificados
empiricamente contra um ambiente real de grande porte, não inferidos da documentação.

---

## 1. A API, e por que o portal não escala

A folha **Azure Monitor → Diagnostic settings** do portal enumera recursos e então emite uma
leitura por recurso, encapsulada em requisições de lote do ARM. É por isso que ela pagina
indefinidamente em assinaturas grandes e não oferece exportação: é uma interface sobre uma API por
recurso, não sobre um índice.

```http
GET https://management.azure.com/{resourceUri}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview
```

Retorna um `DiagnosticSettingsResourceCollection` — `value[]`, com cada item expondo
`properties.workspaceId`, `properties.storageAccountId`,
`properties.eventHubAuthorizationRuleId`, `properties.eventHubName`,
`properties.marketplacePartnerId`, `properties.logs[]` e `properties.metrics[]`.

> Fonte: [Diagnostic Settings - List (Azure Monitor REST API)](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings/list)

Uma restrição útil: **cada recurso pode ter no máximo cinco diagnostic settings**, então toda
resposta é pequena e limitada.

> Fonte: [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)

---

## 2. A restrição que define tudo: o Resource Graph não responde a isso

**O Azure Resource Graph não indexa diagnostic settings.** Isso elimina a resposta óbvia de
"basta escrever uma consulta KQL".

- A tabela `insightresources` contém apenas
  `microsoft.insights/datacollectionruleassociations` e `microsoft.insights/tenantactiongroups`.
- A tabela `resources` contém vários tipos `microsoft.insights/*` — `actiongroups`,
  `activitylogalerts`, `autoscalesettings`, `components`, `datacollectionrules`,
  `guestdiagnosticsettings`, `metricalerts`, `scheduledqueryrules`, `webtests`, `workbooks` —
  mas **não** `microsoft.insights/diagnosticsettings`.

> Fonte: [Supported Azure Resource Manager resource types — Azure Resource Graph](https://learn.microsoft.com/en-us/azure/governance/resource-graph/reference/supported-tables-resources)

⚠ `microsoft.insights/guestdiagnosticsettings` **está** na lista. Esse é o tipo legado de
diagnóstico *de convidado* — outra coisa. Não confunda com diagnostic settings de recurso.

### 2.1 A saída `useResourceGraph=true` também não ajuda

O ARM oferece um caminho de GET/LIST apoiado no Resource Graph para aliviar throttling de leitura:

```http
GET https://management.azure.com/{resourceId}?api-version={v}&useResourceGraph=true
```

A cobertura documentada é **apenas dos tipos das tabelas `resources` e `computeresources`**, e
*"quaisquer requisições não suportadas resultam no `useResourceGraph=true` ignorado, e a chamada é
roteada automaticamente para o resource provider"*. Como diagnostic settings não estão em nenhuma
das duas tabelas, a flag simplesmente não faz nada aqui.

> Fonte: [Azure Resource Graph GET/LIST API guidance](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/azure-resource-graph-get-list-api)

**Conclusão:** as únicas formas de descobrir o estado das diagnostic settings são perguntar ao ARM
recurso a recurso, ou fazer o Azure avaliar via Azure Policy e ler o resultado de conformidade.

---

## 3. O orçamento de throttling

O ARM usa um modelo de **token bucket** por região:

| Escopo | Operação | Balde | Reposição / s |
| --- | --- | --- | --- |
| Assinatura | leituras | 250 | 25 |
| Assinatura | escritas | 200 | 10 |
| Tenant | leituras | 250 | 25 |
| Tenant | escritas | 200 | 10 |

Os limites de assinatura valem **por assinatura, por service principal e por tipo de operação**,
com limites globais equivalentes a 15× os limites individuais por service principal. Ao esgotar:
HTTP 429 com `Retry-After`. Folga observável:
`x-ms-ratelimit-remaining-subscription-reads` e `x-ms-ratelimit-remaining-tenant-reads`.

> Fonte: [Understand how Azure Resource Manager throttles requests](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling)

Isso inverte o desenho ingênuo de varredura: paralelismo *entre* assinaturas é barato, porque cada
uma tem seu próprio balde, enquanto paralelismo *dentro* de uma mesma assinatura é o que dispara
429.

### 3.1 Medido: a execução é limitada por latência, não por throttling

A dúvida em aberto era se um lote de 20 itens debita 1 ou 20 do balde de leituras. A resposta
honesta é que **isso não importa**:

- Cada sub-resposta do lote reporta seus próprios cabeçalhos de rate limit. Em um lote de 2 itens,
  ambas as sub-respostas reportaram 249 restantes.
- 249 de um balde de 250 com reposição de 25/s é simplesmente "250 menos a requisição em voo". A
  poucas requisições por segundo, o balde repõe mais rápido do que é consumido, então ele nunca se
  move visivelmente.
- Ao longo de centenas de chamadas do piloto, o cabeçalho nunca ficou abaixo de 249, com zero 429.

**O planejamento de capacidade é, portanto, guiado pela latência de ida e volta e pelo número de
chamadas, não por aritmética de balde.** As requisições são emitidas em série, então o throughput é
`max(intervalo de ritmo, latência de ida e volta)`. Elevar o ritmo acima do inverso da latência
medida não produz efeito.

### 3.2 Medido: sub-respostas de lote não têm campo de correlação

Uma sub-resposta contém exatamente `httpStatusCode`, `headers`, `content` e `contentLength`. Não
há **nome, `relativeUrl` ecoado nem identificador de requisição** que a ligue de volta a uma
sub-requisição.

Duas consequências guiam a implementação:

1. Os resultados precisam ser atribuídos lendo **o próprio `id` de cada setting retornada**,
   truncado em `/providers/microsoft.insights/diagnosticsettings/` — nunca por índice do array.
2. Uma sub-resposta não-200 **não pode ser atribuída**, então o lote inteiro precisa ser relido
   recurso a recurso para localizar a falha com precisão. Este é o maior precipício de desempenho
   do desenho.

---

## 4. O mecanismo de lote, validado contra código first-party

```http
POST https://management.azure.com/batch?api-version=2020-06-01
Content-Type: application/json

{
  "requests": [
    { "httpMethod": "GET", "relativeUrl": "<resourceId>/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview" }
  ]
}
```

Isso não foi obtido por engenharia reversa do navegador. É o que o **Azure Quick Review (`azqr`)**,
ferramenta mantida pela Microsoft sob licença MIT, faz em
`internal/scanners/diagnostics_settings.go`:

| Parâmetro | Valor no azqr |
| --- | --- |
| Tamanho do lote | **20** sub-requisições por POST |
| Workers | 30 concorrentes |
| Limitador ARM no cliente | 20 ops/s, burst 100 |
| Retentativas | 5, atraso de 4s → máx. 60s |
| Cabeçalho observado | `x-ms-ratelimit-remaining-tenant-reads` |
| Derivação do resultado | lê o `id` da setting retornada para recuperar o recurso pai |

> Fonte: [Azure/azqr — `internal/scanners/diagnostics_settings.go`](https://github.com/Azure/azqr/blob/main/internal/scanners/diagnostics_settings.go)

Esses valores comprovados são reaproveitados em vez de reinventados. **Medido:** o fan-out do lote
é de fato paralelo no servidor — um lote de 2 itens levou ~0,61s (0,305 s/item) enquanto um de 20
itens levou ~1,64s (0,082 s/item). A escala sublinear confirma que o lote não é processado em
série.

---

## 5. O critério da sondagem

**Esta é a lição mais cara do projeto.**

A sondagem original decidia o suporte do tipo a partir de `diagnosticSettingsCategories`. Isso está
errado:

> **Um `200` de `diagnosticSettingsCategories` não significa que o tipo suporta diagnostic
> settings.** Tipos somente de métricas retornam `200 { AllMetrics, categoryType: "Metrics" }` do
> endpoint de categorias e depois falham na leitura real com:
>
> ```
> 400 { "code": "ResourceTypeNotSupported",
>       "message": "The resource type '<type>' does not support diagnostic settings." }
> ```

Confirmado em `microsoft.network/privateendpoints` — um tipo que pode facilmente representar uma
fatia de dois dígitos percentuais de um ambiente moderno.

O custo de errar aqui não é apenas uma linha rotulada de forma incorreta. Recursos não suportados
dentro de um lote ARM produzem sub-respostas não-200 e, como as sub-respostas não têm campo de
correlação (§3.2), **um único recurso ruim força a releitura individual de todo o lote de 20
itens**. Em teste, um único tipo contaminante transformou 50 lotes em 726 leituras individuais — um
colapso de throughput de ~15x que teria passado despercebido.

**Regras que decorrem disso:**

- Sonde o endpoint que você realmente vai chamar. Suporte significa `diagnosticSettings` retornar
  200.
- Use `diagnosticSettingsCategories` apenas para metadados de categoria, nunca como critério.
- `400 ResourceTypeNotSupported` é a resposta canônica de "não suportado" nos dois endpoints — não
  é requisição malformada. Mapeie para um status `NotSupported` distinto, nunca para `Error` e
  nunca para "desabilitado".
- Não fixe uma lista de tipos suportados no código. Ela envelhece conforme o Azure lança serviços,
  criando pontos cegos silenciosos. Sondar custa de uma a duas chamadas por tipo distinto e produz
  um `supported-types.csv` auditável.

---

## 6. Storage accounts exigem expansão de sub-recursos

`Microsoft.Storage/storageAccounts` expõe apenas categorias de **métrica**. As categorias de
**log** ficam em `blobServices`, `fileServices`, `queueServices` e `tableServices` — que o Resource
Graph não indexa, portanto nunca podem ser enumeradas.

Os IDs são determinísticos (`<accountId>/<service>/default`), então o coletor sintetiza os quatro
por conta. **Medido:** os quatro endpoints retornam HTTP 200 mesmo quando o serviço não é usado, e
incluí-los aumentou materialmente a contagem de `Enabled`. Sem essa expansão, um ambiente com muito
storage é subnotificado silenciosamente.

---

## 7. Medido: processos coletores de longa duração degradam

Em uma execução de várias horas, o throughput caiu de forma monotônica desde um início limpo e
terminou travado. Blocos consecutivos de 500 recursos levaram 153s, 54s, 204s, 219s, 329s e, então,
mais de 900s.

O ponto crucial: isso **não** é latência do ARM nem throttling. Enquanto o coletor estava travado em
uma assinatura, um shell recém-iniciado, em separado, atendeu um lote de 20 itens contra essa mesma
assinatura em 1,64s. Reiniciar o coletor reproduziu a mesma degradação a partir de um início limpo.
A explicação mais consistente é acúmulo de estado de rede/handles no processo, coerente com as
falhas transitórias de token de managed identity observadas na mesma linha do tempo.

**Mitigação:** um processo do sistema operacional por assinatura, com timeout rígido, o que limita
qualquer travamento e impede que a degradação se acumule. Invocar o script novamente *dentro da
mesma sessão* não cria um processo novo e não resolve.

É isso que o `Invoke-DiagnosticSettingsCollection.ps1` implementa.

---

## 8. Alternativas consideradas

### A — Azure Policy somente auditoria + consulta de conformidade

Atribuir a policy interna agnóstica de destino, deixar o Azure avaliar a conformidade na própria
infraestrutura dele e ler o resultado do Resource Graph em uma consulta. **Zero leitura ARM por
recurso.**

| Campo | Valor |
| --- | --- |
| ID | `7f89b1eb-583c-429a-8828-af049802c1d9` |
| Nome | Audit diagnostic setting for selected resource types |
| Efeito | `AuditIfNotExists` — **fixo, não parametrizável** |
| Parâmetros | `listOfResourceTypes`, `logsEnabled` (padrão `true`), `metricsEnabled` (padrão `true`) |

> Fonte: [Azure/azure-policy — `Monitoring/DiagnosticSettingsForTypes_Audit.json`](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Monitoring/DiagnosticSettingsForTypes_Audit.json)

**Prós:** não pode alterar nada; é agnóstica de destino; uma atribuição no management group cobre
todas as assinaturas; a conformidade cai na tabela indexada `policyresources`; reavalia
continuamente, virando um controle duradouro em vez de uma planilha desatualizada.

**Contras:** exige criar uma atribuição de policy — uma mudança de configuração que precisa de
aprovação, mesmo sendo somente auditoria. E **a condição de existência é mais restrita que "possui
diagnostic setting"**: com os padrões, uma setting que coleta logs mas não `AllMetrics` é reportada
como não conforme. Ajuste deliberadamente, ou use duas atribuições e compare.

> As iniciativas de grupo de categorias `allLogs` / `audit` são **específicas de destino** —
> marcam um recurso como não conforme se ele envia para outro destino. Ferramenta errada para uma
> pergunta de inventário.

**Escolha esta opção** quando o inventário virar um controle recorrente, e não um relatório único.

### B — Coletor próprio com Resource Graph + lote ARM

**O que este repositório implementa.** Maior fidelidade: tipo de destino e IDs de destino, nomes das
settings, categorias habilitadas e flag de métricas. Sem mudança no tenant. Reutilizável e
reexecutável. O custo é assumir o comportamento de throttling, e é por isso que o protocolo de
piloto é obrigatório.

### C — Executar o `azqr` diretamente

```bash
azqr scan --management-group-id <mgId> --stages diagnostics
```

Zero código a manter e throttling testado em produção. Mas a saída de diagnósticos é formatada como
*recomendações* — reporta os recursos **sem** settings, então um panorama completo de
habilitado/desabilitado exige cruzar com a saída de inventário. O filtro de tipos suportados é uma
lista fixa dentro da ferramenta, e introduzir um binário de terceiros pode exigir aprovação.

### D — Cruzamento com Log Analytics

```kusto
union withsource=TableName AzureDiagnostics, AzureMetrics
| where TimeGenerated > ago(7d)
| summarize LastSeen = max(TimeGenerated) by _ResourceId, TableName
```

Zero carga no ARM, e responde à pergunta possivelmente mais útil: *os dados estão realmente
chegando?* Detecta settings que existem mas não entregam nada. Mas **não é substituto** — é cego
para destinos Event Hub e Storage, cego para recursos configurados porém silenciosos, e tabelas
específicas de serviço ficam fora de `AzureDiagnostics`. **Use como camada de validação, nunca
sozinho.**

---

## 9. Esquema de saída

| Coluna | Observações |
| --- | --- |
| `SubscriptionId` / `SubscriptionName` | Nome resolvido a partir de `resourcecontainers` |
| `ResourceGroup`, `ResourceName`, `ResourceType`, `Location` | |
| `ResourceId` | ID ARM completo — a chave de junção |
| `DiagnosticStatus` | `Enabled` / `NotConfigured` / `NotSupported` / `AccessDenied` / `NotFound` / `Error` |
| `SettingsCount` | 0–5 |
| `SettingNames` | Separado por ponto e vírgula |
| `DestinationTypes` | `LogAnalytics;EventHub;Storage;Partner` |
| `WorkspaceIds`, `StorageAccountIds`, `EventHubNames` | Separados por ponto e vírgula |
| `LogCategories` | Categorias e grupos de categorias, separados por ponto e vírgula |
| `MetricsEnabled` | true / false |
| `CollectedAtUtc` | Carimbo da linha — também a evidência de que a execução é um retrato progressivo |

As colunas de detalhe não custam nada na coleta: a API devolve o objeto completo da configuração na
mesma resposta que responde à pergunta binária. Adiá-las significaria uma segunda varredura
completa.

---

## 10. Não coletado: settings de assinatura e de management group

As settings em nível de recurso não são o quadro completo. **A exportação do activity log é
configurada no escopo da assinatura**, e management groups têm API própria. Ambas são baratas — uma
chamada por assinatura e mais algumas poucas.

```http
GET https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview
```

> Fontes: [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings),
> [Management Group Diagnostic Settings REST API](https://learn.microsoft.com/en-us/rest/api/monitor/management-group-diagnostic-settings)

Vale incluir em qualquer entrega — os clientes costumam se surpreender aqui. É a evolução mais
óbvia desta solução.
