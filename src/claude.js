/**
 * Claude API client — calls Anthropic SDK directly.
 * Requires ANTHROPIC_API_KEY in environment.
 */

import Anthropic from '@anthropic-ai/sdk';

const MODEL = 'claude-sonnet-4-5';
let _client = null;

function getClient() {
  if (!_client) {
    if (!process.env.ANTHROPIC_API_KEY) {
      throw new Error('ANTHROPIC_API_KEY no configurada en .env');
    }
    _client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  }
  return _client;
}

/**
 * Parse a BetterPlace email and extract property listings.
 * @param {string} text - innerText of the email (max 12k chars)
 * @returns {Promise<Array<{url, zone, price, portal, isParticular}>>}
 */
export async function parseEmail(text) {
  const truncated = text.slice(0, 12000);
  const msg = await getClient().messages.create({
    model: MODEL,
    max_tokens: 2048,
    messages: [{
      role: 'user',
      content: `Eres un parser de emails inmobiliarios. Analiza este email de BetterPlace (puede ser texto plano o HTML) y extrae los inmuebles de PARTICULARES.

El email puede tener dos formatos:

FORMATO TEXTO PLANO:
[Título/zona]
[Precio] € | [m²] | [habs]
Particular en [portal]
[Links: Valoración, Tarea, Informe de captación, Ficha del inmueble]

FORMATO HTML:
- Cada inmueble aparece como un bloque con título, precio, tipo de vendedor y links
- Los links pueden ser directos (idealista.com, fotocasa.es, pisos.com) o redirects de BetterPlace (click.betterplaceapp.com)
- Busca si dice "Particular" (no "Agencia") cerca de cada inmueble
- El link de "Ficha del inmueble" o el link al portal es la URL que necesitas

IMPORTANTE sobre los links:
- Si el link es directo al portal (idealista.com, fotocasa.es, pisos.com, habitaclia.com) → úsalo tal cual
- Si el link es un redirect de BetterPlace (click.betterplaceapp.com o similar) → úsalo también, es válido

Devuelve SOLO un JSON array con los inmuebles de PARTICULARES. Formato:
[
  {
    "url": "https://...",
    "zone": "Calle/zona del inmueble",
    "price": 350000,
    "portal": "idealista",
    "isParticular": true
  }
]

Si no hay particulares devuelve [].
Devuelve SOLO el JSON, sin markdown, sin explicaciones.

EMAIL:
${truncated}`,
    }],
  });

  const content = msg.content[0].text.trim();
  try {
    return JSON.parse(content);
  } catch {
    const match = content.match(/\[[\s\S]*\]/);
    if (match) return JSON.parse(match[0]);
    return [];
  }
}

/**
 * Extract phone from property page DOM text.
 * @param {string} domText - cleaned innerText of the property page (max 14k chars)
 * @param {string} portal - 'idealista' | 'fotocasa' | 'pisos.com'
 * @returns {Promise<{found: boolean, phone?: string, action?: string, noPhone?: boolean}>}
 */
export async function extractPhone(domText, portal, { afterClick = false } = {}) {
  const truncated = domText.slice(0, 14000);

  // First pass (before clicking): always click "Ver teléfono" to reveal the owner's phone.
  // Any phone visible before clicking belongs to the logged-in user, NOT the owner.
  if (!afterClick) {
    return { found: false, action: 'click', hint: 'Ver teléfono' };
  }

  // Fast regex pass — avoid Claude call if phone is already visible
  const phoneRegex = /\b(6\d[\d\s]{7,10}|7\d[\d\s]{7,10})\b/g;
  const matches = domText.match(phoneRegex);
  if (matches) {
    for (const m of matches) {
      const cleaned = m.replace(/\s/g, '');
      if (cleaned.length >= 9 && cleaned.length <= 12 && /^[67]/.test(cleaned)) {
        return { found: true, phone: cleaned };
      }
    }
  }

  const msg = await getClient().messages.create({
    model: MODEL,
    max_tokens: 256,
    messages: [{
      role: 'user',
      content: `Eres un extractor de teléfonos de fichas inmobiliarias en ${portal}.

Analiza este texto de la página y responde con JSON:

IMPORTANTE: En idealista, después de pulsar "Ver teléfono" aparece una sección "Teléfonos de contacto" con el número del PROPIETARIO. Ese es el que quieres.
NO extraigas teléfonos que aparezcan en zonas de perfil del usuario logueado o en la cabecera.

Si encuentras el teléfono del PROPIETARIO (sección de contacto, suele empezar por 6 o 7, tiene 9 dígitos):
{"found": true, "phone": "612345678"}

Si necesitas pulsar un botón para revelarlo ("Ver teléfono"):
{"found": false, "action": "click", "hint": "Ver teléfono"}

Si no hay teléfono ni botón:
{"found": false, "noPhone": true}

Devuelve SOLO el JSON, sin markdown.

TEXTO DE LA PÁGINA:
${truncated}`,
    }],
  });

  const content = msg.content[0].text.trim();
  try {
    return JSON.parse(content);
  } catch {
    const match = content.match(/\{[\s\S]*\}/);
    if (match) return JSON.parse(match[0]);
    return { found: false, noPhone: true };
  }
}

/**
 * Extract property details from DOM text.
 * @param {string} domText - cleaned innerText of the property page
 * @param {string} portal - 'idealista' | 'fotocasa' | 'pisos.com' etc.
 * @returns {Promise<{zone, price, priceText, propertyType, operation, sqm, rooms, bathrooms, floor, features, ownerName, description}>}
 */
export async function extractDetails(domText, portal) {
  const truncated = domText.slice(0, 14000);
  const msg = await getClient().messages.create({
    model: MODEL,
    max_tokens: 512,
    messages: [{
      role: 'user',
      content: `Extrae los datos de esta ficha de inmueble de ${portal}. Devuelve SOLO JSON:

{
  "zone": "dirección o zona (ej: Calle Suertes de la Villa 2, El Cañaveral, Madrid)",
  "price": 350000,
  "priceText": "350.000 €",
  "propertyType": "piso",
  "operation": "venta",
  "sqm": 113,
  "rooms": 3,
  "bathrooms": 2,
  "floor": "8ª planta",
  "features": ["ascensor", "garaje", "terraza", "aire acondicionado"],
  "ownerName": "Juan Carlos",
  "description": "resumen de 1 frase de lo más destacado del inmueble"
}

Reglas:
- "zone": dirección lo más completa posible (calle + barrio + ciudad)
- "price": número sin formatear. Si es alquiler, precio mensual
- "operation": "venta" o "alquiler"
- "propertyType": piso, casa, ático, dúplex, estudio, chalet, local, etc.
- "ownerName": nombre del particular si aparece (no el del usuario logueado)
- "features": array con características destacadas (máx 6)
- "description": 1 frase corta y concreta sobre lo más atractivo
- Si un campo no está disponible, usa null
- Devuelve SOLO el JSON, sin markdown

TEXTO DE LA PÁGINA:
${truncated}`,
    }],
  });

  const content = msg.content[0].text.trim();
  try {
    return JSON.parse(content);
  } catch {
    const match = content.match(/\{[\s\S]*\}/);
    if (match) return JSON.parse(match[0]);
    return {};
  }
}

const DEFAULT_TEMPLATE = `Hola{{nombre}}, soy {{agente}}, {{cargo}}.

He visto tu {{tipo}} en {{zona}} que tienes en {{portal}}{{precio}}. {{detalle}}

No te escribo para convencerte de trabajar con una agencia 🙂

Solo comentarte algo: vender por tu cuenta es totalmente posible, pero vender bien, en menos tiempo y sin tener que bajar el precio es lo complicado.

Si algun dia te apetece ver como lo trabajariamos y luego decides si te aporta valor o no, llamame y lo vemos sin ningun compromiso.`;

/**
 * Build a personalized WhatsApp message using Claude.
 * @param {Object} contact - {name, zone, portal, price, propertyType, detail, agentName, agentCompany, agentRole, template, vars}
 * @returns {Promise<string>}
 */
export async function buildMessage(contact) {
  const template = contact.template || DEFAULT_TEMPLATE;
  const vars = contact.vars || { price: true, zone: true, detail: true };
  const agentName = contact.agentName || 'tu agente inmobiliario';
  const agentCompany = contact.agentCompany || '';
  const agentRole = contact.agentRole || 'agente inmobiliario profesional';

  const dataLines = [
    `- Nombre vendedor: ${contact.name || 'desconocido'}`,
    `- Nombre agente: ${agentName}`,
    `- Empresa: ${agentCompany || 'no especificada'}`,
    `- Cargo: ${agentRole}`,
    `- Portal: ${contact.portal || 'el portal'}`,
    `- Tipo de inmueble: ${contact.propertyType || 'vivienda'}`,
    `- Operacion: ${contact.operation || 'venta'}`,
  ];
  if (vars.zone !== false) dataLines.push(`- Zona: ${contact.zone || 'desconocida'}`);
  if (vars.price !== false) dataLines.push(`- Precio: ${contact.priceText || (contact.price ? Number(contact.price).toLocaleString('es-ES') + ' €' : 'desconocido')}`);
  if (contact.sqm) dataLines.push(`- Metros: ${contact.sqm} m2`);
  if (contact.rooms) dataLines.push(`- Habitaciones: ${contact.rooms}`);
  if (contact.floor) dataLines.push(`- Planta: ${contact.floor}`);
  if (contact.features?.length) dataLines.push(`- Caracteristicas: ${contact.features.join(', ')}`);
  if (vars.detail !== false && contact.detail) dataLines.push(`- Detalle de la ficha: ${contact.detail}`);

  const instructions = [
    '- Si hay nombre vendedor: "Hola [nombre]," — si no: "Hola,"',
    '- Reemplaza {{agente}} con el nombre del agente, {{cargo}} con su cargo, {{empresa}} con su empresa',
    '- Reemplaza {{tipo}}, {{zona}}, {{portal}} con los datos reales',
    '- Manten el tono profesional pero cercano',
    '- Devuelve SOLO el mensaje final, sin comillas, sin explicaciones',
  ];
  if (vars.price !== false) instructions.push('- Si hay precio: incluye "por [precio]" — si no: omite {{precio}}');
  else instructions.push('- NO menciones el precio, elimina {{precio}} de la plantilla');
  if (vars.zone !== false) instructions.push('- Incluye la zona/direccion del inmueble');
  else instructions.push('- NO menciones la zona, usa algo generico');
  if (vars.detail !== false) instructions.push('- {{detalle}}: UNA frase natural (max 20 palabras) mencionando algo concreto y positivo del inmueble basado en los datos');
  else instructions.push('- NO añadas detalle extra, elimina {{detalle}}');

  const msg = await getClient().messages.create({
    model: MODEL,
    max_tokens: 512,
    messages: [{
      role: 'user',
      content: `Eres un agente inmobiliario profesional.
Escribe un WhatsApp para captar a un particular que vende su piso. Usa esta plantilla base pero personalizala:

---
${template}
---

Datos del inmueble:
${dataLines.join('\n')}

Instrucciones:
${instructions.join('\n')}`,
    }],
  });

  return msg.content[0].text.trim();
}
