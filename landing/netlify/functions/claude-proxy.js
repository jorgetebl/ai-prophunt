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
      result = await extractPhone(payload.domText, payload.portal);
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

async function extractPhone(domText, portal) {
  const truncated = domText.slice(0, 14000);
  const msg = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 256,
    messages: [{
      role: 'user',
      content: `Eres un extractor de teléfonos de fichas inmobiliarias en ${portal}.

Analiza este texto de la página y responde con JSON:

Si encuentras un número de teléfono visible:
{"found": true, "phone": "612345678"}

Si hay un botón que hay que pulsar para ver el teléfono (p.ej. "Ver teléfono", "Mostrar teléfono", "Contactar"):
{"found": false, "action": "click", "hint": "texto exacto del botón"}

Si no hay teléfono ni botón de contacto:
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

async function buildMessage(contact) {
  const msg = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 512,
    messages: [{
      role: 'user',
      content: `Eres Juanan Gomis, agente API profesional en REMAX Experience (Palma de Mallorca).
Escribe un WhatsApp para captar a un particular que vende su piso. Usa esta plantilla base pero personalízala:

---
Hola{{nombre_parte}}, soy Juanan Gomis agente Api profesional y asociado a REMAX EXPERIENCE

He visto tu {{tipo}} en {{zona}} que tienes en {{portal}}{{precio_parte}}. {{detalle}}

No te escribo para convencerte de trabajar con una agencia 🙂

Solo comentarte algo: vender por tu cuenta es totalmente posible, pero vender bien, en menos tiempo y sin tener que bajar el precio es lo complicado.

En REMAX trabajamos con una red de 21 oficinas en Palma y más de 170 agentes, además de una inversión fuerte en marketing digital para llegar al comprador adecuado.

Si algún día te apetece ver cómo lo trabajaríamos y luego decides si te aporta valor o no, llámame y lo vemos sin ningún compromiso.
---

Datos del inmueble:
- Nombre vendedor: ${contact.name || 'desconocido'}
- Zona: ${contact.zone || 'Palma de Mallorca'}
- Portal: ${contact.portal || 'el portal'}
- Precio: ${contact.price ? Number(contact.price).toLocaleString('es-ES') + ' €' : 'desconocido'}
- Tipo: ${contact.propertyType || 'vivienda'}
- Detalle extra: ${contact.detail || ''}

Instrucciones:
- Si hay nombre: "Hola [nombre]," — si no hay nombre: "Hola,"
- Reemplaza {{tipo}}, {{zona}}, {{portal}} con los datos reales
- Si hay precio: "por [precio]" — si no hay precio: omite esa parte
- {{detalle}}: UNA frase natural (máx 20 palabras) mencionando algo concreto y positivo del inmueble
- Mantén el tono profesional pero cercano
- Devuelve SOLO el mensaje, sin comillas, sin explicaciones`,
    }],
  });

  return msg.content[0].text.trim();
}
