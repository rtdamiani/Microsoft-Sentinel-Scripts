#!/usr/bin/env bash
set -euo pipefail

# =============================
# Configurações
# =============================
SERVERS_FILE="./servers.txt"     # um nome por linha (nome do recurso Arc)
TENANT_ID="<TENANT_ID>"
APP_ID="<APPLICATION_ID>"
APP_SECRET="<PASSWORD>"
SUBSCRIPTION_ID="<SUBSCRIPTION_ID>"

ARC_RG="<RG_ARC>"
LOCATION="<LOCATION>"            # ex: brazilsouth, eastus, westeurope

DCR_RULE_ID="<DCR_RULE_RESOURCE_ID>"   # /subscriptions/.../resourceGroups/.../providers/Microsoft.Insights/dataCollectionRules/<name>
ASSOCIATION_NAME="ama-dcr-association"

# =============================
# Validações iniciais
# =============================
if [[ ! -f "$SERVERS_FILE" ]]; then
  echo "Arquivo não encontrado: $SERVERS_FILE"
  exit 1
fi

mapfile -t SERVERS < <(grep -v '^\s*#' "$SERVERS_FILE" | sed '/^\s*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '!seen[$0]++')
if [[ ${#SERVERS[@]} -eq 0 ]]; then
  echo "Nenhum servidor válido encontrado em $SERVERS_FILE"
  exit 1
fi

# =============================
# Login Azure CLI (SP)
# =============================
az login --service-principal -u "$APP_ID" -p "$APP_SECRET" --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

# =============================
# Execução em lote
# =============================
echo "Processando ${#SERVERS[@]} servidores (Linux)..."

for ARC_MACHINE_NAME in "${SERVERS[@]}"; do
  echo "-----------------------------------------"
  echo "Processando (Linux): $ARC_MACHINE_NAME"
  echo "-----------------------------------------"

  # Confirma que é Linux
  OS_TYPE=$(az connectedmachine show -g "$ARC_RG" -n "$ARC_MACHINE_NAME" --query properties.osType -o tsv | tr '[:upper:]' '[:lower:]' | xargs)
  if [[ "$OS_TYPE" != "linux" ]]; then
    echo "Ignorando: osType='$OS_TYPE' (este script é apenas para Linux)."
    continue
  fi

  ARC_ID=$(az connectedmachine show -g "$ARC_RG" -n "$ARC_MACHINE_NAME" --query id -o tsv | xargs)
  if [[ -z "$ARC_ID" ]]; then
    echo "Falhou: não consegui obter o resourceId do Arc machine."
    continue
  fi

  # 1) Instala/garante AMA (Linux)
  az connectedmachine extension create \
    --resource-group "$ARC_RG" \
    --machine-name "$ARC_MACHINE_NAME" \
    --name "AzureMonitorLinuxAgent" \
    --publisher "Microsoft.Azure.Monitor" \
    --type "AzureMonitorLinuxAgent" \
    --location "$LOCATION" \
    --enable-auto-upgrade true >/dev/null

  # 2) Associa DCR (idempotente: se existir, recria)
  if az monitor data-collection rule association show --name "$ASSOCIATION_NAME" --resource "$ARC_ID" >/dev/null 2>&1; then
    az monitor data-collection rule association delete --name "$ASSOCIATION_NAME" --resource "$ARC_ID" >/dev/null
  fi

  az monitor data-collection rule association create \
    --name "$ASSOCIATION_NAME" \
    --resource "$ARC_ID" \
    --rule-id "$DCR_RULE_ID" >/dev/null

  echo "OK: AMA instalado e DCR associada em $ARC_MACHINE_NAME"
done

echo ""
echo "Concluído."