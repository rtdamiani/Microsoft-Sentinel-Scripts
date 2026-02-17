<#
.SYNOPSIS
  Exports Sentinel Analytics Rules in Portal format (Analytics -> Export,
  Creates a single JSON file containing all the rules.

.DESCRIPTION
- Collects rules (Scheduled/NRT by default)

- For each rule, reads via ARM REST (Invoke-AzRestMethod) forcing api-version

- Removes read-only properties (e.g., lastModifiedUtc)

- Creates 1 ARM template with several alertRules resources
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

    [Parameter(Mandatory = $false)]
    [string]$OutputFileName = "sentinel-analytics-rules-export.json",

    # Por padrão exporta TUDO. Use -SkipDisabled para pular desabilitadas.
    [Parameter(Mandatory = $false)]
    [switch]$SkipDisabled,

    [Parameter(Mandatory = $false)]
    [string[]]$ExportKinds = @("Scheduled", "NRT"),

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

function New-Dir {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
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
    param([Parameter(Mandatory=$true)]$PropertiesObject)

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

function Export-AllRulesSingleFile {
    Write-Log "Iniciando exportacao (arquivo unico) no formato do Portal"

    Ensure-Modules
    Connect-And-SetContext

    New-Dir -Path $OutputPath

    Write-Log "Obtendo lista de Analytics Rules do workspace: $WorkspaceName"
    $rules = Get-AzSentinelAlertRule -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ErrorAction Stop

    if (!$rules) {
        Write-Log "Nenhuma Analytics Rule encontrada." -Level "WARN"
        return
    }

    Write-Log "Encontradas $($rules.Count) regras."

    $resources = New-Object System.Collections.Generic.List[object]
    $added = 0
    $skipped = 0
    $errors = 0

    foreach ($r in $rules) {
        try {
            if ($SkipDisabled -and ($r.PSObject.Properties.Name -contains "Enabled") -and (-not $r.Enabled)) {
                $skipped++
                continue
            }

            if ($r.Kind -notin $ExportKinds) {
                $skipped++
                continue
            }

            $raw = Get-AlertRuleJsonViaArmRest -RuleGuid $r.Name
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop

            $kind = $obj.kind
            $propsObj = Remove-ReadOnlyProperties -PropertiesObject $obj.properties

            $ruleGuid = $r.Name

            $res = [ordered]@{
                id = "[concat(resourceId('Microsoft.OperationalInsights/workspaces/providers', parameters('workspace'), 'Microsoft.SecurityInsights'),'/alertRules/$ruleGuid')]"
                name = "[concat(parameters('workspace'),'/Microsoft.SecurityInsights/$ruleGuid')]"
                type = "Microsoft.OperationalInsights/workspaces/providers/alertRules"
                kind = $kind
                apiVersion = $ApiVersion
                properties = $propsObj
            }

            $resources.Add($res) | Out-Null
            $added++
        }
        catch {
            Write-Log "Erro ao incluir '$($r.DisplayName)': $($_.Exception.Message)" -Level "ERROR"
            $errors++
        }
    }

    $template = [ordered]@{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        parameters = @{
            workspace = @{
                type = "String"
            }
        }
        resources = $resources
        metadata = @{
            exportDateUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
            sourceWorkspace = $WorkspaceName
            sourceResourceGroup = $ResourceGroupName
            sourceSubscription = $SubscriptionId
            apiVersion = $ApiVersion
            exportKinds = $ExportKinds
            skipDisabled = [bool]$SkipDisabled
            totalRules = $rules.Count
            includedResources = $added
            skipped = $skipped
            errors = $errors
        }
    }

    $outFile = Join-Path $OutputPath $OutputFileName
    $template | ConvertTo-Json -Depth 100 | Out-File -FilePath $outFile -Encoding UTF8 -Force

    Write-Log "Arquivo unico gerado: $outFile" -Level "SUCCESS"
    Write-Log "Incluidas: $added | Puladas: $skipped | Erros: $errors" -Level "SUCCESS"
}

Export-AllRulesSingleFile