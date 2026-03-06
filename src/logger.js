import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const DATA_DIR = join(import.meta.dirname, '..', 'data', 'logs');

function getLogPath() {
  mkdirSync(DATA_DIR, { recursive: true });
  const date = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
  return join(DATA_DIR, `${date}.log`);
}

function timestamp() {
  return new Date().toLocaleTimeString('es-ES', {
    timeZone: 'Europe/Madrid',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function log(message) {
  const line = `${timestamp()} - ${message}`;
  console.log(line);
  appendFileSync(getLogPath(), line + '\n');
}

export function logSummary(stats) {
  const lines = [
    '',
    `=== RESUMEN BUSQUEDA API ===`,
    `Total inmuebles encontrados: ${stats.totalFound}`,
    `Particulares (agency=false): ${stats.particulares}`,
    `Nuevos (no duplicados): ${stats.newProperties}`,
    `Duplicados descartados: ${stats.duplicates}`,
    `Pendientes para procesar: ${stats.pendingToProcess}`,
    `Requests API usadas hoy: ${stats.requestsUsed}`,
    `============================`,
  ];
  for (const line of lines) log(line);
}
