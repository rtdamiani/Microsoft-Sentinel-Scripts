<#
Script para deploy de CustomDetectionRules por arquivo YAML das regras.
#>

# Diretório onde estão os YAMLs
$rulesPath = "C:\Detections"

# Verifica se o diretório existe
if (-not (Test-Path $rulesPath)) {
    Write-Host "Diretório não encontrado: $rulesPath" -ForegroundColor Red
    exit
}

# Lista todos os arquivos YAML
$yamlFiles = Get-ChildItem -Path $rulesPath -Filter *.yaml

if ($yamlFiles.Count -eq 0) {
    Write-Host "Nenhum arquivo YAML encontrado em $rulesPath" -ForegroundColor Yellow
    exit
}

Write-Host "Encontrados $($yamlFiles.Count) arquivos YAML. Iniciando deploy..." -ForegroundColor Cyan

# Loop para deploy de cada regra

foreach ($file in $yamlFiles) {
    Write-Host "Deploying: $($file.Name)" -ForegroundColor Yellow

    try {
        Deploy-CustomDetection -InputFile $file.FullName -Verbose
        Write-Host "OK: $($file.Name)" -ForegroundColor Green
    }
    catch {
        Write-Host "ERRO ao processar $($file.Name): $_" -ForegroundColor Red
    }
}

Write-Host "Processo concluído!" -ForegroundColor Cyan
