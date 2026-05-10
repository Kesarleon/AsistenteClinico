#!/bin/bash
# =============================================================
# register_webhooks.sh
# Registra los dos webhooks necesarios en Kaja Uno:
#   1. whatsapp.client_message → agente principal
#   2. appointment.created     → recordatorios automáticos
#
# Uso:
#   chmod +x scripts/register_webhooks.sh
#   ./scripts/register_webhooks.sh
# =============================================================

set -euo pipefail

# Cargar variables de entorno
if [ ! -f ".env" ]; then
  echo "✗ Error: no se encontró el archivo .env en el directorio actual."
  echo "  Ejecuta desde la raíz del proyecto: ./scripts/register_webhooks.sh"
  exit 1
fi
source .env

# Validar variables requeridas
required_vars=("KAJA_API_TOKEN" "KAJA_TENANT_SLUG" "N8N_WEBHOOK_URL")
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "✗ Error: la variable $var no está definida en el .env"
    exit 1
  fi
done

KAJA_BASE="https://${KAJA_TENANT_SLUG}.kaja.uno"
AGENT_WEBHOOK_URL="${N8N_WEBHOOK_URL}/webhook/booking-agent"
REMINDER_WEBHOOK_URL="${N8N_WEBHOOK_URL}/webhook/appointment-reminder"

echo ""
echo "════════════════════════════════════════════════"
echo "  Registrando webhooks en Kaja Uno"
echo "  Tenant: ${KAJA_TENANT_SLUG}"
echo "════════════════════════════════════════════════"

# ── Webhook 1: whatsapp.client_message → Agente Principal ─────
echo ""
echo "1. Registrando webhook: whatsapp.client_message"
echo "   URL destino: ${AGENT_WEBHOOK_URL}"

RESPONSE_1=$(curl -s -w "\n%{http_code}" -X POST "${KAJA_BASE}/api/v1/webhooks/" \
  -H "Authorization: Bearer ${KAJA_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"event\": \"whatsapp.client_message\",
    \"url\": \"${AGENT_WEBHOOK_URL}\"
  }")

HTTP_CODE_1=$(echo "$RESPONSE_1" | tail -n1)
BODY_1=$(echo "$RESPONSE_1" | head -n-1)

echo "   HTTP Status: ${HTTP_CODE_1}"
echo "   Response: ${BODY_1}"

if [ "$HTTP_CODE_1" = "200" ] || [ "$HTTP_CODE_1" = "201" ]; then
  echo "   ✅ Webhook 1 registrado correctamente"
else
  echo "   ⚠  Webhook 1: respuesta inesperada (puede que ya exista)"
fi

# ── Webhook 2: appointment.created → Recordatorios ────────────
echo ""
echo "2. Registrando webhook: appointment.created"
echo "   URL destino: ${REMINDER_WEBHOOK_URL}"

RESPONSE_2=$(curl -s -w "\n%{http_code}" -X POST "${KAJA_BASE}/api/v1/webhooks/" \
  -H "Authorization: Bearer ${KAJA_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"event\": \"appointment.created\",
    \"url\": \"${REMINDER_WEBHOOK_URL}\"
  }")

HTTP_CODE_2=$(echo "$RESPONSE_2" | tail -n1)
BODY_2=$(echo "$RESPONSE_2" | head -n-1)

echo "   HTTP Status: ${HTTP_CODE_2}"
echo "   Response: ${BODY_2}"

if [ "$HTTP_CODE_2" = "200" ] || [ "$HTTP_CODE_2" = "201" ]; then
  echo "   ✅ Webhook 2 registrado correctamente"
else
  echo "   ⚠  Webhook 2: respuesta inesperada (puede que ya exista)"
fi

# ── Listar webhooks activos ────────────────────────────────────
echo ""
echo "3. Verificando webhooks activos en Kaja..."
curl -s -X GET "${KAJA_BASE}/api/v1/webhooks/" \
  -H "Authorization: Bearer ${KAJA_API_TOKEN}" | \
  python3 -c "import sys, json; data=json.load(sys.stdin); [print(f'   - {w[\"event\"]}: {w[\"url\"]} (id: {w[\"id\"]})') for w in (data.get('results', data) if isinstance(data, dict) else data)]" 2>/dev/null \
  || echo "   (No se pudo parsear el listado — revisa manualmente en Kaja)"

echo ""
echo "════════════════════════════════════════════════"
echo "  ✅ Registro de webhooks completado"
echo "  Próximo paso: importar los workflows JSON en n8n"
echo "  http://localhost:5678"
echo "════════════════════════════════════════════════"
echo ""
