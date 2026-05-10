#!/bin/bash
# =============================================================
# setup.sh — Configuración inicial completa del Asistente Clínico
#
# Pasos que realiza:
#   1. Copia .env.example → .env (si no existe)
#   2. Levanta Docker (n8n + Redis + Qdrant)
#   3. Espera a que los servicios estén healthy
#   4. Instala dependencias de Node (knowledge-base/ingest.js)
#   5. Indexa los manuales en Qdrant
#
# Uso:
#   chmod +x scripts/setup.sh
#   ./scripts/setup.sh
# =============================================================

set -euo pipefail

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Asistente Clínico 24/7 — Setup inicial    ║"
echo "╚══════════════════════════════════════════════╝"

# ── 1. Crear .env si no existe ─────────────────────────────────
if [ ! -f ".env" ]; then
  cp .env.example .env
  echo ""
  echo "⚠  Se creó el archivo .env desde .env.example"
  echo "   Edita .env con tus credenciales reales antes de continuar."
  echo "   Abre .env y llena: KAJA_API_TOKEN, GOOGLE_GEMINI_API_KEY, etc."
  echo ""
  read -p "Presiona ENTER cuando hayas llenado el .env... "
fi

source .env

# ── 2. Levantar Docker ─────────────────────────────────────────
echo ""
echo "1. Levantando servicios Docker (n8n + Redis + Qdrant)..."
docker compose up -d

# ── 3. Esperar a que los servicios estén healthy ───────────────
echo ""
echo "2. Esperando a que los servicios estén listos..."

wait_for_healthy() {
  local container=$1
  local max_wait=60
  local waited=0
  while [ $waited -lt $max_wait ]; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "starting")
    if [ "$status" = "healthy" ]; then
      echo "   ✓ $container está healthy"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
    echo "   Esperando $container... ($waited/${max_wait}s)"
  done
  echo "   ⚠  $container no reportó healthy en ${max_wait}s — continuando de todas formas"
}

wait_for_healthy "clinico-redis"
wait_for_healthy "clinico-qdrant"
# n8n no tiene healthcheck configurado, esperamos unos segundos
sleep 5
echo "   ✓ clinico-n8n debería estar listo"

echo ""
echo "3. Estado de los servicios:"
docker compose ps

# ── 4. Verificar Qdrant ────────────────────────────────────────
echo ""
echo "4. Verificando Qdrant..."
if curl -sf http://localhost:6333/readyz > /dev/null 2>&1; then
  echo "   ✓ Qdrant responde en http://localhost:6333"
else
  echo "   ✗ Qdrant no responde — verifica los logs: docker compose logs qdrant"
  exit 1
fi

# ── 5. Instalar dependencias e indexar manuales ────────────────
echo ""
echo "5. Instalando dependencias de Node.js para ingest.js..."
(cd knowledge-base && npm install --silent)
echo "   ✓ Dependencias instaladas"

echo ""
echo "6. Indexando manuales en Qdrant..."
(cd knowledge-base && node ingest.js)

# ── 6. Verificación final ──────────────────────────────────────
echo ""
echo "7. Verificación final:"
echo "   Puntos indexados en Qdrant:"
curl -s -X POST http://localhost:6333/collections/hearing_aid_manuals/points/count \
  -H "Content-Type: application/json" \
  -d '{"exact": true}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'   → {d[\"result\"][\"count\"]} chunks en la colección hearing_aid_manuals')" 2>/dev/null \
  || curl -s http://localhost:6333/collections/hearing_aid_manuals | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'   → Colección: {d}')" 2>/dev/null \
  || echo "   → Verifica manualmente: curl http://localhost:6333/collections/hearing_aid_manuals"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✅ Setup completado                        ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  n8n UI:   http://localhost:5678             ║"
echo "║  Qdrant:   http://localhost:6333             ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Próximos pasos:                             ║"
echo "║  1. Abre n8n y crea las 5 credenciales       ║"
echo "║     (ver README.md → Configuración n8n)      ║"
echo "║  2. Importa los workflows JSON               ║"
echo "║  3. Registra los webhooks en Kaja:           ║"
echo "║     ./scripts/register_webhooks.sh           ║"
echo "║  4. Ejecuta el test:                         ║"
echo "║     ./test/run_scenarios.sh                  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
