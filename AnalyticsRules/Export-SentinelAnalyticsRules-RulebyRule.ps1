<#
Exports Sentinel Analytics Rules in Portal format (Analytics -> Export,
Creates a JSON file for each rule.

Uso:
powershell -ExecutionPolicy Bypass -File .\Export-SentinelAnalyticsRules-RulebyRule.ps1
.\Export-SentinelAnalyticsRules-PortalImport.ps1 -SubscriptionId "..." -ResourceGroupName "..." -WorkspaceName "..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\SentinelRules-PortalImport",

    # Por padrão exporta TUDO. Use -SkipDisabled para pular desabilitadas.
    [Parameter(Mandatory = $false)]
    [switch]$SkipDisabled,

    # Tipos mais comuns/importáveis
    [Parameter(Mandatory = $false)]
    [string[]]$ExportKinds = @("Scheduled", "NRT"),

    # Igual ao export do Portal que você colou
    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "2023-12-01-preview"
)

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-SafeFileName {
    param([Parameter(Mandatory=$true)][string]$FileName)

    $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
    $sanitized = $FileName -replace "[$invalidChars]", "_"
    $sanitized = $sanitized -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($sanitized)) { $sanitized = "rule" }
    return $sanitized.Substring(0, [Math]::Min($sanitized.Length, 120))
}

function Ensure-Modules {
    Write-Log "Verificando modulos necessarios..."
    $mods = @("Az.Accounts", "Az.SecurityInsights")
    foreach ($m in $mods) {
        if (!(Get-Module -ListAvailable -Name $m)) {
            Write-Log "Instalando modulo: $m" -Level "WARN"
            Install-Module -Name $m -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        }
        Import-Module $m -Force -ErrorAction Stop
    }
}

function Connect-And-SetContext {
    Write-Log "Conectando ao Azure..."
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (!$ctx) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Contexto definido para subscription: $SubscriptionId"
}

function New-OutputStructure {
    param([Parameter(Mandatory=$true)][string]$BasePath)

    $dirs = @(
        "$BasePath",
        (Join-Path $BasePath "Scheduled"),
        (Join-Path $BasePath "NRT"),
        (Join-Path $BasePath "Other")
    )

    foreach ($d in ($dirs | Select-Object -Unique)) {
        if (!(Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Log "Diretorio criado: $d"
        }
    }
}

function Get-AlertRuleJsonViaArmRest {
    param([Parameter(Mandatory=$true)][string]$RuleGuid)

    $path =
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
        "/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" +
        "/providers/Microsoft.SecurityInsights/alertRules/$RuleGuid" +
        "?api-version=$ApiVersion"

    $resp = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
    return $resp.Content
}

function Remove-ReadOnlyProperties {
    param(
        [Parameter(Mandatory=$true)]$PropertiesObject
    )

    # Lista prática de campos read-only/gerenciados que causam erro em deploy/import
    # (além do lastModifiedUtc que você já viu)
    $readOnlyProps = @(
        "lastModifiedUtc",
        "createdUtc",
        "createdBy",
        "lastModifiedBy",
        "etag",
        "systemData"
    )

    foreach ($p in $readOnlyProps) {
        if ($PropertiesObject.PSObject.Properties.Name -contains $p) {
            $null = $PropertiesObject.PSObject.Properties.Remove($p)
        }
    }

    return $PropertiesObject
}

function Build-PortalExportJsonText {
    param(
        [Parameter(Mandatory=$true)][string]$RuleGuid,
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][string]$PropertiesJson
    )

    @"
{
  "`$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "workspace": { "type": "String" }
  },
  "resources": [
    {
      "id": "[concat(resourceId('Microsoft.OperationalInsights/workspaces/providers', parameters('workspace'), 'Microsoft.SecurityInsights'),'/alertRules/$RuleGuid')]",
      "name": "[concat(parameters('workspace'),'/Microsoft.SecurityInsights/$RuleGuid')]",
      "type": "Microsoft.OperationalInsights/workspaces/providers/alertRules",
      "kind": "$Kind",
      "apiVersion": "$ApiVersion",
      "properties": $PropertiesJson
    }
  ]
}
"@
}

function Export-Rules {
    Write-Log "Iniciando exportacao no formato do Portal (Analytics -> Export/Import)"

    Ensure-Modules
    Connect-And-SetContext
    New-OutputStructure -BasePath $OutputPath

    Write-Log "Obtendo lista de Analytics Rules do workspace: $WorkspaceName"
    $rules = Get-AzSentinelAlertRule -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ErrorAction Stop

    if (!$rules) {
        Write-Log "Nenhuma Analytics Rule encontrada." -Level "WARN"
        return
    }

    Write-Log "Encontradas $($rules.Count) regras."

    $exported = 0
    $skipped  = 0
    $errors   = 0
    $nameCounter = @{}

    foreach ($r in $rules) {
        try {
            if ($SkipDisabled -and ($r.PSObject.Properties.Name -contains "Enabled") -and (-not $r.Enabled)) {
                Write-Log "Pulando desabilitada: $($r.DisplayName)" -Level "WARN"
                $skipped++
                continue
            }

            if ($r.Kind -notin $ExportKinds) {
                Write-Log "Pulando Kind '$($r.Kind)': $($r.DisplayName)" -Level "WARN"
                $skipped++
                continue
            }

            $subDir = if ($r.Kind -in @("Scheduled","NRT")) { $r.Kind } else { "Other" }

            $safe = Get-SafeFileName -FileName $r.DisplayName
            $base = $safe
            $i = 1
            while ($nameCounter.ContainsKey("$subDir\$safe")) {
                $safe = "${base}_$i"
                $i++
            }
            $nameCounter["$subDir\$safe"] = $true

            $filePath = Join-Path (Join-Path $OutputPath $subDir) ($safe + ".json")

            $raw = Get-AlertRuleJsonViaArmRest -RuleGuid $r.Name
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop

            $kind = $obj.kind
            $propsObj = $obj.properties

            # remove read-only
            $propsObj = Remove-ReadOnlyProperties -PropertiesObject $propsObj

            # serializa properties (somente properties) — normalmente não estoura mais; se estourar, ajustamos para extração por texto
            $propertiesJson = $propsObj | ConvertTo-Json -Depth 100

            $finalText = Build-PortalExportJsonText -RuleGuid $r.Name -Kind $kind -PropertiesJson $propertiesJson

            # valida JSON final
            $null = $finalText | ConvertFrom-Json -ErrorAction Stop

            $finalText | Out-File -FilePath $filePath -Encoding UTF8 -Force
            Write-Log "Exportada: $($r.DisplayName) -> $filePath"
            $exported++
        }
        catch {
            Write-Log "Erro ao exportar '$($r.DisplayName)': $($_.Exception.Message)" -Level "ERROR"
            $errors++
        }
    }

    $index = @{
        exportSummary = @{
            exportDateUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
            sourceWorkspace = $WorkspaceName
            sourceResourceGroup = $ResourceGroupName
            sourceSubscription = $SubscriptionId
            apiVersion = $ApiVersion
            exportKinds = $ExportKinds
            skipDisabled = [bool]$SkipDisabled
            totalRules = $rules.Count
            exportedRules = $exported
            skippedRules = $skipped
            errors = $errors
        }
        rulesSummary = $rules | Select-Object Name, DisplayName, Kind, Enabled, Severity | Sort-Object Kind, DisplayName
    }

    $indexPath = Join-Path $OutputPath "export-index.json"
    $index | ConvertTo-Json -Depth 20 | Out-File -FilePath $indexPath -Encoding UTF8 -Force

    Write-Log "=== RELATORIO ===" -Level "SUCCESS"
    Write-Log "Exportadas: $exported" -Level "SUCCESS"
    Write-Log "Puladas: $skipped" -Level "SUCCESS"
    Write-Log "Erros: $errors" -Level "SUCCESS"
    Write-Log "Arquivos salvos em: $OutputPath" -Level "SUCCESS"
    Write-Log "Indice: $indexPath" -Level "SUCCESS"
}


Export-Rules
