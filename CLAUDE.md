# Asistente Clínico 24/7 — Especialista en Aparatos Auditivos

## Contexto del cliente
Doctora especialista en audiología y aparatos auditivos con pacientes en múltiples
estados del país. Su problema: el teléfono está saturado de dudas técnicas básicas
(cómo cambiar pila, limpiar filtro, qué significa un pitido) que le impiden enfocarse
en casos clínicos reales.

## Tres pilares del sistema (del plan de proyecto)

### Pilar 1 — Soporte Técnico Especializado (knowledge base)
El agente lee los manuales técnicos de los aparatos auditivos que distribuye la Dra.
y responde dudas operativas paso a paso, en lenguaje natural.
- Fuente de conocimiento: PDFs de manuales en `/knowledge-base/manuals/`
- Indexados en un vector store local (n8n in-memory o Qdrant vía Docker)
- El agente tiene una tool `buscar_manual` que hace similarity search sobre los manuales
- Ejemplos de consultas que debe resolver sin escalar:
  "¿Cómo cambio la pila de mi Phonak Audeo?" / "Mi aparato pita 3 veces, ¿qué significa?"
  "¿Cada cuánto limpio el filtro?" / "¿Cómo conecto el Bluetooth?"

### Pilar 2 — Triaje Inteligente (3 categorías)
El agente clasifica CADA interacción antes de responder:

  CATEGORÍA A — Duda técnica operativa:
    → Resolver directamente con el knowledge base (manuales)
    → No escalar

  CATEGORÍA B — Problema de mantenimiento:
    → Informar al paciente que se canalizará con el equipo de soporte
    → Notificar al equipo (mensaje WhatsApp al número de soporte de la Dra.)
    → Ofrecer agendar cita de revisión

  CATEGORÍA C — Señal de urgencia médica o audiológica:
    → Indicar al paciente que la Dra. lo contactará a la brevedad
    → Enviar alerta INMEDIATA a la Dra. vía WhatsApp (número de emergencias)
    → Registrar el caso

### Pilar 3 — Módulo de Gestión de Agenda (Kaja Uno)
El agente agenda, reagenda y cancela citas de forma autónoma.
Además, hay un workflow separado de recordatorios automáticos que se dispara
cuando se crea una cita (evento appointment.created de Kaja).

## Canales
- **WhatsApp**: implementado en este prototipo (vía Kaja Uno)
- **Voz (llamada telefónica)**: fuera de scope de este prototipo. Se implementará en
  Fase 2 con Twilio Voice + n8n. Documentar en README como "próximo paso".

## Stack técnico
- **n8n** (orquestador principal) — corre local vía Docker
- **Redis** (sesiones de chat TTL 12h, caché de contexto de negocio TTL 24h)
- **Gemini 2.5 Flash** (LLM principal — rápido y económico para WhatsApp)
- **Qdrant** (vector store para manuales técnicos) — corre vía Docker
- **Kaja Uno** (plataforma de citas + WhatsApp Business API)

## Estructura de archivos
```
asistente-clinico/
├── docker-compose.yml              # n8n + Redis + Qdrant
├── .env.example
├── knowledge-base/
│   ├── manuals/                    # PDFs de manuales de aparatos auditivos
│   │   ├── phonak-audeo-paradise.pdf
│   │   ├── oticon-more.pdf
│   │   └── README.md               # instrucciones para agregar más manuales
│   └── ingest.js                   # script para indexar PDFs en Qdrant
├── workflows/
│   ├── main_agent_workflow.json    # workflow principal (WhatsApp → Agente → Kaja)
│   └── reminders_workflow.json     # workflow de recordatorios automáticos
└── README.md
```

## API de Kaja Uno
- Base URL: `https://{tenant_slug}.kaja.uno`
- Auth: `Authorization: Bearer {api_token}`
- Rate limit: 60 req/min por tenant

### Endpoints relevantes
| Acción | Método y ruta |
|--------|--------------|
| Enviar WhatsApp | `POST /api/v1/messages/text` body: `{ to_phone, message }` |
| Branches | `GET /api/v1/branches/{branch_id}/` |
| Staff | `GET /api/v1/branches/{branch_id}/staff/` |
| Crear webhook | `POST /api/v1/webhooks/` body: `{ event, url }` |
| MCP booking | SSE en `/mcp/booking/sse` (bearer auth) |

### Eventos webhook de Kaja
| Evento | Cuándo |
|--------|--------|
| `whatsapp.client_message` | Mensaje entrante del paciente → dispara el agente |
| `appointment.created` | Cita agendada → dispara el workflow de recordatorios |

### MCP tools disponibles (booking)
`list_staff`, `search_products`, `get_available_slots`,
`search_customers`, `create_customer`, `create_appointment`

## Workflows en n8n

### Workflow 1: Agente Principal (main_agent_workflow.json)
```
WhatsApp Webhook (whatsapp.client_message)
  → Extraer tenant_id / from_phone / text
  → Redis EXPIRE sesión (TTL 12h)
  → Redis GET contexto negocio (cache 24h)
    → si miss: GET /api/v1/branches/{id}/ + /staff/ → formatear → Redis SET
  → AI Agent (Gemini 2.5 Flash)
      tools:
        · buscar_manual      ← Qdrant similarity search sobre manuales técnicos
        · MCP Kaja Booking   ← 6 tools de agenda
      memory: Redis Chat Memory (TTL 12h)
  → [según output del agente]
      · Categoría A: responder directamente al paciente
      · Categoría B: responder + notificar número de soporte de la Dra.
      · Categoría C: responder + alerta URGENTE a la Dra.
      · Agenda: responder con confirmación de cita
```

### Workflow 2: Recordatorios Automáticos (reminders_workflow.json)
```
Webhook (appointment.created de Kaja)
  → Extraer datos de la cita (paciente, fecha, hora, staff)
  → Calcular tiempo hasta la cita
  → Schedule node: esperar hasta 24h antes de la cita
  → HTTP Request: enviar recordatorio WhatsApp al paciente
      "Hola {nombre}, te recordamos tu cita mañana {fecha} a las {hora}
       con {staff} en {negocio}. ¿Confirmas tu asistencia? Responde SÍ o NO."
  → IF: si responde NO → ofrecer reagendar (dispara el agente principal)
```

## Credenciales en n8n (nombres exactos — no cambiar)
| Nombre | Tipo n8n | Para qué |
|--------|----------|---------|
| `Redis Local` | Redis | Sesiones y caché |
| `Google Gemini API` | Google PaLm Api | LLM principal |
| `Kaja API — Bearer Token` | Header Auth (`Authorization: Bearer ...`) | HTTP Requests a Kaja |
| `Kaja API — Bearer Auth` | HTTP Bearer Auth | MCP Client |
| `Qdrant Local` | Qdrant API | Vector store de manuales |

## Variables de entorno (.env)
```
# n8n
N8N_USER, N8N_PASSWORD, N8N_WEBHOOK_URL

# Redis
REDIS_PASSWORD

# Kaja Uno
KAJA_API_TOKEN, KAJA_TENANT_SLUG, KAJA_BRANCH_ID
KAJA_BUSINESS_NAME, KAJA_BUSINESS_ADDRESS

# Contactos de escalación (Pilar 2)
DOCTOR_PHONE=521XXXXXXXXXX        # número de la Dra. para alertas médicas urgentes
SUPPORT_PHONE=521XXXXXXXXXX       # número de soporte técnico (puede ser el mismo)

# Google Gemini
GOOGLE_GEMINI_API_KEY

# Qdrant (corre local vía Docker, no necesita key)
QDRANT_URL=http://qdrant:6333
QDRANT_COLLECTION=hearing_aid_manuals
```

## System prompt del agente (referencia)
```
Eres el asistente clínico virtual de la Dra. {nombre}, especialista en audiología
y aparatos auditivos, atendiendo pacientes en todo el país vía WhatsApp.

ANTES DE RESPONDER, clasifica cada mensaje en una de estas categorías:

[CATEGORÍA A — DUDA TÉCNICA]
Ejemplos: cambiar pila, limpiar filtro, ajustar volumen, conectar Bluetooth,
entender señales sonoras, guardar el aparato, cargadores.
Acción: usa la herramienta `buscar_manual` para encontrar la respuesta exacta
en los manuales técnicos. Responde paso a paso, en lenguaje sencillo.

[CATEGORÍA B — MANTENIMIENTO]
Ejemplos: aparato dañado físicamente, humedad, reparación, calibración,
solicitud de repuesto, garantía.
Acción: informa al paciente que tu equipo de soporte lo contactará pronto.
Notifica al equipo con la herramienta `notificar_soporte`.

[CATEGORÍA C — URGENCIA MÉDICA O AUDIOLÓGICA]
Ejemplos: dolor de oído con el aparato puesto, pérdida auditiva repentina,
infección, mareos, tinnitus severo súbito, aparato que causa daño.
Acción: indica al paciente que la Dra. lo contactará a la brevedad.
Usa la herramienta `alertar_doctor` de inmediato.
NO intentes resolver estos casos — escala siempre.

[AGENDA DE CITAS]
Si el paciente quiere agendar, reagendar o cancelar:
Usa las herramientas del MCP de agenda siguiendo el flujo:
servicio → preferencia de staff → fecha/hora → disponibilidad →
datos del paciente → confirmación → crear cita.

REGLAS GENERALES:
- Responde siempre en español, con tono cálido y profesional.
- Sé breve: estás en WhatsApp, no en un formulario.
- Nunca inventes disponibilidad — consulta siempre get_available_slots.
- Si no sabes algo, di que se lo harás llegar a la Dra.
```

## Escenarios de prueba requeridos
El prototipo debe pasar estos 5 casos:

| # | Mensaje del paciente | Comportamiento esperado |
|---|---------------------|------------------------|
| 1 | "¿Cómo cambio la pila de mi Phonak Audeo?" | Categoría A → buscar_manual → respuesta paso a paso |
| 2 | "Mi aparato se cayó al agua y ya no funciona" | Categoría B → informar + notificar soporte |
| 3 | "Tengo mucho dolor de oído desde que uso el aparato" | Categoría C → escalar + alertar a la Dra. |
| 4 | "Quiero agendar una cita para la próxima semana" | Pilar 3 → flujo de agenda completo |
| 5 | "Mándame foto de mi expediente" | Fuera de scope → respuesta amable de redirección |
