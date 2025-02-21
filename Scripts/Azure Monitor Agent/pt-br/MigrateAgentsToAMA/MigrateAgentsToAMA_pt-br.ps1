####################################################################
# Script: MigrateAgentsToAMA_pt-br.ps1
# Versao: 1.0
# Author: Rogerio T. Barros (rogerio.barros@hotmail.com)
# Criado em: 21/02/2025

# Corrigir problema com a associação de Managed Identities em VMs (Update-AZVM)
####################################################################

# Carregar configurações do arquivo de configuração
$configFilePath = ".\MigrateAgentsToAMAConfig.json"
$config = Get-Content $configFilePath | ConvertFrom-Json

# variáveis
$InputFileName = $config.inputFileName
[array]$identitiesList = $config.identitiesList
$resourcesLocation = $config.resourcesLocation
[array]$dcrlist = $config.dcrList
$inputFile = get-content $InputFileName
# Type handlers
$Global:TypeHandlerVersionWindows = "1.31"
$Global:TypeHandlerVersionLinux = "1.31"


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
    $VMState = get-AzVM -ResourceId $VMObject.ResourceId -Status

    
    if ($VMObject.Properties.ProvisioningState -eq "Succeeded" -and $VMState.statuses[1].code -eq "PowerState/running") {
        $OsType = $VMObject.Properties.storageProfile.osDisk.osType

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
            Write-Host "Versão de SO não suportada: $OsType"
            return
        }
        $identitySettingString = '{"authentication":{"managedIdentity":{"identifier-name":"mi_res_id","identifier-value":"' + $AgentUAMID + '"}}}'
        try {
            Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $ExtensionName -Publisher $Publisher -ExtensionType $Type -TypeHandlerVersion $TypeHandlerVersion -Location $Location -EnableAutomaticUpgrade $true -SettingString $identitySettingString -AsJob
        }
        catch {
            Write-Output "`nErro ao instalar extensão do Azure Monitor Agent na VM $($VM.Name)."
            $_.Exception.Message
        }
        
    }
    else {
        $msg = "A VM " + $VM.Name + " não está em funcionamento. A extensão não será instalada"
        write-output $msg
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
    write-output $msg
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
        Write-Output "A Managed Identity $identityResourceId não existe ou o usuário executando não tem acesso. Favor verificar."
        return
    }


    $identity
    $msg = "Iniciando associação de User Assigned Managed Identity...`n`nManaged Identity a adicionar: " + $identity.Name
    write-output $msg

    $msg = "Associar User Managed Identity - Analisando VM " + $vmobject.name
    write-output $msg

    Write-Host "VM Identity Type: " $vmobject.Identity.Type

    write-output "Checando tipo de identidade"
    if ($null -eq $vmobject.Identity) {
        $msg = "VM não possui Managed Identity. Adicionando a identidade " + $identity.Name + "..."
        Write-Output $msg
        write-host "TS" -ForegroundColor red
        $VMObject

        $identity

        $vmobject | Update-AZVM -Identitytype "UserAssigned" -IdentityId $identity.ResourceId -AsJob
    }
    else {
        $msg = "VM possui Managed Identity. Tipo: " + $vmobject.Identity.Type
        Write-Output $msg
        switch ($vmobject.Identity.Type) {
            "None" { 
                $msg = "VM não possui Managed Identity. Adicionando a identidade" + $identity.Name + "..."
                Write-Output $msg
                $vmobject | Update-AZVM -Identitytype "UserAssigned" -IdentityId $identity.ResourceId -AsJob
            }
            "SystemAssigned" { 
                $msg = "VM possui Managed Identity System Assigned. Adicionando a Identidade " + $identity.Name + "..." 
                $vmobject | Update-AZVM -Identitytype "SystemAssignedUserAssigned" -IdentityId $identity.ResourceId -AsJob
                write-output $msg
            }
            "UserAssigned" { 
                if ($vmobject.Identity.UserAssignedIdentities.Keys.ToLower() -contains $identity.ResourceId.ToLower()) {
                    $msg = "A identidade " + $identity.name + " já está associada à VM"
                    write-output $msg
                }
                else {
                    $msg = "A identidade " + $identity.name + " não está associada mas há outra(s) configurada(s)"
                    [array]$UAMIList = $vmobject.Identity.UserAssignedIdentities.Keys
                    $msg = $msg + "`n`nIdentidades User Assigned associadas à VM: " + $UAMIList

                    $msg = $msg + "`n`nAdicionando identidade : " + $identity.Name + " à lista de identidades associadas à VM..."
                    $UAMIList += $identity.ResourceId
                    write-output $msg
                    $vmobject | Update-AZVM -Identitytype $vmobject.Identity.Type -IdentityId $UAMIList -AsJob
                }
            }
            "SystemAssignedUserAssigned" { 
                $msg = "VM possui Managed Identity System Assigned e User Assigned. Checando user assigned identities..."
                if ($vmobject.Identity.UserAssignedIdentities.Keys.ToLower() -contains $identity.ResourceId.ToLower()) {
                    $msg = "A identidade " + $identity.name + " já está associada à VM"
                    write-output $msg
                }
                else {
                    $msg = "A identidade " + $identity.name + " não está associada mas há outra(s) configurada(s)"
                    [array]$UAMIList = $vmobject.Identity.UserAssignedIdentities.Keys
                    $msg = $msg + "`n`nIdentidades User Assigned associadas à VM: " + $UAMIList

                    $msg = $msg + "`n`nAdicionando identidade : " + $identity.Name + " à lista de identidades associadas à VM..."
                    $UAMIList += $identity.ResourceId
                    write-output $msg
                    $vmobject | Update-AZVM -Identitytype $vmobject.Identity.Type -IdentityId $UAMIList -AsJob
                }
            }
            default { $msg = "VM possui Managed Identity de tipo desconhecido" }
        }
    }
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
    write-output $msg

    # Selecionar User Assigned Managed Identity para a subscription

    $identityResId = $UAMIBySubscription[$subscriptionId][0]

    foreach ($VMResourceID in $VMResourceIDs) {
        $msg = "Processando VM: " + $VMResourceID
        write-output $msg
        $VM = Get-AzResource -ResourceId $VMResourceID
        write-host "`nProcessando VM: " $VM.Name -ForegroundColor Blue
        
        
        
        
        if ($vm.Location -eq $resourcesLocation) {
            # Validar a User Managed Identity da VM. Instalar caso necessário.
    
            Add-UserAssignedMItoVM -VMObject $VM -identityResourceId $identityResId
        
        
            # Checar se há extensões do Azure Monitor Agent instaladas
        
            $msg = "Checando extensões do Azure Monitor Agent na VM " + $($VM.Name) + "..."
            write-output $msg
            $Extensions = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name
            if ($Extensions.Publisher -contains "Microsoft.Azure.Monitor") {
                $msg = "A VM " + $($VM.Name) + " possui a extensão Azure Monitor Agent instalada."
                write-output $msg
            }
            else {
                $msg = "A VM " + $($VM.Name) + " não possui a extensão Azure Monitor Agent instalada. Enviando comando para instalação..."
                write-output $msg
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
            Write-Output $msg
        
            if ($null -eq $dcrAssociations) {
                $msg = "A VM não possui DCRs associadas. Associando..."
                write-output $msg
                foreach ($dcr in $dcrlist) {
                    AssignVMToDCR -VMObject $VM -DCRResourceId $dcr
                }
            }
            else {
                $msg = "A VM possui as seguintes DCRs associadas: `n" + $AssociatedDCRNames
    
                write-output $msg
    
                #Comparar DCRs associadas à VM com a lista de DCRs a serem associadas
                foreach ($dcr in $dcrlist) {
                    $DCRName = $dcr.split("/")[-1]
                    if ($dcrAssociations.DataCollectionRuleId -icontains $dcr) {
                        $msg = "A DCR " + $DCRName + " já está associada à VM"
                        write-output $msg
                    }
                    else {
                        $msg = "A DCR " + $DCRName + " não está associada à VM. Associando..."
                        write-output $msg
                        AssignVMToDCR -VMObject $VM -DCRResourceId $dcr
                    }
                }
            }
        }
        else {
            $msg = "A VM " + $VM.Name + " não está na região configurada para o script. Somente serão processadas VMs na região " + $resourcesLocation + ". Seguindo para a próxima VM..."
            write-output $msg
            
        }
    }
}






