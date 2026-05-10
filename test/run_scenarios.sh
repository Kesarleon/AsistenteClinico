#!/bin/bash
# =============================================================
# run_scenarios.sh — 5 escenarios de prueba obligatorios
# Asistente Clínico 24/7
#
# Uso:
#   chmod +x test/run_scenarios.sh
#   ./test/run_scenarios.sh
#
# Requiere:
#   - .env con N8N_WEBHOOK_URL configurado
#   - n8n corriendo con el workflow importado y activo
#   - Qdrant con los manuales indexados
# =============================================================

set -euo pipefail

# Cargar variables de entorno
if [ ! -f ".env" ]; then
  echo "✗ Error: no se encontró .env — ejecuta desde la raíz del proyecto"
  exit 1
fi
source .env

BASE_URL="${N8N_WEBHOOK_URL}/webhook/booking-agent"
TENANT_ID="tn_test001"
FROM_PHONE="5215512345678"
PASS=0
FAIL=0

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Asistente Clínico — Test de 5 Escenarios Obligatorios ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Webhook URL : ${BASE_URL}"
echo "  Tenant ID   : ${TENANT_ID}"
echo "  From Phone  : ${FROM_PHONE}"
echo ""

# ── Función para enviar un escenario ──────────────────────────

send_msg() {
  local scenario=$1
  local msg=$2
  local expected_cat=$3
  local description=$4

  echo "══════════════════════════════════════════════════════════"
  echo "ESCENARIO ${scenario}: ${description}"
  echo "  Mensaje    : \"${msg}\""
  echo "  Categoría  : ${expected_cat}"
  echo "──────────────────────────────────────────────────────────"

  local response
  local http_code

  # Enviar mensaje simulando payload de Kaja whatsapp.client_message
  response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}" \
    -H "Content-Type: application/json" \
    -d "{
      \"event\": \"whatsapp.client_message\",
      \"tenant_id\": \"${TENANT_ID}\",
      \"sender_type\": \"client\",
      \"message\": {
        \"id\": \"wamid.test00${scenario}\",
        \"from\": \"${FROM_PHONE}\",
        \"type\": \"text\",
        \"text\": { \"body\": \"${msg}\" }
      }
    }" 2>&1)

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | head -n-1)

  echo "  HTTP Status : ${http_code}"
  echo "  Response    : ${body}"

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    echo "  ✅ Webhook aceptado correctamente"
    PASS=$((PASS + 1))
  else
    echo "  ❌ Error en la respuesta del webhook"
    FAIL=$((FAIL + 1))
  fi

  echo ""
  echo "  ⏳ Esperando 5s para que el agente procese..."
  sleep 5
  echo ""
}

# ── Verificar que n8n está activo ─────────────────────────────

echo "Verificando conectividad con n8n..."
if ! curl -sf "${N8N_WEBHOOK_URL}/healthz" > /dev/null 2>&1 && \
   ! curl -sf "http://localhost:5678/healthz" > /dev/null 2>&1; then
  echo "⚠  n8n no responde en ${N8N_WEBHOOK_URL}"
  echo "   Asegúrate de que n8n esté corriendo: docker compose up -d"
  echo "   Y que el workflow esté importado y activo."
  echo ""
  echo "   Continuando de todas formas para registrar el intento..."
fi

# ── Ejecutar los 5 escenarios ─────────────────────────────────

send_msg 1 \
  "¿Cómo cambio la pila de mi Phonak Audeo?" \
  "[CAT-A] Duda técnica" \
  "Duda técnica — buscar_manual → respuesta paso a paso"

send_msg 2 \
  "Mi aparato se cayó al agua y ya no funciona" \
  "[CAT-B] Mantenimiento" \
  "Mantenimiento — informar + notificar soporte"

send_msg 3 \
  "Tengo mucho dolor de oído desde que uso el aparato" \
  "[CAT-C] Urgencia médica" \
  "Urgencia médica — escalar + alertar a la Dra."

send_msg 4 \
  "Quiero agendar una cita para la próxima semana" \
  "[CAT-AGENDA] Gestión de citas" \
  "Gestión de citas — flujo completo con MCP Kaja"

send_msg 5 \
  "Mándame foto de mi expediente" \
  "[CAT-OOS] Fuera de scope" \
  "Fuera de scope — respuesta amable de redirección"

# ── Resumen ───────────────────────────────────────────────────

echo "══════════════════════════════════════════════════════════"
echo ""
echo "  RESUMEN DE RESULTADOS"
echo ""
echo "  ✅ Webhooks aceptados : ${PASS}/5"
echo "  ❌ Errores            : ${FAIL}/5"
echo ""
echo "  Para verificar el comportamiento real del agente:"
echo "  → Revisa las ejecuciones en n8n: http://localhost:5678"
echo "    (Menu → Executions)"
echo ""
echo "  Criterios de aprobación por escenario:"
echo "  ┌─────┬─────────────────────────────────────────────────────┐"
echo "  │  1  │ ✓ Cat A identificada  ✓ buscar_manual invocada      │"
echo "  │     │ ✓ Respuesta paso a paso enviada al paciente         │"
echo "  ├─────┼─────────────────────────────────────────────────────┤"
echo "  │  2  │ ✓ Cat B identificada  ✓ Paciente informado          │"
echo "  │     │ ✓ WhatsApp a SUPPORT_PHONE enviado                  │"
echo "  ├─────┼─────────────────────────────────────────────────────┤"
echo "  │  3  │ ✓ Cat C identificada  ✓ alertar_doctor invocada     │"
echo "  │     │ ✓ WhatsApp URGENTE a DOCTOR_PHONE enviado           │"
echo "  ├─────┼─────────────────────────────────────────────────────┤"
echo "  │  4  │ ✓ MCP Kaja invocado   ✓ Slots consultados           │"
echo "  │     │ ✓ Flujo de agenda completado                        │"
echo "  ├─────┼─────────────────────────────────────────────────────┤"
echo "  │  5  │ ✓ Fuera de scope detectado                          │"
echo "  │     │ ✓ Respuesta amable sin inventar información         │"
echo "  └─────┴─────────────────────────────────────────────────────┘"
echo ""
echo "  Para ver logs: docker compose logs n8n --tail=100"
echo ""

# ── Verificar Redis y Qdrant post-test ────────────────────────

echo "══════════════════════════════════════════════════════════"
echo "  Verificación de estado post-test:"
echo ""

echo "  → Sesiones en Redis:"
docker exec clinico-redis redis-cli -a "${REDIS_PASSWORD}" KEYS "chat_session:*" 2>/dev/null \
  | sed 's/^/    /' || echo "    (Redis no accesible)"

echo ""
echo "  → Historial de chat de la sesión de prueba:"
docker exec clinico-redis redis-cli -a "${REDIS_PASSWORD}" \
  GET "chat_session:${TENANT_ID}:${FROM_PHONE}" 2>/dev/null \
  | head -c 500 || echo "    (Sin historial en Redis — normal si Redis Chat Memory usa otro formato)"

echo ""
echo "  → Puntos indexados en Qdrant:"
curl -s -X POST http://localhost:6333/collections/hearing_aid_manuals/points/count \
  -H "Content-Type: application/json" \
  -d '{"exact": true}' 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    {d[\"result\"][\"count\"]} chunks en hearing_aid_manuals')" 2>/dev/null \
  || echo "    (Qdrant no accesible en localhost:6333)"

echo ""
echo "══════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 Todos los webhooks fueron aceptados."
  echo "     Verifica el comportamiento del agente en n8n → Executions"
  exit 0
else
  echo "  ⚠  ${FAIL} escenarios fallaron en el envío del webhook."
  echo "     Revisa que n8n esté corriendo y el workflow esté activo."
  exit 1
fi
