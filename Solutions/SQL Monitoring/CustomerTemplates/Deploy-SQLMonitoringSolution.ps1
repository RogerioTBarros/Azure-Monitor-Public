<#
.SYNOPSIS
    SQL Server Monitoring Solution - Deployment Helper Script
    Assists with deploying ARM templates and configuring RBAC permissions.

.DESCRIPTION
    This script guides the customer through deploying the SQL Server Monitoring
    solution step by step. It deploys ARM templates and configures the necessary
    RBAC role assignments.

    Run this script from the CustomerTemplates folder.

.PARAMETER ResourceGroupName
    The Azure Resource Group where resources will be deployed.

.PARAMETER Location
    The Azure region for deployment (e.g., eastus, westus2, brazilsouth).

.PARAMETER AutomationAccountName
    Name for the Azure Automation Account.

.PARAMETER LogAnalyticsWorkspaceName
    Name for the Log Analytics Workspace.

.PARAMETER SqlAuthenticationType
    SQL Server authentication type: "Windows" or "SQL". Default: "Windows"

.PARAMETER KeyVaultName
    Name for the Key Vault (existing or new, required only for SQL Authentication).

.PARAMETER KeyVaultResourceGroup
    Resource group of an existing Key Vault. Defaults to ResourceGroupName.

.PARAMETER CreateKeyVault
    Create a new Key Vault. If omitted, uses an existing one.

.PARAMETER CreateAutomationAccount
    Create a new Automation Account. If omitted, uses an existing one.

.PARAMETER AutomationAccountResourceGroup
    Resource group of the existing Automation Account. Defaults to ResourceGroupName.

.PARAMETER CreateLogAnalyticsWorkspace
    Create a new Log Analytics Workspace. If omitted, uses an existing one.

.PARAMETER LogAnalyticsWorkspaceResourceGroup
    Resource group of the existing Log Analytics Workspace. Defaults to ResourceGroupName.

.PARAMETER SkipInfrastructure
    Skip the infrastructure deployment (if already deployed).

.PARAMETER SkipDataCollection
    Skip the data collection deployment (if already deployed).

.PARAMETER SkipWorkbook
    Skip the workbook deployment (if already deployed).

.EXAMPLE
    # Use existing Automation Account, create a new Log Analytics Workspace
    .\Deploy-SQLMonitoringSolution.ps1 `
        -ResourceGroupName "rg-sql-monitoring" `
        -Location "eastus" `
        -AutomationAccountName "existing-aa" `
        -AutomationAccountResourceGroup "rg-shared-services" `
        -LogAnalyticsWorkspaceName "sql-monitoring-law" `
        -CreateLogAnalyticsWorkspace

.EXAMPLE
    # Use all existing resources (Automation Account, LAW, Key Vault)
    .\Deploy-SQLMonitoringSolution.ps1 `
        -ResourceGroupName "rg-sql-monitoring" `
        -Location "eastus" `
        -AutomationAccountName "existing-aa" `
        -AutomationAccountResourceGroup "rg-shared-services" `
        -LogAnalyticsWorkspaceName "existing-law" `
        -LogAnalyticsWorkspaceResourceGroup "rg-monitoring" `
        -SqlAuthenticationType "SQL" `
        -KeyVaultName "existing-kv" `
        -KeyVaultResourceGroup "rg-security"

.EXAMPLE
    # Create everything from scratch
    .\Deploy-SQLMonitoringSolution.ps1 `
        -ResourceGroupName "rg-sql-monitoring" `
        -Location "eastus" `
        -AutomationAccountName "sql-monitoring-aa" `
        -CreateAutomationAccount `
        -LogAnalyticsWorkspaceName "sql-monitoring-law" `
        -CreateLogAnalyticsWorkspace `
        -SqlAuthenticationType "SQL" `
        -KeyVaultName "sql-monitoring-kv" `
        -CreateKeyVault

.NOTES
    Prerequisites:
    - Azure CLI installed and logged in (az login)
    - Contributor access to the target subscription
    - Run from the CustomerTemplates folder
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $false)]
    [string]$AutomationAccountResourceGroup,

    [switch]$CreateAutomationAccount,

    [Parameter(Mandatory = $true)]
    [string]$LogAnalyticsWorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceResourceGroup,

    [switch]$CreateLogAnalyticsWorkspace,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Windows", "SQL")]
    [string]$SqlAuthenticationType = "Windows",

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName = "",

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultResourceGroup,

    [switch]$CreateKeyVault,

    [Parameter(Mandatory = $false)]
    [string]$DataCollectionEndpointName = "sql-monitoring-dce",

    [Parameter(Mandatory = $false)]
    [string]$DataCollectionRuleName = "dcr-sql-monitoring",

    [Parameter(Mandatory = $false)]
    [string]$WorkbookDisplayName = "SQL Server Monitoring Dashboard",

    [switch]$SkipInfrastructure,
    [switch]$SkipDataCollection,
    [switch]$SkipWorkbook
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# Validate prerequisites
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SQL Server Monitoring Solution - Deployment Script" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check Azure CLI
try {
    $azAccount = az account show 2>&1 | ConvertFrom-Json
    Write-Host "[OK] Logged into Azure as: $($azAccount.user.name)" -ForegroundColor Green
    Write-Host "     Subscription: $($azAccount.name) ($($azAccount.id))" -ForegroundColor Gray
} catch {
    Write-Host "[ERROR] Azure CLI not logged in. Please run 'az login' first." -ForegroundColor Red
    exit 1
}

# Default resource group parameters
if ([string]::IsNullOrEmpty($AutomationAccountResourceGroup)) {
    $AutomationAccountResourceGroup = $ResourceGroupName
}
if ([string]::IsNullOrEmpty($LogAnalyticsWorkspaceResourceGroup)) {
    $LogAnalyticsWorkspaceResourceGroup = $ResourceGroupName
}
if ([string]::IsNullOrEmpty($KeyVaultResourceGroup)) {
    $KeyVaultResourceGroup = $ResourceGroupName
}

# Compute effective resource groups (where the resource actually lives)
$effectiveAaRg = if ($CreateAutomationAccount) { $ResourceGroupName } else { $AutomationAccountResourceGroup }
$effectiveLawRg = if ($CreateLogAnalyticsWorkspace) { $ResourceGroupName } else { $LogAnalyticsWorkspaceResourceGroup }
$effectiveKvRg = if ($CreateKeyVault) { $ResourceGroupName } else { $KeyVaultResourceGroup }

# Validate SQL Auth parameters
if ($SqlAuthenticationType -eq "SQL" -and [string]::IsNullOrEmpty($KeyVaultName)) {
    Write-Host "[ERROR] KeyVaultName is required when using SQL Authentication." -ForegroundColor Red
    exit 1
}

$enableKeyVault = ($SqlAuthenticationType -eq "SQL")

Write-Host ""
Write-Host "Deployment Configuration:" -ForegroundColor Yellow
Write-Host "  Resource Group:        $ResourceGroupName"
Write-Host "  Location:              $Location"
Write-Host "  Automation Account:    $AutomationAccountName $(if ($CreateAutomationAccount) { '(CREATE)' } else { "(existing in $effectiveAaRg)" })"
Write-Host "  Log Analytics:         $LogAnalyticsWorkspaceName $(if ($CreateLogAnalyticsWorkspace) { '(CREATE)' } else { "(existing in $effectiveLawRg)" })"
Write-Host "  Auth Type:             $SqlAuthenticationType"
if ($enableKeyVault) {
    Write-Host "  Key Vault:             $KeyVaultName $(if ($CreateKeyVault) { '(CREATE)' } else { "(existing in $effectiveKvRg)" })"
}
Write-Host "  DCE Name:              $DataCollectionEndpointName"
Write-Host "  DCR Name:              $DataCollectionRuleName"
Write-Host "  Workbook:              $WorkbookDisplayName"
Write-Host ""

# Confirm
$confirm = Read-Host "Proceed with deployment? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "Deployment cancelled." -ForegroundColor Yellow
    exit 0
}

# Create Resource Group if it doesn't exist
Write-Host ""
Write-Host "--- Ensuring Resource Group exists ---" -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName 2>&1
if ($rgExists -eq "false") {
    Write-Host "Creating resource group: $ResourceGroupName in $Location"
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "[OK] Resource group created." -ForegroundColor Green
} else {
    Write-Host "[OK] Resource group already exists." -ForegroundColor Green
}

# =====================================================
# STEP 1: Deploy Infrastructure
# =====================================================
if (-not $SkipInfrastructure) {
    Write-Host ""
    Write-Host "--- Step 1/4: Deploying Infrastructure ---" -ForegroundColor Cyan
    Write-Host "  (Automation Account, Log Analytics Workspace, Custom Table, Key Vault)"

    $infraParams = @{
        automationAccountName              = @{ value = $AutomationAccountName }
        createAutomationAccount            = @{ value = $CreateAutomationAccount.IsPresent }
        automationAccountResourceGroup     = @{ value = $AutomationAccountResourceGroup }
        logAnalyticsWorkspaceName          = @{ value = $LogAnalyticsWorkspaceName }
        createLogAnalyticsWorkspace        = @{ value = $CreateLogAnalyticsWorkspace.IsPresent }
        logAnalyticsWorkspaceResourceGroup = @{ value = $LogAnalyticsWorkspaceResourceGroup }
        location                           = @{ value = $Location }
        enableKeyVault                     = @{ value = $enableKeyVault }
        createKeyVault                     = @{ value = $CreateKeyVault.IsPresent }
    }
    if ($enableKeyVault) {
        $infraParams.keyVaultName = @{ value = $KeyVaultName }
        $infraParams.keyVaultResourceGroup = @{ value = $KeyVaultResourceGroup }
    }

    $infraParamsJson = $infraParams | ConvertTo-Json -Depth 5 -Compress
    $infraParamsFile = Join-Path $env:TEMP "infra-params.json"
    $infraParamsJson | Set-Content -Path $infraParamsFile -Force

    $infraResult = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file "$scriptDir\arm-template-infrastructure.json" `
        --parameters "@$infraParamsFile" `
        --output json 2>&1

    $infraOutput = $infraResult | ConvertFrom-Json
    if ($infraOutput.properties.provisioningState -eq "Succeeded") {
        Write-Host "[OK] Infrastructure deployed successfully." -ForegroundColor Green
        $automationPrincipalId = $infraOutput.properties.outputs.automationAccountPrincipalId.value
        Write-Host "     Automation Account Principal ID: $automationPrincipalId" -ForegroundColor Gray
    } else {
        Write-Host "[ERROR] Infrastructure deployment failed." -ForegroundColor Red
        Write-Host $infraResult
        exit 1
    }

    Remove-Item $infraParamsFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ""
    Write-Host "--- Step 1/4: Infrastructure (SKIPPED) ---" -ForegroundColor Yellow
    # Get existing principal ID
    $automationPrincipalId = az automation account show `
        --resource-group $effectiveAaRg `
        --name $AutomationAccountName `
        --query "identity.principalId" -o tsv 2>&1
    Write-Host "     Automation Account Principal ID: $automationPrincipalId" -ForegroundColor Gray
}

# =====================================================
# STEP 2: Deploy Data Collection Components
# =====================================================
if (-not $SkipDataCollection) {
    Write-Host ""
    Write-Host "--- Step 2/4: Deploying Data Collection Components ---" -ForegroundColor Cyan
    Write-Host "  (Data Collection Endpoint, Data Collection Rule)"

    $dcParams = @{
        dataCollectionEndpointName       = @{ value = $DataCollectionEndpointName }
        dataCollectionRuleName           = @{ value = $DataCollectionRuleName }
        logAnalyticsWorkspaceName        = @{ value = $LogAnalyticsWorkspaceName }
        logAnalyticsWorkspaceResourceGroup = @{ value = $effectiveLawRg }
        location                         = @{ value = $Location }
    }

    $dcParamsJson = $dcParams | ConvertTo-Json -Depth 5 -Compress
    $dcParamsFile = Join-Path $env:TEMP "dc-params.json"
    $dcParamsJson | Set-Content -Path $dcParamsFile -Force

    $dcResult = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file "$scriptDir\arm-template-data-collection.json" `
        --parameters "@$dcParamsFile" `
        --output json 2>&1

    $dcOutput = $dcResult | ConvertFrom-Json
    if ($dcOutput.properties.provisioningState -eq "Succeeded") {
        Write-Host "[OK] Data Collection components deployed successfully." -ForegroundColor Green
        $dceEndpoint = $dcOutput.properties.outputs.dceEndpoint.value
        $dcrImmutableId = $dcOutput.properties.outputs.dcrImmutableId.value
        $dcrResourceId = $dcOutput.properties.outputs.dcrResourceId.value
        Write-Host "     DCE Endpoint:    $dceEndpoint" -ForegroundColor Gray
        Write-Host "     DCR Immutable ID: $dcrImmutableId" -ForegroundColor Gray
    } else {
        Write-Host "[ERROR] Data Collection deployment failed." -ForegroundColor Red
        Write-Host $dcResult
        exit 1
    }

    Remove-Item $dcParamsFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ""
    Write-Host "--- Step 2/4: Data Collection (SKIPPED) ---" -ForegroundColor Yellow
    $dceEndpoint = az monitor data-collection endpoint show `
        --resource-group $effectiveLawRg `
        --name $DataCollectionEndpointName `
        --query "logsIngestion.endpoint" -o tsv 2>&1
    $dcrImmutableId = az monitor data-collection rule show `
        --resource-group $effectiveLawRg `
        --name $DataCollectionRuleName `
        --query "immutableId" -o tsv 2>&1
    $dcrResourceId = az monitor data-collection rule show `
        --resource-group $effectiveLawRg `
        --name $DataCollectionRuleName `
        --query "id" -o tsv 2>&1
    Write-Host "     DCE Endpoint:    $dceEndpoint" -ForegroundColor Gray
    Write-Host "     DCR Immutable ID: $dcrImmutableId" -ForegroundColor Gray
}

# =====================================================
# STEP 3: Configure RBAC
# =====================================================
Write-Host ""
Write-Host "--- Step 3/4: Configuring RBAC Permissions ---" -ForegroundColor Cyan

if ($automationPrincipalId -and $dcrResourceId) {
    # Monitoring Metrics Publisher on DCR
    Write-Host "  Assigning 'Monitoring Metrics Publisher' role on DCR..."
    az role assignment create `
        --assignee $automationPrincipalId `
        --role "Monitoring Metrics Publisher" `
        --scope $dcrResourceId `
        --output none 2>&1 | Out-Null
    Write-Host "[OK] Monitoring Metrics Publisher role assigned." -ForegroundColor Green

    # Key Vault Secrets User (if SQL Auth)
    if ($enableKeyVault -and $KeyVaultName) {
        $kvId = az keyvault show --name $KeyVaultName --query "id" -o tsv 2>&1
        if ($kvId) {
            Write-Host "  Assigning 'Key Vault Secrets User' role on Key Vault..."
            az role assignment create `
                --assignee $automationPrincipalId `
                --role "Key Vault Secrets User" `
                --scope $kvId `
                --output none 2>&1 | Out-Null
            Write-Host "[OK] Key Vault Secrets User role assigned." -ForegroundColor Green
        }
    }
} else {
    Write-Host "[WARNING] Could not configure RBAC automatically. Please assign manually:" -ForegroundColor Yellow
    Write-Host "  - 'Monitoring Metrics Publisher' on the DCR" -ForegroundColor Yellow
    Write-Host "  - 'Key Vault Secrets User' on the Key Vault (if using SQL Auth)" -ForegroundColor Yellow
}

# =====================================================
# STEP 4: Deploy Workbook
# =====================================================
if (-not $SkipWorkbook) {
    Write-Host ""
    Write-Host "--- Step 4/4: Deploying Workbook ---" -ForegroundColor Cyan

    $wbParams = @{
        workbookDisplayName = @{ value = $WorkbookDisplayName }
        location            = @{ value = $Location }
    }

    $wbParamsJson = $wbParams | ConvertTo-Json -Depth 5 -Compress
    $wbParamsFile = Join-Path $env:TEMP "wb-params.json"
    $wbParamsJson | Set-Content -Path $wbParamsFile -Force

    $wbResult = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file "$scriptDir\arm-template-workbook.json" `
        --parameters "@$wbParamsFile" `
        --output json 2>&1

    $wbOutput = $wbResult | ConvertFrom-Json
    if ($wbOutput.properties.provisioningState -eq "Succeeded") {
        Write-Host "[OK] Workbook deployed successfully." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Workbook deployment failed." -ForegroundColor Red
        Write-Host $wbResult
    }

    Remove-Item $wbParamsFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ""
    Write-Host "--- Step 4/4: Workbook (SKIPPED) ---" -ForegroundColor Yellow
}

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Deployment Complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Set up the Hybrid Worker:" -ForegroundColor White
Write-Host "     Go to Automation Account → Hybrid Worker Groups → Create" -ForegroundColor Gray
Write-Host "     Add your Arc-enabled server or Azure VM" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Import the Runbook:" -ForegroundColor White
Write-Host "     Go to Automation Account → Runbooks → Create" -ForegroundColor Gray
Write-Host "     Name: Get-SQLServerInfo-LogsIngestionApi" -ForegroundColor Gray
Write-Host "     Type: PowerShell, Runtime: 7.2" -ForegroundColor Gray
Write-Host "     Upload: Get-SQLServerInfo-LogsIngestionApi.ps1 from this folder" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Create the SqlInstances variable:" -ForegroundColor White
Write-Host "     Go to Automation Account → Variables → Add a variable" -ForegroundColor Gray
Write-Host "     Name: SqlInstances" -ForegroundColor Gray
Write-Host "     Value: [\"Server1\", \"Server2\", \"10.0.0.5\"]  (JSON array)" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Create a Schedule and link to the Runbook:" -ForegroundColor White
Write-Host "     Frequency: Every 1 hour (recommended)" -ForegroundColor Gray
Write-Host "     Run on: Hybrid Worker group" -ForegroundColor Gray
Write-Host ""
Write-Host "  5. Runbook Parameters (in the schedule link):" -ForegroundColor White
Write-Host "     SqlAuthenticationType: $SqlAuthenticationType" -ForegroundColor Gray
if ($dceEndpoint) {
    Write-Host "     DceEndpoint:           $dceEndpoint" -ForegroundColor Gray
}
if ($dcrImmutableId) {
    Write-Host "     DcrImmutableId:        $dcrImmutableId" -ForegroundColor Gray
}
Write-Host "     StreamName:            Custom-SQLServerMonitoring_CL" -ForegroundColor Gray
if ($enableKeyVault) {
    Write-Host "     KeyVaultName:          $KeyVaultName" -ForegroundColor Gray
    Write-Host "     SqlUsernameSecretName: SqlMonitorUsername" -ForegroundColor Gray
    Write-Host "     SqlPasswordSecretName: SqlMonitorPassword" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  6. Store SQL credentials in Key Vault:" -ForegroundColor White
    Write-Host "     Go to Key Vault → Secrets → Generate/Import" -ForegroundColor Gray
    Write-Host "     Create: SqlMonitorUsername and SqlMonitorPassword" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  7. View the Workbook:" -ForegroundColor White
Write-Host "     Azure Portal → Monitor → Workbooks → '$WorkbookDisplayName'" -ForegroundColor Gray
Write-Host ""
