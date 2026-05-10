# Asistente Clínico 24/7 — Aparatos Auditivos

Agente de WhatsApp para clínicas de audiología que resuelve dudas técnicas, clasifica urgencias y gestiona citas de forma autónoma, liberando a la Dra. del volumen de consultas operativas.

## Tres pilares

| Pilar | Descripción |
|-------|-------------|
| **1 — Soporte Técnico** | Lee manuales de aparatos auditivos (Phonak, Oticon) y responde dudas paso a paso |
| **2 — Triaje Inteligente** | Clasifica cada mensaje en Cat A (técnica), B (mantenimiento) o C (urgencia médica) y escala cuando corresponde |
| **3 — Gestión de Agenda** | Agenda, reagenda y cancela citas vía Kaja Uno MCP |

## Stack

- **n8n** — orquestador de workflows (Docker)
- **Redis** — sesiones de chat (TTL 12h) + caché de contexto (TTL 24h)
- **Qdrant** — vector store de manuales técnicos (Docker)
- **Gemini 2.5 Flash** — LLM principal
- **Kaja Uno** — WhatsApp Business API + plataforma de citas

## Estructura del proyecto

```
asistente-clinico/
├── docker-compose.yml              # n8n + Redis + Qdrant
├── .env.example                    # Variables de entorno (copia como .env)
├── .gitignore
├── CLAUDE.md                       # Contexto completo del sistema
│
├── knowledge-base/
│   ├── manuals/
│   │   ├── phonak-audeo-paradise.txt   # Manual Phonak (carga, Bluetooth, pitidos, limpieza)
│   │   ├── oticon-more.txt             # Manual Oticon (carga, volumen, conectividad)
│   │   └── README.md                   # Instrucciones para agregar manuales
│   ├── ingest.js                   # Indexa manuales en Qdrant
│   └── package.json
│
├── workflows/
│   ├── main_agent_workflow.json    # Workflow principal (WhatsApp → Agente → Kaja)
│   └── reminders_workflow.json     # Recordatorios automáticos de citas
│
├── scripts/
│   ├── setup.sh                    # Setup inicial completo (Docker + ingestión)
│   └── register_webhooks.sh        # Registra webhooks en Kaja Uno
│
└── test/
    └── run_scenarios.sh            # Test de los 5 escenarios obligatorios
```

---

## Inicio rápido

### 1. Clonar y configurar

```bash
git clone <repo>
cd asistente-clinico
cp .env.example .env
# Edita .env con tus credenciales reales
```

### 2. Levantar todo con el script de setup

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

El script realiza: Docker up → esperar healthy → instalar Node deps → indexar manuales.

### 3. Verificar los servicios

```bash
docker compose ps
# Deberías ver 3 servicios: clinico-n8n, clinico-redis, clinico-qdrant

# Verificar Qdrant
curl http://localhost:6333/collections/hearing_aid_manuals

# Ver logs de n8n
docker compose logs n8n --tail=50
```

---

## Configuración de n8n

Accede a n8n en `http://localhost:5678` y completa estos pasos **antes** de importar los workflows.

### Credenciales requeridas (nombres exactos)

Crea cada credencial en **Settings → Credentials → Add credential**:

| Nombre exacto | Tipo en n8n | Valor |
|---------------|-------------|-------|
| `Redis Local` | Redis | Host: `redis`, Port: `6379`, Password: `$REDIS_PASSWORD` |
| `Google Gemini API` | Google PaLm Api | API Key: `$GOOGLE_GEMINI_API_KEY` |
| `Kaja API — Bearer Token` | Header Auth | Name: `Authorization`, Value: `Bearer $KAJA_API_TOKEN` |
| `Kaja API — Bearer Auth` | HTTP Bearer Auth | Token: `$KAJA_API_TOKEN` |
| `Qdrant Local` | Qdrant API | URL: `http://qdrant:6333`, API Key: *(dejar vacío)* |

> Los nombres deben coincidir **exactamente** (mayúsculas, guiones, espacios) porque el workflow JSON los referencia por nombre.

### Importar workflows

1. En n8n, ve a **Workflows → Import from file**
2. Importa `workflows/main_agent_workflow.json`
3. Importa `workflows/reminders_workflow.json`
4. Activa ambos workflows (toggle en la esquina superior derecha)

### Configuración de la tool `buscar_manual` (Pilar 1)

La tool `buscar_manual` está configurada en el workflow principal como un nodo de tipo **Tool Vector Store** conectado al AI Agent:

- **Nodo**: `buscar_manual (Qdrant)` → tipo `@n8n/n8n-nodes-langchain.toolVectorStore`
- **Credencial**: `Qdrant Local`
- **Colección**: `hearing_aid_manuals` (variable `QDRANT_COLLECTION` del entorno)
- **Top K**: 4 fragmentos más relevantes por consulta
- **Conexión**: sale como `ai_tool` hacia el nodo `AI Agent (Gemini 2.5 Flash)`

Si necesitas ajustar la colección o el número de resultados, edita el nodo directamente en la UI de n8n.

---

## Indexar manuales (Pilar 1)

```bash
# Primera vez (o cuando agregues manuales nuevos)
cd knowledge-base
npm install
node ingest.js

# Verificar que quedaron indexados
curl http://localhost:6333/collections/hearing_aid_manuals/points/count
```

Para agregar un nuevo manual, coloca el archivo `.txt` en `knowledge-base/manuals/` y vuelve a ejecutar `node ingest.js`. El script reemplaza los puntos anteriores del mismo archivo (no duplica).

---

## Registrar webhooks en Kaja

```bash
chmod +x scripts/register_webhooks.sh
./scripts/register_webhooks.sh
```

O manualmente:

```bash
source .env

# Webhook 1: mensajes WhatsApp → agente principal
curl -X POST "https://${KAJA_TENANT_SLUG}.kaja.uno/api/v1/webhooks/" \
  -H "Authorization: Bearer ${KAJA_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"event\": \"whatsapp.client_message\", \"url\": \"${N8N_WEBHOOK_URL}/webhook/booking-agent\"}"

# Webhook 2: cita creada → recordatorios automáticos
curl -X POST "https://${KAJA_TENANT_SLUG}.kaja.uno/api/v1/webhooks/" \
  -H "Authorization: Bearer ${KAJA_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"event\": \"appointment.created\", \"url\": \"${N8N_WEBHOOK_URL}/webhook/appointment-reminder\"}"
```

---

## Lógica de triaje (Pilar 2)

El agente evalúa cada mensaje y agrega marcadores internos a su respuesta:

| Marcador | Categoría | Acción |
|----------|-----------|--------|
| `[CAT-A]` | Duda técnica | Responde directamente usando `buscar_manual` |
| `[CAT-B][ESCALAR-SOPORTE]` | Mantenimiento | Responde + WhatsApp a `SUPPORT_PHONE` |
| `[CAT-C][ESCALAR-DOCTOR]` | Urgencia médica | Responde + WhatsApp urgente a `DOCTOR_PHONE` |
| `[CAT-AGENDA]` | Citas | Flujo completo con MCP Kaja |
| `[CAT-OOS]` | Fuera de scope | Respuesta amable de redirección |

Los marcadores se eliminan antes de enviar la respuesta al paciente (nodo "Limpiar output del agente").

### Mensajes de escalación

**Categoría B — Soporte técnico:**
```
🔧 SOPORTE REQUERIDO
Paciente: {from_phone}
Mensaje: {texto_original}
Fecha: {timestamp}
```

**Categoría C — Urgencia médica:**
```
🚨 URGENCIA MÉDICA
Paciente: {from_phone}
Mensaje: {texto_original}
Fecha: {timestamp}
Contactar de inmediato.
```

---

## Recordatorios automáticos (Pilar 3)

Cuando Kaja crea una cita (`appointment.created`), el workflow de recordatorios:

1. Extrae datos de la cita (paciente, fecha, hora, staff)
2. Calcula el tiempo hasta 24h antes de la cita
3. Espera ese tiempo (nodo Wait)
4. Envía WhatsApp al paciente:
   > "Hola {nombre} 👋 Te recordamos tu cita mañana {fecha} a las {hora} con {staff}. ¿Confirmas tu asistencia? Responde **SÍ** para confirmar ✅ o **NO** para reagendar 📅"
5. Si el paciente responde NO → dispara el agente principal para reagendar

---

## Prueba de los 5 escenarios obligatorios

```bash
chmod +x test/run_scenarios.sh
./test/run_scenarios.sh
```

| # | Mensaje | Comportamiento esperado |
|---|---------|------------------------|
| 1 | "¿Cómo cambio la pila de mi Phonak Audeo?" | Cat A → `buscar_manual` → respuesta paso a paso |
| 2 | "Mi aparato se cayó al agua y ya no funciona" | Cat B → informar + WhatsApp a soporte |
| 3 | "Tengo mucho dolor de oído desde que uso el aparato" | Cat C → escalar + alerta urgente a la Dra. |
| 4 | "Quiero agendar una cita para la próxima semana" | Pilar 3 → flujo MCP Kaja completo |
| 5 | "Mándame foto de mi expediente" | Fuera de scope → redirección amable |

Revisa los resultados en **n8n → Executions** para confirmar que cada nodo procesó correctamente.

---

## Validación del sistema (Tarea 8)

```bash
# Ver logs de n8n
docker compose logs n8n --tail=100

# Ver sesiones activas en Redis
docker exec -it clinico-redis redis-cli -a $REDIS_PASSWORD KEYS "*"

# Ver historial de chat de la sesión de prueba
docker exec -it clinico-redis redis-cli -a $REDIS_PASSWORD \
  GET "chat_session:tn_test001:5215512345678"

# Ver contexto del negocio cacheado
docker exec -it clinico-redis redis-cli -a $REDIS_PASSWORD \
  GET "booking_context:tn_test001"

# Ver cantidad de documentos indexados en Qdrant
curl -s -X POST http://localhost:6333/collections/hearing_aid_manuals/points/count \
  -H "Content-Type: application/json" \
  -d '{"exact": true}'
```

---

## Canal de Voz (Fase 2 — Próximo paso)

El canal de voz (llamadas telefónicas) no está incluido en este prototipo.
La implementación futura usará:

- **Twilio Voice** para recibir y hacer llamadas
- **n8n + Twilio node** para integrar con el mismo agente ya construido
- **Text-to-Speech** (Google TTS o ElevenLabs) para respuestas de voz naturales
- El mismo sistema de triaje (Pilar 2) y knowledge base (Pilar 1) ya construidos

Para activar este canal se necesita:

1. Cuenta Twilio con número telefónico activo (con capacidad de voz)
2. Credencial Twilio en n8n (`Account SID` + `Auth Token`)
3. Configurar el número Twilio para apuntar al webhook de n8n (`voice_agent_workflow.json`)
4. Workflow adicional: `workflows/voice_agent_workflow.json`

El número de teléfono de la Dra. puede redirigirse a Twilio para que el agente de voz atienda las llamadas antes de escalar a la Dra. si es necesario.

---

## Troubleshooting

**n8n no levanta:**
```bash
docker compose logs n8n
# Verifica que los puertos 5678 no estén en uso
```

**Qdrant no indexa:**
```bash
# Verifica que GOOGLE_GEMINI_API_KEY está en .env
curl http://localhost:6333/readyz
```

**El agente no responde en WhatsApp:**
- Verifica que el webhook esté activo en Kaja
- Verifica que el workflow en n8n esté activo (no en modo borrador)
- Revisa n8n → Executions para ver el error exacto

**Redis Chat Memory no funciona:**
- Verifica la credencial `Redis Local` en n8n (host debe ser `redis`, no `localhost`)
- Dentro de Docker, los servicios se llaman por su nombre de servicio

---

## Variables de entorno

Ver `.env.example` para la lista completa con descripción de cada variable.
