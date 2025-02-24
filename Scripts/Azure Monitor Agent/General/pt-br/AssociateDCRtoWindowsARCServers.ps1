# =================================================================================
# AssociateDCRtoWindowsARCServers.ps1
#
# Autor: Rogério T. Barros
# Versão 1.0 - 25/03/2022
# =================================================================================

# =================================================================================
# Seção onde devem ser alterados os dados antes da execução do script
# =================================================================================

# Substituir o tenantId pelo seu tenant ID (Acha no Azure Active Directory, no portal)
Connect-AzAccount -TenantId xxxx-yyyy-zzzz # Adicionar seu tenant

# =================================================================================
# Início do script
# =================================================================================

clear-host
write-host "Selecione a subscription na janela que vai ser aberta - apenas uma seleção (ela pode aparecer minimizada, procure na barra de tarefas)" -ForegroundColor Green
$subscription = Get-AzSubscription | Out-GridView -PassThru -Title "Selecionar subscription (apenas uma) e clique em ok"

Set-AzContext -SubscriptionObject $subscription

$FullWindowsARCServerList = get-azresource -ResourceType microsoft.HybridCompute/machines -ExpandProperties | ? {$_.Properties.osName -eq "windows"}

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
        $ArcServersList = $FullWindowsARCServerList
    }
    "2"
    {
        write-host "Selecione os servidores na janela que vai se abrir"
        $ArcServersList = $FullWindowsARCServerList | Out-GridView -PassThru -Title "Selecione os servidores (um ou mais) e clique em ok"
    }
    "3"
    {
        exit
    } 
}

$ARCServers = ($ArcServersList).Id
$instalados = 0
$AllDCRs = Get-AzDataCollectionRule 
write-host "Selecione a Data Collection Rule (apenas uma) na janela que vai se abrir"
$DCRChoice = $null
$DCRChoice = $AllDCRs | Select-Object Name, id | Out-GridView -Title "Selecione a Data Collection Rule (apenas uma) e clique em Ok" -PassThru
if ($DCRChoice.count -ne 1) 
{
    write-host "Data Collection Rule não escolhidas corretamente. Obrigatório escolher apenas uma. Saindo do script" -ForegroundColor Red
    start-sleep 5
    exit
}
$DCR = $AllDCRs | where-object {$_.id -eq $DCRChoice.id}

foreach ($ARCServer in $ARCServers)
{
    $CurrentServer = get-azresource -id $ARCServer
    write-host "Criando associação da regra" $DCR.name no servidor $CurrentServer.name -ForegroundColor Green
    New-AzDataCollectionRuleAssociation -TargetResourceId $CurrentServer.id -AssociationName $DCR.name -RuleId $DCR.Id
    $instalados++
}
write-host "Fim - servidores instalados: " $instalados "- Total de servidores analisados: " $ARCServers.count