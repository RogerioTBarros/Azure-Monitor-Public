####################################################################
# Script: MigrateAgentsToAMA_pt-br.ps1
# Versao: 1.0
# Author: Rogerio T. Barros (rogerio.barros@hotmail.com)
# Criado em: 21/02/2025
####################################################################

# Carregar configurações do arquivo de configuração
$configFilePath = ".\MigrateAgentsToAMAConfig.json"
if (Test-Path $configFilePath) {
    $config = Get-Content $configFilePath | ConvertFrom-Json
} else {
    Write-Error "Arquivo de configuração não encontrado: $configFilePath"
    exit
}

# variáveis
$InputFileName = $config.inputFileName
[array]$identitiesList = $config.identitiesList
$resourcesLocation = $config.resourcesLocation
[array]$dcrlist = $config.dcrList
$inputFile = get-content $InputFileName
# Type handlers
$Global:TypeHandlerVersionWindows = "1.31"
$Global:TypeHandlerVersionLinux = "1.31"

# Log file setup
$LogFilePrefix = "MigrateAgentsToAMA"
$timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
$LogFileName = "$LogFilePrefix$timestamp.log"
$LogFilePath = Join-Path -Path (Get-Location) -ChildPath $LogFileName


# Extrair lista de recursos agrupados por subscription

$ResourcesBySubscription = @{}

# Iterate over each resource path
foreach ($path in $InputFile) {
    # Extract the subscription ID and resource path
    if ($path -match "/subscriptions/([^/]+)/(.+)") {
        $subscriptionId = $matches[1]
        $resource = $matches[0]

        # Add the resource to the corresponding subscription ID in the hashtable
        if (-not $ResourcesBySubscription.ContainsKey($subscriptionId)) {
            $ResourcesBySubscription[$subscriptionId] = @()
        }
        $ResourcesBySubscription[$subscriptionId] += $resource
    }
}

# Extrair lista de Managed Identities por Subscription

$UAMIBySubscription = @{}

# Iterate over each resource path
foreach ($UAMIpath in $identitiesList) {
    # Extract the subscription ID and resource path
    if ($UAMIpath -match "/subscriptions/([^/]+)/(.+)") {
        $subscriptionId = $matches[1]
        $resource = $matches[0]

        # Add the resource to the corresponding subscription ID in the hashtable
        if (-not $UAMIBySubscription.ContainsKey($subscriptionId)) {
            $UAMIBySubscription[$subscriptionId] = @()
        }
        $UAMIBySubscription[$subscriptionId] += $resource
    }
}

# Funções

# 1 - Instalar Extension AMA
function DeployAMAExtension {
    param(
        [object]$VMObject,
        [string]$AgentUAMID
    )


    $Location = $VMObject.Location
    $VMState = get-AzVM -ResourceId $VMObject.Id -Status

    if ($VMObject.ProvisioningState -eq "Succeeded" -and $VMState.statuses[1].code -eq "PowerState/running") {
        $OsType = $VMObject.storageProfile.osDisk.osType

        if ($OsType -eq "Windows") {
            $ExtensionName = "AzureMonitorWindowsAgent"
            $Publisher = "Microsoft.Azure.Monitor"
            $Type = "AzureMonitorWindowsAgent"
            $TypeHandlerVersion = $Global:TypeHandlerVersionWindows
        }
        elseif ($OsType -eq "Linux") {
            $ExtensionName = "AzureMonitorLinuxAgent"
            $Publisher = "Microsoft.Azure.Monitor"
            $Type = "AzureMonitorLinuxAgent"
            $TypeHandlerVersion = $Global:TypeHandlerVersionLinux
        }
        else {
            Log-Message "Versão de SO não suportada: $OsType"
            return
        }
        $identitySettingString = '{"authentication":{"managedIdentity":{"identifier-name":"mi_res_id","identifier-value":"' + $AgentUAMID + '"}}}'
        try {
            Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $ExtensionName -Publisher $Publisher -ExtensionType $Type -TypeHandlerVersion $TypeHandlerVersion -Location $Location -EnableAutomaticUpgrade $true -SettingString $identitySettingString -AsJob
        }
        catch {
            Log-Message "`nErro ao instalar extensão do Azure Monitor Agent na VM $($VM.Name)."
            Log-Message $_.Exception.Message
        }
    }
    else {
        $msg = "A VM " + $VM.Name + " não está em funcionamento. A extensão não será instalada"
        Log-Message $msg
    }
}

# 2 - Associar VM a uma DCR
function AssignVMToDCR {
    param(
        [object]$VMObject,
        [string]$DCRResourceId
    )

    $DCR = Get-AzResource -ResourceId $DCRResourceId

    $msg = "Associando VM " + $VMObject.Name + " à DCR " + $DCR.Name
    Log-Message $msg
    $DCRAssociationName = $DCR.Name + "-" + $VMObject.Name
    New-AzDataCollectionRuleAssociation -AssociationName $DCRAssociationName -ResourceUri $VMObject.Id -DataCollectionRuleId $DCRResourceId
}

# 3 - Associar user-assigned identity a uma VM
function Add-UserAssignedMItoVM {
    param(
        [object]$VMObject,
        [string]$identityResourceId
    )
    
    # Identifica objeto Managed Identity a aplicar
    $identity = (Get-AzResource -ResourceId $identityResourceId)
    if ($identity -eq $null) {
        Log-Message "A Managed Identity $identityResourceId não existe ou o usuário executando não tem acesso. Favor verificar."
        return
    }

    $identity
    $msg = "Iniciando associação de User Assigned Managed Identity...`n`nManaged Identity a adicionar: " + $identity.Name
    Log-Message $msg

    $msg = "Associar User Managed Identity - Analisando VM " + $vmobject.name
    Log-Message $msg

    Log-Message "Checando tipo de identidade"
    if ($null -eq $vmobject.Identity) {
        $msg = "VM não possui Managed Identity. Adicionando a identidade " + $identity.Name + "..."
        Log-Message $msg
        Log-Message "TS" -ForegroundColor red
        $VMObject

        $identity

        $vmobject | Update-AZVM -Identitytype "UserAssigned" -IdentityId $identity.ResourceId -AsJob
    }
    else {
        $msg = "VM possui Managed Identity. Tipo: " + $vmobject.Identity.Type
        Log-Message $msg
        switch ($vmobject.Identity.Type) {
            "None" { 
                $msg = "VM não possui Managed Identity. Adicionando a identidade" + $identity.Name + "..."
                Log-Message $msg
                $vmobject | Update-AZVM -Identitytype "UserAssigned" -IdentityId $identity.ResourceId -AsJob
            }
            "SystemAssigned" { 
                $msg = "VM possui Managed Identity System Assigned. Adicionando a Identidade " + $identity.Name + "..." 
                $vmobject | Update-AZVM -Identitytype "SystemAssignedUserAssigned" -IdentityId $identity.ResourceId -AsJob
                Log-Message $msg
            }
            "UserAssigned" { 
                if ($vmobject.Identity.UserAssignedIdentities.Keys.ToLower() -contains $identity.ResourceId.ToLower()) {
                    $msg = "A identidade " + $identity.name + " já está associada à VM"
                    Log-Message $msg
                }
                else {
                    $msg = "A identidade " + $identity.name + " não está associada mas há outra(s) configurada(s)"
                    [array]$UAMIList = $vmobject.Identity.UserAssignedIdentities.Keys
                    $msg = $msg + "`n`nIdentidades User Assigned associadas à VM: " + $UAMIList

                    $msg = $msg + "`n`nAdicionando identidade : " + $identity.Name + " à lista de identidades associadas à VM..."
                    $UAMIList += $identity.ResourceId
                    Log-Message $msg
                    $vmobject | Update-AZVM -Identitytype $vmobject.Identity.Type -IdentityId $UAMIList -AsJob
                }
            }
            "SystemAssignedUserAssigned" { 
                $msg = "VM possui Managed Identity System Assigned e User Assigned. Checando user assigned identities..."
                if ($vmobject.Identity.UserAssignedIdentities.Keys.ToLower() -contains $identity.ResourceId.ToLower()) {
                    $msg = "A identidade " + $identity.name + " já está associada à VM"
                    Log-Message $msg
                }
                else {
                    $msg = "A identidade " + $identity.name + " não está associada mas há outra(s) configurada(s)"
                    [array]$UAMIList = $vmobject.Identity.UserAssignedIdentities.Keys
                    $msg = $msg + "`n`nIdentidades User Assigned associadas à VM: " + $UAMIList

                    $msg = $msg + "`n`nAdicionando identidade : " + $identity.Name + " à lista de identidades associadas à VM..."
                    Log-Message $msg
                    $vmobject | Update-AZVM -Identitytype $vmobject.Identity.Type -IdentityId $UAMIList -AsJob
                }
            }
            default { $msg = "VM possui Managed Identity de tipo desconhecido" }
        }
    }
}

# 4 - Gerar Log e resposta no console
function Log-Message {
    param (
        [string]$message
    )
    Write-Output $message
    Add-Content -Path $LogFilePath -Value $message
}

# Main

# Conectar ao Azure
Clear-Host
Connect-AzAccount | out-null

# Para cada VM (resource ids em inputfile), instalar a extensão do Azure Monitor Agent

foreach ($subscriptionId in $ResourcesBySubscription.keys)
{
    $VMResourceIDs = $ResourcesBySubscription[$subscriptionId]
    $context = set-azcontext -SubscriptionId $subscriptionId

    $msg = "Processando VMs da subscription: " + $context.Name
    Log-Message $msg

    # Selecionar User Assigned Managed Identity para a subscription

    #$identityResId = $UAMIBySubscription[$subscriptionId][0]
    # única User Assigned Managed Identity para todas as VMs

    $identityResId = $identitiesList[0]

    foreach ($VMResourceID in $VMResourceIDs) {
        
        $VM = Get-AzVM -ResourceId $VMResourceID
        $msg = "`nProcessando VM: " + $VM.Name
        Log-Message $msg

        if ($vm.Location -eq $resourcesLocation) {
            
            # Validar a User Managed Identity da VM. Instalar caso necessário.
            Add-UserAssignedMItoVM -VMObject $VM -identityResourceId $identityResId

            # Checar se há extensões do Azure Monitor Agent instaladas
            $msg = "Checando extensões do Azure Monitor Agent na VM " + $($VM.Name) + "..."
            Log-Message $msg
            $Extensions = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name
            if ($Extensions.Publisher -contains "Microsoft.Azure.Monitor") {
                $msg = "A VM " + $($VM.Name) + " possui a extensão Azure Monitor Agent instalada."
                Log-Message $msg
            }
            else {
                $msg = "A VM " + $($VM.Name) + " não possui a extensão Azure Monitor Agent instalada. Enviando comando para instalação..."
                Log-Message $msg
                DeployAMAExtension -VMObject $VM -AgentUAMID $identityResId  
            }

            # Verificar DCRs associadas à VM e associar caso necessário
            $dcrAssociations = Get-AzDataCollectionRuleAssociation -TargetResourceId $VM.Id
            $AssociatedDCRNames = @()
            foreach ($dcrentry in $dcrAssociations.DataCollectionRuleId) {
                $DCRName = $dcrentry.split("/")[-1]
                $AssociatedDCRNames += $DCRName
            }
            $msg = "Checando DCRs associadas à VM " + $VM.Name
            Log-Message $msg

            if ($null -eq $dcrAssociations) {
                $msg = "A VM não possui DCRs associadas. Associando..."
                Log-Message $msg
                foreach ($dcr in $dcrlist) {
                    AssignVMToDCR -VMObject $VM -DCRResourceId $dcr
                }
            }
            else {
                $msg = "A VM possui as seguintes DCRs associadas: `n" + $AssociatedDCRNames

                Log-Message $msg

                #Comparar DCRs associadas à VM com a lista de DCRs a serem associadas
                foreach ($dcr in $dcrlist) {
                    $DCRName = $dcr.split("/")[-1]
                    if ($dcrAssociations.DataCollectionRuleId -icontains $dcr) {
                        $msg = "A DCR " + $DCRName + " já está associada à VM"
                        Log-Message $msg
                    }
                    else {
                        $msg = "A DCR " + $DCRName + " não está associada à VM. Associando..."
                        Log-Message $msg
                        AssignVMToDCR -VMObject $VM -DCRResourceId $dcr
                    }
                }
            }
        }
        else {
            $msg = "A VM " + $VM.Name + " não está na região configurada para o script. Somente serão processadas VMs na região " + $resourcesLocation + ". Seguindo para a próxima VM..."
            Log-Message $msg
        }
    }
}