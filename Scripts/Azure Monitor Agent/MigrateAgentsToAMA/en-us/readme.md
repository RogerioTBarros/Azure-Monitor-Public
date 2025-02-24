# MigrateAgentsToAMA_en-us.ps1

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
```

### Configuration Details:
* `inputFileName:` Path to the input file containing the resource IDs of the VMs to be processed.
* `identitiesList:` List of resource IDs of the user-assigned managed identities (User Assigned Managed Identities) that will be associated with the VMs.
* `resourcesLocation:` Region where the resources are located. Only VMs in this region will be processed.
* `dcrList:` List of resource IDs of the data collection rules (DCRs) that will be associated with the VMs.

### Input File

The input file contains the resource IDs of the VMs to be processed. The path to the input file is specified in the `$InputFileName` variable.

Example input file (`VMAgentMigrationInput.txt`):

```txt
/subscriptions/222-111-222-333-444/resourceGroups/RogerioLab.VMs.RG/providers/Microsoft.Compute/virtualMachines/Win-brz-002
/subscriptions/222-111-222-333-444/resourceGroups/RogerioLab.VMs.RG/providers/Microsoft.Compute/virtualMachines/WindowsBrazilSouth-001
/subscriptions/111-222-333-444/resourcegroups/RogerioLab.VS.VMs.RG/providers/Microsoft.Compute/virtualMachines/win-vsold-001
```

## Usage

1. Clone the repository and navigate to the script directory.
2. Edit the configuration file `MigrateAgentsToAMAConfig.json` as needed.
3. Create or edit the input file `VMAgentMigrationInput.txt` with the resource IDs of the VMs to be processed.
4. Run the PowerShell script:

```powershell
.\MigrateAgentsToAMA_pt-br.ps1
```

## Main Functions

### DeployAMAExtension

Installs the Azure Monitor Agent extension on a VM.

### AssignVMToDCR

Associates a VM with a data collection rule (DCR).

### Add-UserAssignedMItoVM

Associates a user-assigned managed identity (User Assigned Managed Identity) with a VM.

### Log-Message

Generates logs and displays messages in the console.

## Main Flow

1. Connects to Azure.
2. For each VM in the input file:
   - Validates and associates the managed identity.
   - Checks and installs the Azure Monitor Agent extension, if necessary.
   - Checks and associates the DCRs, if necessary.

## Author

Rogerio T. Barros (github.com/rogeriotbarros)

## License

This project is licensed under the terms of the MIT license.
```