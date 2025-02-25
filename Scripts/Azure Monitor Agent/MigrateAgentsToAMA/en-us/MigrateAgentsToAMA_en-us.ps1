####################################################################
# Script: MigrateAgentsToAMA_en-us.ps1
# Version: 1.0
# Author: Rogerio T. Barros (github.com/rogeriotbarros)
# Created on: 21/02/2025
####################################################################

# Load settings from the configuration file
$configFilePath = ".\MigrateAgentsToAMAConfig.json"
if (Test-Path $configFilePath) {
    $config = Get-Content $configFilePath | ConvertFrom-Json
} else {
    Write-Error "Configuration file not found: $configFilePath"
    exit
}

# Variables
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

# Extract list of resources grouped by subscription

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

# Extract list of Managed Identities by Subscription

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

# Functions

# 1 - Install AMA Extension
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
            Log-Message "Unsupported OS version: $OsType"
            return
        }
        $identitySettingString = '{"authentication":{"managedIdentity":{"identifier-name":"mi_res_id","identifier-value":"' + $AgentUAMID + '"}}}'
        try {
            Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $ExtensionName -Publisher $Publisher -ExtensionType $Type -TypeHandlerVersion $TypeHandlerVersion -Location $Location -EnableAutomaticUpgrade $true -SettingString $identitySettingString -AsJob
        }
        catch {
            Log-Message "`nError installing Azure Monitor Agent extension on VM $($VM.Name)."
            Log-Message $_.Exception.Message
        }
    }
    else {
        $msg = "The VM " + $VM.Name + " is not running. The extension will not be installed"
        Log-Message $msg
    }
}

# 2 - Associate VM to a DCR
function AssignVMToDCR {
    param(
        [object]$VMObject,
        [string]$DCRResourceId
    )

    $DCR = Get-AzResource -ResourceId $DCRResourceId

    $msg = "Associating VM " + $VMObject.Name + " to DCR " + $DCR.Name
    Log-Message $msg
    $DCRAssociationName = $DCR.Name + "-" + $VMObject.Name
    New-AzDataCollectionRuleAssociation -AssociationName $DCRAssociationName -ResourceUri $VMObject.Id -DataCollectionRuleId $DCRResourceId
}

# 3 - Associate user-assigned identity to a VM
function Add-UserAssignedMItoVM {
    param(
        [object]$VMObject,
        [string]$identityResourceId
    )
    
    # Identify Managed Identity object to apply
    $identity = (Get-AzResource -ResourceId $identityResourceId)
    if ($identity -eq $null) {
        Log-Message "The Managed Identity $identityResourceId does not exist or the executing user does not have access. Please check."
        return
    }

    $identity
    $msg = "Starting association of User Assigned Managed Identity...`n`nManaged Identity to add: " + $identity.Name
    Log-Message $msg

    $msg = "Associate User Managed Identity - Analyzing VM " + $vmobject.name
    Log-Message $msg

    Log-Message "Checking identity type"
    if ($null -eq $vmobject.Identity) {
        $msg = "VM does not have Managed Identity. Adding identity " + $identity.Name + "..."
        Log-Message $msg
        Log-Message "TS" -ForegroundColor red
        $VMObject

        $identity

        $vmobject | Update-AZVM -Identitytype "UserAssigned" -IdentityId $identity.ResourceId -AsJob
    }
    else {
        $msg = "VM has Managed Identity. Type: " + $vmobject.Identity.Type
        Log-Message $msg
        switch ($vmobject.Identity.Type) {
            "None" { 
                $msg = "VM does not have Managed Identity. Adding identity" + $identity.Name + "..."
                Log-Message $msg
                $vmobject | Update-AZVM -Identitytype "UserAssigned" -IdentityId $identity.ResourceId -AsJob
            }
            "SystemAssigned" { 
                $msg = "VM has System Assigned Managed Identity. Adding Identity " + $identity.Name + "..." 
                $vmobject | Update-AZVM -Identitytype "SystemAssignedUserAssigned" -IdentityId $identity.ResourceId -AsJob
                Log-Message $msg
            }
            "UserAssigned" { 
                if ($vmobject.Identity.UserAssignedIdentities.Keys.ToLower() -contains $identity.ResourceId.ToLower()) {
                    $msg = "The identity " + $identity.name + " is already associated with the VM"
                    Log-Message $msg
                }
                else {
                    $msg = "The identity " + $identity.name + " is not associated but there are other(s) configured"
                    [array]$UAMIList = $vmobject.Identity.UserAssignedIdentities.Keys
                    $msg = $msg + "`n`nUser Assigned identities associated with the VM: " + $UAMIList

                    $msg = $msg + "`n`nAdding identity : " + $identity.Name + " to the list of identities associated with the VM..."
                    $UAMIList += $identity.ResourceId
                    Log-Message $msg
                    $vmobject | Update-AZVM -Identitytype $vmobject.Identity.Type -IdentityId $UAMIList -AsJob
                }
            }
            "SystemAssignedUserAssigned" { 
                $msg = "VM has System Assigned and User Assigned Managed Identity. Checking user assigned identities..."
                if ($vmobject.Identity.UserAssignedIdentities.Keys.ToLower() -contains $identity.ResourceId.ToLower()) {
                    $msg = "The identity " + $identity.name + " is already associated with the VM"
                    Log-Message $msg
                }
                else {
                    $msg = "The identity " + $identity.name + " is not associated but there are other(s) configured"
                    [array]$UAMIList = $vmobject.Identity.UserAssignedIdentities.Keys
                    $msg = $msg + "`n`nUser Assigned identities associated with the VM: " + $UAMIList

                    $msg = $msg + "`n`nAdding identity : " + $identity.Name + " to the list of identities associated with the VM..."
                    Log-Message $msg
                    $vmobject | Update-AZVM -Identitytype $vmobject.Identity.Type -IdentityId $UAMIList -AsJob
                }
            }
            default { $msg = "VM has unknown Managed Identity type" }
        }
    }
}

# 4 - Generate Log and console response
function Log-Message {
    param (
        [string]$message
    )
    Write-Output $message
    Add-Content -Path $LogFilePath -Value $message
}

# Main

# Connect to Azure
Clear-Host
Connect-AzAccount | out-null

# For each VM (resource ids in inputfile), install the Azure Monitor Agent extension

foreach ($subscriptionId in $ResourcesBySubscription.keys)
{
    $VMResourceIDs = $ResourcesBySubscription[$subscriptionId]
    $context = set-azcontext -SubscriptionId $subscriptionId

    $msg = "Processing VMs from subscription: " + $context.Name
    Log-Message $msg

    # Select User Assigned Managed Identity for the subscription

    $identityResId = $UAMIBySubscription[$subscriptionId][0]

    foreach ($VMResourceID in $VMResourceIDs) {
        
        $VM = Get-AzVM -ResourceId $VMResourceID
        $msg = "`nProcessing VM: " + $VM.Name
        Log-Message $msg

        if ($vm.Location -eq $resourcesLocation) {
            
            # Validate the User Managed Identity of the VM. Install if necessary.
            Add-UserAssignedMItoVM -VMObject $VM -identityResourceId $identityResId

            # Check if there are Azure Monitor Agent extensions installed
            $msg = "Checking Azure Monitor Agent extensions on VM " + $($VM.Name) + "..."
            Log-Message $msg
            $Extensions = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name
            if ($Extensions.Publisher -contains "Microsoft.Azure.Monitor") {
                $msg = "The VM " + $($VM.Name) + " has the Azure Monitor Agent extension installed."
                Log-Message $msg
            }
            else {
                $msg = "The VM " + $($VM.Name) + " does not have the Azure Monitor Agent extension installed. Sending command to install..."
                Log-Message $msg
                DeployAMAExtension -VMObject $VM -AgentUAMID $identityResId  
            }

            # Check DCRs associated with the VM and associate if necessary
            $dcrAssociations = Get-AzDataCollectionRuleAssociation -TargetResourceId $VM.Id
            $AssociatedDCRNames = @()
            foreach ($dcrentry in $dcrAssociations.DataCollectionRuleId) {
                $DCRName = $dcrentry.split("/")[-1]
                $AssociatedDCRNames += $DCRName
            }
            $msg = "Checking DCRs associated with VM " + $VM.Name
            Log-Message $msg

            if ($null -eq $dcrAssociations) {
                $msg = "The VM does not have associated DCRs. Associating..."
                Log-Message $msg
                foreach ($dcr in $dcrlist) {
                    AssignVMToDCR -VMObject $VM -DCRResourceId $dcr
                }
            }
            else {
                $msg = "The VM has the following associated DCRs: `n" + $AssociatedDCRNames

                Log-Message $msg

                # Compare DCRs associated with the VM with the list of DCRs to be associated
                foreach ($dcr in $dcrlist) {
                    $DCRName = $dcr.split("/")[-1]
                    if ($dcrAssociations.DataCollectionRuleId -icontains $dcr) {
                        $msg = "The DCR " + $DCRName + " is already associated with the VM"
                        Log-Message $msg
                    }
                    else {
                        $msg = "The DCR " + $DCRName + " is not associated with the VM. Associating..."
                        Log-Message $msg
                        AssignVMToDCR -VMObject $VM -DCRResourceId $dcr
                    }
                }
            }
        }
        else {
            $msg = "The VM " + $VM.Name + " is not in the configured region for the script. Only VMs in the region " + $resourcesLocation + " will be processed. Moving to the next VM..."
            Log-Message $msg
        }
    }
}