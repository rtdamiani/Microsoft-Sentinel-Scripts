$ErrorActionPreference = "Stop"

# =============================
# Entrada: lista de servidores
# =============================
$serversFile = ".\servers.txt"
if (!(Test-Path $serversFile)) { throw "Arquivo não encontrado: $serversFile" }

$servers = Get-Content $serversFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    Select-Object -Unique

if ($servers.Count -eq 0) { throw "Nenhum servidor válido encontrado no arquivo $serversFile" }

# =============================
# Parâmetros Azure / Arc / DCR
# =============================
$tenantId = "<TENANT_ID>"
$appId    = "<APPLICATION_ID>"
$appSecretPlain = "<PASSWORD>"  # ideal: pegar de cofre. Para manual, ok temporário.

$subscriptionId  = "<SUBSCRIPTION_ID_DESTINO>"
$arcResourceGroup = "<RG_ARC_DESTINO>"
$location = "<LOCATION_DO_ARC>" # ex: brazilsouth, eastus, westeurope
$cloud = "AzureCloud"

# DCR (Resource ID completo)
$dcrRuleId = "<DCR_RULE_RESOURCE_ID>"  # /subscriptions/.../resourceGroups/.../providers/Microsoft.Insights/dataCollectionRules/<name>

# Nome fixo para associação (se já existir com o mesmo nome, o script apaga e recria)
$associationName = "ama-dcr-association"

# Se $true, usa o nome do servidor como nome do recurso Arc
$useServerNameAsArcResourceName = $true

# =============================
# Helper: Azure CLI login (SP)
# =============================
function Ensure-AzCliLogin {
    param(
        [string]$TenantId, [string]$AppId, [string]$AppSecretPlain, [string]$SubscriptionId
    )

    $az = Get-Command az -ErrorAction Stop

    # Login SP (idempotente)
    & az login --service-principal -u $AppId -p $AppSecretPlain --tenant $TenantId | Out-Null
    & az account set --subscription $SubscriptionId | Out-Null
}

# =============================
# Execução
# =============================
Ensure-AzCliLogin -TenantId $tenantId -AppId $appId -AppSecretPlain $appSecretPlain -SubscriptionId $subscriptionId

$results = New-Object System.Collections.Generic.List[object]

foreach ($serverName in $servers) {

    Write-Host "========================================="
    Write-Host "Servidor: $serverName"
    Write-Host "========================================="

    $arcResourceName = if ($useServerNameAsArcResourceName) { $serverName } else { $serverName }

    try {
        # 1) No servidor: disconnect/update/connect (puxa versão mais nova via update)
        Invoke-Command -ComputerName $serverName -ScriptBlock {
            param(
                [string]$TenantId,
                [string]$AppId,
                [string]$AppSecretPlain,
                [string]$SubscriptionId,
                [string]$ArcResourceGroup,
                [string]$Location,
                [string]$Cloud,
                [string]$ArcResourceName
            )

            $ErrorActionPreference = "Stop"

            $azcm = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            if (!(Test-Path $azcm)) {
                throw "azcmagent.exe não encontrado em $azcm. O Azure Arc agent está instalado?"
            }

            Write-Host "1) Versão atual do Arc agent:"
            & $azcm version

            Write-Host "2) Disconnect (tolerante):"
            try { & $azcm disconnect } catch { Write-Host "Aviso disconnect: $($_.Exception.Message)" }

            Write-Host "3) Update (busca a versão mais nova na internet):"
            & $azcm update

            Write-Host "4) Connect (Service Principal):"
            & $azcm connect `
                --service-principal-id $AppId `
                --service-principal-secret $AppSecretPlain `
                --tenant-id $TenantId `
                --subscription-id $SubscriptionId `
                --resource-group $ArcResourceGroup `
                --location $Location `
                --cloud $Cloud `
                --resource-name $ArcResourceName

            Write-Host "5) Check:"
            & $azcm check

        } -ArgumentList `
            $tenantId,
            $appId,
            $appSecretPlain,
            $subscriptionId,
            $arcResourceGroup,
            $location,
            $cloud,
            $arcResourceName

        # 2) No Azure: instalar AMA extension + associar DCR
        # Descobre o Arc machine ID pelo nome
        $arcId = (& az connectedmachine show -g $arcResourceGroup -n $arcResourceName --query id -o tsv).Trim()
        if ([string]::IsNullOrWhiteSpace($arcId)) { throw "Não consegui obter o resourceId do Arc machine ($arcResourceName)." }

        $osType = (& az connectedmachine show -g $arcResourceGroup -n $arcResourceName --query properties.osType -o tsv).Trim().ToLower()

        if ($osType -eq "windows") {
            $extName = "AzureMonitorWindowsAgent"
            $extType = "AzureMonitorWindowsAgent"
        }
        elseif ($osType -eq "linux") {
            $extName = "AzureMonitorLinuxAgent"
            $extType = "AzureMonitorLinuxAgent"
        }
        else {
            throw "osType não reconhecido para $arcResourceName: '$osType'"
        }

        Write-Host "Instalando/garantindo AMA ($osType) no Arc resource $arcResourceName..."
        & az connectedmachine extension create `
            --resource-group $arcResourceGroup `
            --machine-name $arcResourceName `
            --name $extName `
            --publisher "Microsoft.Azure.Monitor" `
            --type $extType `
            --location $location `
            --enable-auto-upgrade true | Out-Null

        # Se a associação existir com o mesmo nome, removemos e recriamos (para ficar idempotente)
        $existingAssoc = (& az monitor data-collection rule association show --name $associationName --resource $arcId --query name -o tsv 2>$null).Trim()
        if ($existingAssoc) {
            Write-Host "Associação DCR '$associationName' já existe; recriando..."
            & az monitor data-collection rule association delete --name $associationName --resource $arcId | Out-Null
        }

        Write-Host "Associando DCR ao Arc machine..."
        & az monitor data-collection rule association create `
            --name $associationName `
            --resource $arcId `
            --rule-id $dcrRuleId | Out-Null

        $results.Add([pscustomobject]@{
            Server   = $serverName
            ArcName  = $arcResourceName
            OsType   = $osType
            Status   = "OK"
            Error    = ""
        })
    }
    catch {
        $results.Add([pscustomobject]@{
            Server   = $serverName
            ArcName  = $arcResourceName
            OsType   = ""
            Status   = "ERRO"
            Error    = $_.Exception.Message
        })
        Write-Host "Falhou em $serverName: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "========== RESUMO =========="
$results | Sort-Object Status, Server | Format-Table -AutoSize
