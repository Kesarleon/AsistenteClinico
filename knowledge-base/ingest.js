/**
 * ingest.js — Indexa los manuales de aparatos auditivos en Qdrant
 *
 * Uso:
 *   cd knowledge-base
 *   npm install
 *   node ingest.js
 *
 * Variables de entorno requeridas (en ../.env):
 *   GOOGLE_GEMINI_API_KEY  — para generar embeddings con text-embedding-004
 *   QDRANT_URL             — URL de Qdrant (default: http://localhost:6333)
 *   QDRANT_COLLECTION      — nombre de la colección (default: hearing_aid_manuals)
 */

require("dotenv").config({ path: "../.env" });

const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");

// ── Configuración ──────────────────────────────────────────────────────────

const GEMINI_API_KEY = process.env.GOOGLE_GEMINI_API_KEY;
const QDRANT_URL = process.env.QDRANT_URL || "http://localhost:6333";
const COLLECTION = process.env.QDRANT_COLLECTION || "hearing_aid_manuals";
const MANUALS_DIR = path.join(__dirname, "manuals");

const CHUNK_SIZE_WORDS = 500;
const CHUNK_OVERLAP_WORDS = 50;
const EMBEDDING_MODEL = "text-embedding-004";
const EMBEDDING_DIMENSION = 768; // dimensión de text-embedding-004

// ── Helpers de HTTP ────────────────────────────────────────────────────────

function httpRequest(urlStr, options, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const lib = url.protocol === "https:" ? https : http;
    const req = lib.request(url, options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on("error", reject);
    if (body) req.write(typeof body === "string" ? body : JSON.stringify(body));
    req.end();
  });
}

// ── Generación de embeddings con Google text-embedding-004 ─────────────────

async function generateEmbedding(text) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${EMBEDDING_MODEL}:embedContent?key=${GEMINI_API_KEY}`;
  const body = {
    model: `models/${EMBEDDING_MODEL}`,
    content: { parts: [{ text }] },
    taskType: "RETRIEVAL_DOCUMENT",
  };

  const res = await httpRequest(
    url,
    { method: "POST", headers: { "Content-Type": "application/json" } },
    body
  );

  if (res.status !== 200) {
    throw new Error(`Embedding API error ${res.status}: ${JSON.stringify(res.body)}`);
  }

  return res.body.embedding.values;
}

// ── Chunking ───────────────────────────────────────────────────────────────

function chunkText(text, chunkWords = CHUNK_SIZE_WORDS, overlapWords = CHUNK_OVERLAP_WORDS) {
  const words = text.split(/\s+/).filter(Boolean);
  const chunks = [];
  let start = 0;

  while (start < words.length) {
    const end = Math.min(start + chunkWords, words.length);
    chunks.push(words.slice(start, end).join(" "));
    if (end === words.length) break;
    start += chunkWords - overlapWords;
  }

  return chunks;
}

// ── Lectura de archivos de la carpeta manuals/ ─────────────────────────────

function readManuals(dir) {
  const files = fs.readdirSync(dir).filter((f) => {
    const ext = path.extname(f).toLowerCase();
    return (ext === ".txt" || ext === ".pdf") && !f.startsWith(".");
  });

  const documents = [];
  for (const file of files) {
    const filePath = path.join(dir, file);
    if (path.extname(file).toLowerCase() === ".pdf") {
      console.log(`  ⚠  ${file}: soporte PDF requiere 'pdf-parse'. Usa .txt por ahora.`);
      continue;
    }
    const content = fs.readFileSync(filePath, "utf-8");
    documents.push({ filename: file, content });
    console.log(`  ✓ Leído: ${file} (${content.length} caracteres)`);
  }
  return documents;
}

// ── Operaciones en Qdrant ──────────────────────────────────────────────────

async function ensureCollection() {
  // Verificar si la colección existe
  const check = await httpRequest(`${QDRANT_URL}/collections/${COLLECTION}`, { method: "GET" });

  if (check.status === 200) {
    console.log(`  ✓ Colección '${COLLECTION}' ya existe.`);
    return;
  }

  // Crear la colección
  const res = await httpRequest(
    `${QDRANT_URL}/collections/${COLLECTION}`,
    { method: "PUT", headers: { "Content-Type": "application/json" } },
    {
      vectors: {
        size: EMBEDDING_DIMENSION,
        distance: "Cosine",
      },
    }
  );

  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`Error creando colección: ${JSON.stringify(res.body)}`);
  }
  console.log(`  ✓ Colección '${COLLECTION}' creada.`);
}

async function deleteByFilename(filename) {
  // Elimina puntos existentes con el mismo filename para re-indexar sin duplicados
  await httpRequest(
    `${QDRANT_URL}/collections/${COLLECTION}/points/delete`,
    { method: "POST", headers: { "Content-Type": "application/json" } },
    {
      filter: {
        must: [{ key: "filename", match: { value: filename } }],
      },
    }
  );
}

async function upsertPoints(points) {
  const res = await httpRequest(
    `${QDRANT_URL}/collections/${COLLECTION}/points`,
    { method: "PUT", headers: { "Content-Type": "application/json" } },
    { points }
  );

  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`Error indexando puntos: ${JSON.stringify(res.body)}`);
  }
}

// ── Función principal ──────────────────────────────────────────────────────

async function main() {
  console.log("\n════════════════════════════════════════════════");
  console.log("  Asistente Clínico — Ingestión de Manuales");
  console.log("════════════════════════════════════════════════\n");

  if (!GEMINI_API_KEY) {
    console.error("✗ Error: GOOGLE_GEMINI_API_KEY no está definido en el .env");
    process.exit(1);
  }

  // 1. Leer manuales
  console.log("1. Leyendo manuales...");
  const documents = readManuals(MANUALS_DIR);
  if (documents.length === 0) {
    console.error("✗ No se encontraron archivos .txt en knowledge-base/manuals/");
    process.exit(1);
  }

  // 2. Asegurar colección en Qdrant
  console.log("\n2. Verificando colección en Qdrant...");
  await ensureCollection();

  // 3. Procesar cada documento
  let totalChunks = 0;
  for (const doc of documents) {
    console.log(`\n3. Procesando: ${doc.filename}`);

    // Eliminar puntos anteriores del mismo archivo (re-ingestión limpia)
    console.log(`   → Eliminando puntos anteriores de '${doc.filename}'...`);
    await deleteByFilename(doc.filename);

    // Dividir en chunks
    const chunks = chunkText(doc.content);
    console.log(`   → ${chunks.length} chunks generados`);

    // Generar embeddings e indexar en lotes de 10
    const points = [];
    for (let i = 0; i < chunks.length; i++) {
      process.stdout.write(`   → Embedding chunk ${i + 1}/${chunks.length}...\r`);
      const vector = await generateEmbedding(chunks[i]);
      points.push({
        id: Math.floor(Math.random() * 1e15),
        vector,
        payload: {
          filename: doc.filename,
          chunk_index: i,
          text: chunks[i],
          source: `manual:${doc.filename}`,
        },
      });

      // Indexar en lotes de 10 para no saturar la API
      if (points.length === 10 || i === chunks.length - 1) {
        await upsertPoints([...points]);
        points.length = 0;
      }
    }

    console.log(`\n   ✓ ${chunks.length} chunks indexados para ${doc.filename}`);
    totalChunks += chunks.length;
  }

  // 4. Verificación final
  console.log("\n4. Verificando indexación...");
  const countRes = await httpRequest(
    `${QDRANT_URL}/collections/${COLLECTION}/points/count`,
    { method: "POST", headers: { "Content-Type": "application/json" } },
    { exact: true }
  );

  console.log(`\n════════════════════════════════════════════════`);
  console.log(`  ✅ Ingestión completada`);
  console.log(`  Documentos procesados : ${documents.length}`);
  console.log(`  Chunks indexados      : ${totalChunks}`);
  if (countRes.status === 200) {
    console.log(`  Puntos en Qdrant      : ${countRes.body.result?.count ?? "N/A"}`);
  }
  console.log(`  Colección             : ${COLLECTION}`);
  console.log(`  Qdrant URL            : ${QDRANT_URL}`);
  console.log(`════════════════════════════════════════════════\n`);
}

main().catch((err) => {
  console.error("\n✗ Error fatal:", err.message);
  process.exit(1);
});
