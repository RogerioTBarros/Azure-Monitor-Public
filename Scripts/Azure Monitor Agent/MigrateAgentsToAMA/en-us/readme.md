# MigrateAgentsToAMA_pt-br.ps1

## Description

This PowerShell script automates the migration of agents to the Azure Monitor Agent (AMA) on virtual machines (VMs) in Azure. It associates user-assigned managed identities (User Assigned Managed Identities) with the VMs, installs the Azure Monitor Agent extension, and associates the VMs with data collection rules (DCRs).

## Configuration

### Configuration File

The script uses a JSON configuration file to define variables and resource lists. The path to the configuration file is specified in the `$configFilePath` variable.

Example configuration file (`MigrateAgentsToAMAConfig.json`):

```json
{
  "inputFileName": ".\\VMAgentMigrationInput.txt",
  "identitiesList": [
    "/subscriptions/222-111-222-333-444/resourceGroups/monitoringresources-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/AzureVMMonitoring-MI-BrazilSouth-VSNova",
    "/subscriptions/111-222-333-444/resourceGroups/rg-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-VMMonitoring-vsold-brazilsouth"
  ],
  "resourcesLocation": "brazilsouth",
  "dcrList": [
    "/subscriptions/222-111-222-333-444/resourceGroups/rogeriolab.monitoring.rg/providers/Microsoft.Insights/dataCollectionRules/MSVMI-VMDefault-DCR"
  ]
}