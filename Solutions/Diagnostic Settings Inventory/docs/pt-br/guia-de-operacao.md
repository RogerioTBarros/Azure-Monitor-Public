# Guia de Operação

Como executar o inventário de diagnostic settings de ponta a ponta, do primeiro censo até a
entrega dos CSVs.

🌐 [English](../en-us/operations-guide.md) · **Português (pt-BR)**

---

## 0. Antes de começar

### Duas armadilhas que corrompem uma execução silenciosamente

**1. Confirme que o script enviado é o atual.** Uma cópia desatualizada produz uma execução
totalmente plausível. Verifique o artefato, não a memória:

```powershell
(Get-Command ./Get-DiagnosticSettingsInventory.ps1).Parameters.Keys -join ', '
```

O resultado precisa incluir `SkipStorageServices`. O driver faz essa verificação
automaticamente e se recusa a iniciar caso contrário.

**2. Os artefatos de fase são compartilhados entre escopos.** `census-by-type.csv`,
`census-by-subscription.csv` e `supported-types.csv` são gravados nos mesmos caminhos,
independentemente de `-ManagementGroupId` ou `-SubscriptionId`. Portanto, **um piloto de uma
única assinatura sobrescreve o censo e o cache de sondagem de todo o tenant**. Como a fase de
coleta reutiliza silenciosamente o `supported-types.csv` em cache, uma execução completa iniciada
depois vai filtrar pela lista de tipos muito menor do piloto e ignorar boa parte do ambiente.

> **Sempre reexecute o Censo e `Probe -Force` no escopo completo imediatamente antes da execução
> completa**, e confirme que a contagem de tipos corresponde ao ambiente inteiro, não ao piloto.

### Ambiente

| Requisito | Observações |
| --- | --- |
| Cloud Shell em modo **PowerShell** | Não Bash — os cmdlets Az não existem lá |
| Reader no escopo avaliado | O que não for legível vira `AccessDenied`, nunca é descartado |
| `Az.Accounts` | Já incluído no Cloud Shell; único módulo necessário |
| Autenticação | O Cloud Shell já vem autenticado. **Não** execute `Connect-AzAccount` |

```powershell
Get-AzContext | Format-List Account, Tenant, Environment
```

### ⚠ O armazenamento do Cloud Shell pode ser efêmero

Sem um file share montado, `$HOME` é armazenamento de contêiner. Os checkpoints sobrevivem a um
`Ctrl+C` e ao reinício do script **dentro da mesma sessão**, mas tudo — scripts, checkpoints e
saídas — se perde quando a sessão termina ou o contêiner é reciclado.

Em uma sessão efêmera, faça backup para a sua máquina regularmente:

```powershell
tar -czf ~/dsi-progress.tgz -C ~/Data checkpoints supported-types.csv census-by-type.csv census-by-subscription.csv
download ~/dsi-progress.tgz
```

Restaure em uma sessão nova com:

```powershell
mkdir -p ~/Data
tar -xzf ~/dsi-progress.tgz -C ~/Data
```

Nunca prometa "retomamos amanhã sem perder nada" sem confirmar a persistência antes.

---

## 1. Envie os scripts

Barra de ferramentas do Cloud Shell → **Upload/Download files** → *Upload*. Ambos os scripts vão
para `$HOME`.

```powershell
cd ~
ls Get-DiagnosticSettingsInventory.ps1 Invoke-DiagnosticSettingsCollection.ps1
```

> **Armadilha de caminho:** `-OutputDir` usa por padrão `Join-Path $PWD.Path 'Data'` → `~/Data`.
> Isso é proposital. Um padrão `$PSScriptRoot/..` resolveria para `/home` quando o script é
> enviado para o diretório home, que **não é gravável**, e a primeira escrita falharia.

---

## 2. Censo — sempre primeiro

Custa cerca de duas chamadas ao Resource Graph e transforma qualquer estimativa em número.

```powershell
./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId '<mg-root-id>' -Phase Census
```

Gera `~/Data/census-by-type.csv` e `~/Data/census-by-subscription.csv`.

Leia o resumo no console — tipos distintos, número de assinaturas, total de recursos e a maior
assinatura. **Pare e revise antes de continuar.** Até isso rodar, qualquer estimativa de esforço é
ficção.

---

## 3. Sondagem — quais tipos podem ter settings

Determina quais tipos de recurso *deste* ambiente suportam diagnostic settings, chamando o
endpoint `diagnosticSettings` contra um recurso de amostra por tipo. De uma a duas chamadas por
tipo distinto — centenas, não centenas de milhares.

```powershell
./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId '<mg-root-id>' -Phase Probe
```

Gera `~/Data/supported-types.csv`:

| Coluna | Significado |
| --- | --- |
| `ResourceType` | O tipo |
| `Supported` | `True` se o tipo aceita a leitura de diagnostic settings |
| `ResourceCount` | Quantos recursos desse tipo existem no escopo |
| `Categories` | Metadados de categoria, quando disponíveis |
| `ProbeStatus` / `SettingsProbeStatus` | Status HTTP de cada chamada da sondagem |
| `SupportReason` | Por que o tipo foi incluído ou excluído |
| `SampleId` | O recurso sondado |

**Revise este arquivo antes da execução completa — ele é o filtro que decide o que será
varrido.** Ordene as linhas `Supported=False` por `ResourceCount` decrescente: é ali que um erro
custa mais caro. Se um tipo de alta contagem parecer errado, force a inclusão com
`-AdditionalType`.

Os resultados ficam em cache. Refaça a sondagem com `-Force`.

> **Por que a sondagem chama `diagnosticSettings` e não apenas `diagnosticSettingsCategories`:**
> um `200` do endpoint de categorias **não** significa que o tipo suporta diagnostic settings.
> Tipos somente de métricas retornam `200` em categorias e depois falham na leitura real com
> `400 ResourceTypeNotSupported`. Sondar o endpoint que você realmente vai chamar é o único
> critério correto — veja as [notas de design](notas-de-design.md#5-o-critério-da-sondagem).

---

## 4. Piloto em uma assinatura

Nunca vá direto para a execução completa.

```powershell
./Get-DiagnosticSettingsInventory.ps1 -SubscriptionId '<uma-sub-id>' -TargetBatchesPerSecond 2
```

Observe o resumo da execução:

- **`Throttled429` deve ser 0.** Se não for, reduza `-TargetBatchesPerSecond`.
- **`SingleRequests` deve ser 0.** Um valor diferente de zero significa que os lotes estão caindo
  para leituras individuais — normalmente um tipo não suportado contaminando o conjunto de
  candidatos. Isso é um colapso de throughput de ~15x e precisa ser corrigido antes da execução
  completa, não tolerado.
- **`HeadroomPauses`** próximo de zero. Diferente de zero significa que o script está reduzindo o
  ritmo preventivamente.
- **`GraphQuotaPauses` pode legitimamente ser diferente de zero** em ambientes grandes. O Resource
  Graph tem cota própria (~15 consultas por 5 segundos por usuário), separada do balde de leituras
  do ARM. Isso **não** é motivo para reduzir `-TargetBatchesPerSecond`, que governa apenas a carga
  no ARM.
- **Tempo real por 1.000 recursos** — mas leia o aviso abaixo antes de extrapolar.

> **O ritmo é um piso, não paralelismo.** As requisições são emitidas uma por vez, então o
> throughput real é `max(intervalo de ritmo, latência de ida e volta)`. Se um lote leva 1,5s para
> retornar, aumentar `-TargetBatchesPerSecond` de 2 para 4 não muda nada.

> **⚠ Não extrapole a partir de uma assinatura pequena.** O throughput não é linear em relação ao
> tamanho da assinatura. Um piloto em uma assinatura pequena pode sugerir uma execução completa de
> 2 horas que depois leva muito mais, porque as maiores assinaturas degradam para um regime bem
> mais lento. Faça o piloto na maior assinatura, ou aceite que a estimativa é um limite inferior.

---

## 5. Execução completa

### Ambientes pequenos

```powershell
./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId '<mg-root-id>'
```

Retomável: reexecutar pula assinaturas concluídas e continua as parciais a partir do último
recurso registrado em checkpoint.

### Ambientes grandes — use o driver

Um único processo de longa duração degrada progressivamente: o tempo de ida e volta dos lotes
cresce de segundos para minutos e o processo acaba travando, enquanto um processo recém-iniciado
atende a mesma requisição em menos de dois segundos. A causa é o estado acumulado no processo, não
a latência do ARM nem throttling. Reiniciar o mesmo processo único reproduz a mesma degradação.

A correção é isolamento de processo — um processo do sistema operacional por assinatura, com
timeout rígido:

```powershell
./Invoke-DiagnosticSettingsCollection.ps1 -BackupPath ~/dsi-progress.zip
```

| Parâmetro | Padrão | Finalidade |
| --- | --- | --- |
| `-ScriptPath` | arquivo irmão | Caminho do coletor |
| `-OutputDir` | `./Data` | Precisa ser o mesmo diretório do Censo/Sondagem |
| `-SubscriptionId` | do CSV do censo | Lista explícita de assinaturas |
| `-TimeoutSeconds` | `600` | Encerra e repete uma tentativa que travar |
| `-MaxAttempts` | `20` | Tentativas por assinatura antes de desistir |
| `-BackupPath` | — | Atualiza um arquivo de progresso após cada assinatura |

O driver nunca passa `-Force`, pula assinaturas que já têm marcador `.done` e reporta qualquer
assinatura que não conseguiu concluir. **Uma tentativa travada não perde nada** — o coletor grava
checkpoint a cada lote, então a repetição continua de onde parou.

### Acompanhando o progresso

```powershell
# assinaturas concluídas
(Get-ChildItem ~/Data/checkpoints/*.done).Count

# recursos coletados até agora
(Get-Content ~/Data/checkpoints/*.jsonl | Measure-Object -Line).Lines
```

> A contagem de `.done` é sobre o número de assinaturas que contêm ao menos um recurso
> **suportado** — não sobre todas as assinaturas do tenant. Esses números costumam ser bem
> diferentes.

---

## 6. Exportação e download

A exportação roda automaticamente ao final de uma execução completa. Para reexportar a partir dos
checkpoints, sem recoletar:

```powershell
./Get-DiagnosticSettingsInventory.ps1 -Phase Export
```

```powershell
download ~/Data/diagnostic-settings-summary.csv
download ~/Data/diagnostic-settings-detail.csv
download ~/Data/diagnostic-settings-rollup.csv
```

**Baixe imediatamente** em uma sessão efêmera do Cloud Shell.

---

## 7. Ressalvas que devem constar no relatório

Inclua estas observações em qualquer entrega. Um revisor que descobrir isso sozinho vai
desconfiar de todos os outros números.

1. **Retrato progressivo.** Cada assinatura é capturada no momento em que foi processada, não em
   um instante único. As contagens não vão reconciliar exatamente com uma consulta nova ao
   Resource Graph em um ambiente ativo.
2. **Assinaturas ausentes.** Assinaturas sem recursos suportados não geram linhas. Isso significa
   "nada aqui pode ter diagnostic setting", não "nada é logado". Liste-as separadamente com o
   motivo.
3. **Distinção de status.** `AccessDenied`, `NotFound`, `NotSupported` e `Error` nunca são
   fundidos em `NotConfigured`.
4. **Recursos excluídos.** Execuções longas produzem algumas linhas `NotFound` de recursos
   excluídos entre a enumeração e a leitura. Isso é esperado, não é defeito.

---

## 8. Referência de ajustes

| Parâmetro | Padrão | Quando mudar |
| --- | --- | --- |
| `-TargetBatchesPerSecond` | `4` | Reduza a qualquer 429. Aumente só após um piloto limpo — e só se o piso for latência, não ritmo |
| `-BatchSize` | `20` | Mantenha 20; é o valor usado pelo Azure Quick Review |
| `-MinReadHeadroom` | `100` | Aumente para ser mais conservador em um tenant movimentado |
| `-MaxRetries` | `5` | |
| `-ResourceType` | — | Restringe a tipos específicos, ex.: uma passada só em serviços críticos |
| `-AdditionalType` | — | Força a inclusão de um tipo que a sondagem excluiu por engano |
| `-SkipStorageServices` | desligado | **Desativa** a expansão de sub-recursos de storage. Mais rápido, mas as settings de **log** de storage ficam sem coleta |
| `-IncludeAllTypes` | desligado | Ignora o filtro da sondagem. Carga muito maior — use apenas para provar que nada foi perdido |

### Expansão de sub-recursos de storage

`Microsoft.Storage/storageAccounts` expõe apenas categorias de **métrica**. As categorias de
**log** de storage ficam em `blobServices`, `fileServices`, `queueServices` e `tableServices`, que
o Resource Graph **não** indexa — portanto nunca podem ser enumeradas.

Os IDs são determinísticos (`<accountId>/<service>/default`), então a coleta sintetiza os quatro
por conta em vez de enumerá-los. Cada conta custa então 5 leituras em vez de 1. Serviços que não
se aplicam ao tipo da conta retornam 404, registrado como `NotFound` e mantido distinto de
`NotConfigured`.

---

## 9. Solução de problemas

| Sintoma | Ação |
| --- | --- |
| `Access to the path '/home/Data' is denied` | O `-OutputDir` resolveu acima de `$HOME`. Passe `-OutputDir ~/Data` explicitamente |
| Um diretório chamado literalmente `..\Data` | Um caminho no estilo Windows vazou para o `Join-Path`. O Cloud Shell é Linux; `\` é um caractere válido em nomes de arquivo |
| 429 repetidos | Reduza `-TargetBatchesPerSecond` pela metade. Confirme que nenhuma outra ferramenta está varrendo as mesmas assinaturas com a mesma identidade — o balde é **por service principal** |
| Erro `RateLimiting` citando `aka.ms/resourcegraph-throttling` | Isso é **Resource Graph**, outro balde. Reduzir `-TargetBatchesPerSecond` é a alavanca errada; verifique `GraphQuotaPauses` |
| `SingleRequests` subindo | Um tipo não suportado está contaminando os lotes. Reexecute `Probe -Force` e verifique `SettingsProbeStatus` |
| Throughput caindo ao longo de horas, depois travando | Degradação conhecida no nível do processo. Use o driver para que cada assinatura receba um processo novo |
| `Your Azure credentials have not been set up or have expired` no meio da execução | Falha transitória de token de managed identity em execuções longas. **Não** execute `Connect-AzAccount` no Cloud Shell; repita a assinatura |
| Sessão caiu no meio da execução | Reexecute o mesmo comando; os checkpoints retomam automaticamente |
| `No Azure context` | O Cloud Shell está em modo Bash ou a sessão expirou. Mude para modo PowerShell e recarregue |
| A exportação diz que não há checkpoints | `-OutputDir` errado, ou a restauração do arquivo de progresso falhou. **Pare** — recoletar repete horas de trabalho |
