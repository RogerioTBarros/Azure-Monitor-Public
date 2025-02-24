# MigrateAgentsToAMA_pt-br.ps1

## Descrição

Este script PowerShell automatiza a migração de agentes para o Azure Monitor Agent (AMA) em máquinas virtuais (VMs) no Azure. Ele associa identidades gerenciadas atribuídas pelo usuário (User Assigned Managed Identities) às VMs, instala a extensão do Azure Monitor Agent e associa as VMs às regras de coleta de dados (DCRs).

## Configuração

### Arquivo de Configuração

O script utiliza um arquivo de configuração JSON para definir variáveis e listas de recursos. O caminho do arquivo de configuração é especificado na variável `$configFilePath`.

Exemplo de arquivo de configuração (`MigrateAgentsToAMAConfig.json`):

```json
{
  "inputFileName": ".\\VMAgentMigrationInput.txt",
  "identitiesList": [
    "/subscriptions/fa9678e8-6b00-4b3c-9a0d-465e5faff9ab/resourceGroups/monitoringresources-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/AzureVMMonitoring-MI-BrazilSouth-VSNova",
    "/subscriptions/56828eff-05b6-44cb-ae7f-3c007e40d164/resourceGroups/rg-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-VMMonitoring-vsold-brazilsouth"
  ],
  "resourcesLocation": "brazilsouth",
  "dcrList": [
    "/subscriptions/fa9678e8-6b00-4b3c-9a0d-465e5faff9ab/resourceGroups/rogeriolab.monitoring.rg/providers/Microsoft.Insights/dataCollectionRules/MSVMI-VMDefault-DCR"
  ]
}
```

### Arquivo de Entrada

O arquivo de entrada contém os IDs de recursos das VMs a serem processadas. O caminho do arquivo de entrada é especificado na variável `$InputFileName`.

Exemplo de arquivo de entrada (`VMAgentMigrationInput.txt`):

```txt
/subscriptions/222-111-222-333-444/resourceGroups/RogerioLab.VMs.RG/providers/Microsoft.Compute/virtualMachines/Win-brz-002
/subscriptions/222-111-222-333-444/resourceGroups/RogerioLab.VMs.RG/providers/Microsoft.Compute/virtualMachines/WindowsBrazilSouth-001
/subscriptions/111-222-333-444/resourcegroups/RogerioLab.VS.VMs.RG/providers/Microsoft.Compute/virtualMachines/win-vsold-001
```

## Uso

1. Clone o repositório e navegue até o diretório do script.
2. Edite o arquivo de configuração MigrateAgentsToAMAConfig.json conforme necessário.
3. Crie ou edite o arquivo de entrada VMAgentMigrationInput.txt com os IDs de recursos das VMs a serem processadas.
4. Execute o script PowerShell:

```powershell
.\MigrateAgentsToAMA_pt-br.ps1
```

## Funções Principais

### DeployAMAExtension

Instala a extensão do Azure Monitor Agent em uma VM.

### AssignVMToDCR

Associa uma VM a uma regra de coleta de dados (DCR).

### Add-UserAssignedMItoVM

Associa uma identidade gerenciada atribuída pelo usuário (User Assigned Managed Identity) a uma VM.

### Log-Message

Gera logs e exibe mensagens no console.

## Fluxo Principal

1. Conecta ao Azure.
2. Para cada VM no arquivo de entrada:
   - Valida e associa a identidade gerenciada.
   - Verifica e instala a extensão do Azure Monitor Agent, se necessário.
   - Verifica e associa as DCRs, se necessário.

## Autor

Rogerio T. Barros (github.com/rogeriotbarros)

## Licença

Este projeto está licenciado sob os termos da licença MIT.