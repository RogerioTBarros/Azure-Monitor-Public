# =================================================================================
# OnboardAMAWithProxy.ps1
#
# Autor: Rogério T. Barros
# Versão 1.0 - 25/03/2022
# =================================================================================

# =================================================================================
# Seção onde devem ser alterados os dados antes da execução do script
# =================================================================================

# Substituir o tenantId pelo seu tenant ID (Acha no Azure Active Directory, no portal)
Connect-AzAccount -TenantId xxxx-yyyy-zzzz # Adicionar seu tenant

# Coloque na variável abaixo o endereço do proxy que deseja utilizar para o Azure Monitor Agent
$ProxyAddr = "http://meuproxycustomizado:8080" # Proxy Qualquer
$ExtensionName = "AzureMonitorWindowsAgent-proxycustom"


function CheckCurrentExtensions {
    param ([string]$MachineName,[string]$ResourceGroup)
    $AMAWinExtensions = Get-AzConnectedMachineExtension -MachineName $MachineName -ResourceGroupName $ResourceGroup | ? {$_.MachineExtensionType -eq "AzureMonitorWindowsAgent"} | select Name, ProvisioningState
    if ($AMAWinExtensions)
    {
        Write-Host
        write-host "Extensões encontradas:" -ForegroundColor Yellow
        $AMAWinExtensions
        Return $true
    }
    else 
    {
        Return $false
    }
}

# =================================================================================
# Início do script
# =================================================================================

clear-host
write-host "Selecione a subscription na janela que vai ser aberta - apenas uma seleção (ela pode aparecer minimizada, procure na barra de tarefas)" -ForegroundColor Green
$subscription = Get-AzSubscription | Out-GridView -PassThru -Title "Selecionar subscription (apenas uma) e clique em ok"

Set-AzContext -SubscriptionObject $subscription


# Selecionar entre todos os recursos ou escolha entre máquinas ARC específicas
do 
{   
    clear-host
    write-host "======== Selecione as opções de escolha de servidores ARC Windows ========" -ForegroundColor Green
    write-host "1. Todos os servidores com agente ARC Windows"
    write-host "2. Escolher os servidores os servidores com agente ARC Windows"
    write-host "3. Sair"
    write-host
    $choice = Read-Host
} 
until ($choice -eq "1" -or $choice -eq "2" -or $choice -eq "3")
switch($choice)
{
    "1" 
    {
        $ArcServersList = get-azresource -ResourceType microsoft.HybridCompute/machines
    }
    "2"
    {
        write-host "Selecione os servidores na janela que vai se abrir"
        $ArcServersList = get-azresource -ResourceType microsoft.HybridCompute/machines | Out-GridView -PassThru -Title "Selecione os servidores (um ou mais) e clique em ok"
    }
    "3"
    {
        exit
    } 
}

$ARCServers = ($ArcServersList).id
$instalados = 0
foreach ($ARCServer in $ARCServers)
{
    $CurrentServer = get-azresource -id $ARCServer -ExpandProperties
    $CheckForExtension = Get-AzConnectedMachineExtension -MachineName $CurrentServer.name -ResourceGroupName $CurrentServer.ResourceGroupName
    $ExtensionInstalled = $false
    $CheckForExtension | % {if ($_.MachineExtensionType -eq "AzureMonitorWindowsAgent" -and $_.Name -eq $ExtensionName -and $_.ProvisioningState -eq "Succeeded") {$ExtensionInstalled = $true}}
    if (!($ExtensionInstalled)) 
    {
       if ($CurrentServer.Properties.osName -eq "windows")
       {
        if ((CheckCurrentExtensions -MachineName $CurrentServer.Name -ResourceGroup $CurrentServer.ResourceGroupName) -eq $false)
        { 
            write-host "Extensão não encontrada - instalando... Servidor " $CurrentServer.name -ForegroundColor Green

                $rg = $CurrentServer.ResourceGroupName
                $machine =  $CurrentServer.Name
                $location = $CurrentServer.Location
                
                $ProxySettings = '{
                    "proxy": {
                        "mode": "application",
                        "address": "' + $ProxyAddr + '",
                        "auth": false
                    }
                }'   

                # Adiciona Extension do AMA aos servidores
                New-AzConnectedMachineExtension -Name $ExtensionName -ExtensionType AzureMonitorWindowsAgent -Publisher Microsoft.Azure.Monitor -ResourceGroupName $rg -MachineName $machine -Location $location -Setting $ProxySettings -NoWait
                $instalados++
            }
            else 
            {
                write-host "Há outras extensões do tipo instaladas no servidor - não será tomada ação" -ForegroundColor Yellow
            }
       }
       
        else {
            write-host "O servidor " $CurrentServer.Name "não é uma máquina executando Windows. Instalação não aplicável" -ForegroundColor Yellow
        }      
        
    }
    else {
        write-host "Servidor já possui extensão instalada - Servidor " $CurrentServer.Name -ForegroundColor Red
    }
}
write-host "Fim - servidores instalados: " $instalados "- Total de servidores analisados: " $ARCServers.count

