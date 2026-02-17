$ErrorActionPreference = "Stop"

# =============================
# Configurações
# =============================
$serversFile = ".\servers.txt"   # um nome por linha (nome do recurso Arc)
$tenantId    = "<TENANT_ID>"
$appId       = "<APPLICATION_ID>"
$appSecret   = "<PASSWORD>"
$subscriptionId = "<SUBSCRIPTION_ID>"

$arcResourceGroup = "<RG_ARC>"
$location = "<LOCATION>"         # ex: brazilsouth, eastus, westeurope

$dcrRuleId = "<DCR_RULE_RESOURCE_ID>"  # /subscriptions/.../resourceGroups/.../providers/Microsoft.Insights/dataCollectionRules/<name>
$associationName = "ama-dcr-association"

# =============================
# Validações iniciais
# =============================
if (!(Test-Path $serversFile)) { throw "Arquivo não encontrado: $serversFile" }

$servers = Get-Content $serversFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    Select-Object -Unique

if ($servers.Count -eq 0) { throw "Nenhum servidor válido encontrado em $serversFile" }

# =============================
# Login Azure CLI (SP)
# =============================
$null = & az login --service-principal -u $appId -p $appSecret --tenant $tenantId
$null = & az account set --subscription $subscriptionId

# =============================
# Execução em lote
# =============================
$results = New-Object System.Collections.Generic.List[object]

foreach ($arcMachineName in $servers) {
    Write-Host "-----------------------------------------"
    Write-Host "Processando (Windows): $arcMachineName"
    Write-Host "-----------------------------------------"

    try {
        # Confirma que é Windows
        $osType = (& az connectedmachine show -g $arcResourceGroup -n $arcMachineName --query properties.osType -o tsv).Trim().ToLower()
        if ($osType -ne "windows") {
            throw "osType='$osType' (este script é apenas para Windows)."
        }

        # Resource ID do Arc machine
        $arcId = (& az connectedmachine show -g $arcResourceGroup -n $arcMachineName --query id -o tsv).Trim()
        if ([string]::IsNullOrWhiteSpace($arcId)) { throw "Não consegui obter o resourceId do Arc machine." }

        # 1) Instala/garante AMA (Windows)
        $null = & az connectedmachine extension create `
            --resource-group $arcResourceGroup `
            --machine-name $arcMachineName `
            --name "AzureMonitorWindowsAgent" `
            --publisher "Microsoft.Azure.Monitor" `
            --type "AzureMonitorWindowsAgent" `
            --location $location `
            --enable-auto-upgrade true

        # 2) Associa DCR (idempotente: se existir, recria)
        $existingAssoc = (& az monitor data-collection rule association show --name $associationName --resource $arcId --query name -o tsv 2>$null).Trim()
        if ($existingAssoc) {
            $null = & az monitor data-collection rule association delete --name $associationName --resource $arcId
        }

        $null = & az monitor data-collection rule association create `
            --name $associationName `
            --resource $arcId `
            --rule-id $dcrRuleId

        $results.Add([pscustomobject]@{
            ArcMachine = $arcMachineName
            OsType     = $osType
            Status     = "OK"
            Error      = ""
        })
    }
    catch {
        $results.Add([pscustomobject]@{
            ArcMachine = $arcMachineName
            OsType     = ""
            Status     = "ERRO"
            Error      = $_.Exception.Message
        })
        Write-Host "Falhou: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "========== RESUMO (Windows) =========="
$results | Sort-Object Status, ArcMachine | Format-Table -AutoSize