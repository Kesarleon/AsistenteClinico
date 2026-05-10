# Manuales de Aparatos Auditivos

Esta carpeta contiene los manuales técnicos que el agente usa para responder
dudas operativas de los pacientes (Pilar 1).

## Manuales incluidos

| Archivo | Modelo | Fabricante |
|---------|--------|------------|
| `phonak-audeo-paradise.txt` | Phonak Audeo Paradise P-R | Phonak AG |
| `oticon-more.txt` | Oticon More miniRITE R | Oticon A/S |

## Cómo agregar un nuevo manual

1. Coloca el archivo en esta carpeta (`knowledge-base/manuals/`).
   - Formatos soportados: `.txt`, `.pdf`
   - Nombre recomendado: `marca-modelo.txt` (minúsculas, sin espacios)

2. Ejecuta el script de ingestión para indexar el nuevo manual en Qdrant:
   ```bash
   cd knowledge-base
   node ingest.js
   ```
   El script indexa TODOS los archivos de la carpeta (no solo el nuevo).
   Si un documento ya existe en Qdrant con el mismo nombre de archivo,
   el script lo reemplaza automáticamente.

3. Verifica que quedó indexado:
   ```bash
   curl http://localhost:6333/collections/hearing_aid_manuals/points/count
   ```

## Estructura de los manuales (recomendada)

Para que el agente pueda responder con precisión, cada manual debe incluir:

- **Cambio/carga de batería o pila**: pasos detallados
- **Señales sonoras**: tabla de pitidos y su significado
- **Conectividad Bluetooth**: pasos de emparejamiento y solución de problemas
- **Limpieza y mantenimiento**: frecuencia y pasos
- **Reemplazo del filtro de cera**: pasos
- **Almacenamiento correcto**: condiciones
- **Solución de problemas comunes**: síntoma → causa → solución

## Notas técnicas

- El script `ingest.js` divide cada manual en chunks de ~500 palabras
  con 50 palabras de solapamiento para preservar contexto entre chunks.
- Los embeddings se generan con `text-embedding-004` de Google.
- La colección en Qdrant se llama `hearing_aid_manuals` (configurado en `.env`).
