import Anthropic from '@anthropic-ai/sdk';
import { createClient } from '@supabase/supabase-js';

const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

export default async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405 });
  }

  // Auth: verify Supabase JWT
  const authHeader = req.headers.get('authorization') || '';
  const token = authHeader.replace('Bearer ', '').trim();
  if (!token) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
  }

  const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: 'Invalid token' }), { status: 401 });
  }

  // Check active subscription
  const { data: hasSub } = await supabase.rpc('has_active_subscription', { uid: user.id });
  if (!hasSub) {
    return new Response(JSON.stringify({ error: 'No active subscription' }), { status: 403 });
  }

  // Parse request
  let body;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }), { status: 400 });
  }

  const { action, payload } = body;

  try {
    let result;

    if (action === 'parse_email') {
      result = await parseEmail(payload.text);
    } else if (action === 'extract_phone') {
      result = await extractPhone(payload.domText, payload.portal, payload.afterClick);
    } else if (action === 'extract_details') {
      result = await extractDetails(payload.domText, payload.portal);
    } else if (action === 'build_message') {
      result = await buildMessage(payload.contact);
    } else {
      return new Response(JSON.stringify({ error: `Unknown action: ${action}` }), { status: 400 });
    }

    return new Response(JSON.stringify({ ok: true, result }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error(`claude-proxy error [${action}]:`, err.message);
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
};

export const config = { path: '/api/claude' };

// ── Claude functions ──────────────────────────────────────────────────────────

const MODEL = 'claude-sonnet-4-5';

async function parseEmail(text) {
  const truncated = text.slice(0, 12000);
  const msg = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 1024,
    messages: [{
      role: 'user',
      content: `Eres un parser de emails inmobiliarios. Analiza este email de BetterPlace y extrae los inmuebles.

Cada bloque tiene formato:
[Título/zona]
[Precio] € | [m²] | [habs]
Particular en [portal]  ← o "Agencia en ..." si es agencia
[Links: Valoración, Tarea, Informe de captación, Ficha del inmueble]

Devuelve SOLO un JSON array con los inmuebles de PARTICULARES (ignora agencias). Formato:
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

async function extractPhone(domText, portal, afterClick = false) {
  const truncated = domText.slice(0, 14000);

  // First pass (before clicking): always click "Ver teléfono" to reveal the owner's phone.
  // Any phone visible before clicking belongs to the logged-in user, NOT the owner.
  if (!afterClick) {
    return { found: false, action: 'click', hint: 'Ver teléfono' };
  }

  // After click: try regex first to find the revealed phone
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

  const msg = await anthropic.messages.create({
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

async function extractDetails(domText, portal) {
  const truncated = domText.slice(0, 14000);
  const msg = await anthropic.messages.create({
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

async function buildMessage(contact) {
  const template = contact.template || DEFAULT_TEMPLATE;
  const vars = contact.vars || { price: true, zone: true, detail: true };
  const agentName = contact.agentName || 'tu agente inmobiliario';
  const agentCompany = contact.agentCompany || '';
  const agentRole = contact.agentRole || 'agente inmobiliario profesional';

  // Build data lines
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

  // Build instructions
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
  else instructions.push('- NO anadaas detalle extra, elimina {{detalle}}');

  const msg = await anthropic.messages.create({
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
