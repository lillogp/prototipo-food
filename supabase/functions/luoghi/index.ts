import { createClient } from 'npm:@supabase/supabase-js@2';

// Suggerimenti di indirizzi e località (Google Places). La chiave resta qui, nel segreto GOOGLE_PLACES_KEY: non finisce mai nell'app.
// Possono usarla solo gli amministratori e i commercianti (chi ha una bottega), con un limite di richieste al minuto.
// Già pubblicata su Supabase (verify_jwt = true). Senza chiave risponde 503 e app e pannello usano Photon.
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const recenti = new Map<string, number[]>();
const permessi = new Map<string, { ok: boolean; t: number }>();

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const j = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });
  const chiave = Deno.env.get('GOOGLE_PLACES_KEY');
  if (!chiave) return j({ errore: 'nessuna_chiave' }, 503);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return j({ errore: 'accesso' }, 401);

  // chi può usarla: amministratori e commercianti (controllo ricordato per 5 minuti)
  let p = permessi.get(user.id);
  if (!p || Date.now() - p.t > 300000) {
    const [a, b] = await Promise.all([
      sb.from('profiles').select('is_admin').eq('id', user.id).maybeSingle(),
      sb.from('botteghe').select('id').eq('owner_id', user.id).maybeSingle(),
    ]);
    p = { ok: !!(a.data as any)?.is_admin || !!b.data, t: Date.now() };
    permessi.set(user.id, p);
  }
  if (!p.ok) return j({ errore: 'non_autorizzato' }, 403);

  // massimo 40 richieste al minuto per persona
  const ora = Date.now();
  const l = (recenti.get(user.id) || []).filter((t) => ora - t < 60000);
  if (l.length >= 40) return j({ errore: 'troppe_richieste' }, 429);
  l.push(ora); recenti.set(user.id, l);

  let b: any;
  try { b = await req.json(); } catch { return j({ errore: 'richiesta' }, 400); }
  const sessione = /^[A-Za-z0-9-]{8,64}$/.test(String(b?.sessione || '')) ? String(b.sessione) : undefined;

  try {
    if (b?.azione === 'suggerisci') {
      const q = String(b.q || '').trim().slice(0, 100);
      if (q.length < 3) return j({ risultati: [] });
      const corpo: Record<string, unknown> = {
        input: q, languageCode: 'it', regionCode: 'IT', includedRegionCodes: ['it'], sessionToken: sessione,
        locationBias: { circle: { center: { latitude: 44.22, longitude: 12.04 }, radius: 50000 } },
      };
      if (b.tipo === 'zona') corpo.includedPrimaryTypes = ['locality', 'sublocality', 'neighborhood', 'administrative_area_level_3'];
      const r = await fetch('https://places.googleapis.com/v1/places:autocomplete', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': chiave }, body: JSON.stringify(corpo) });
      if (!r.ok) return j({ errore: 'google', stato: r.status }, 502);
      const d = await r.json();
      const risultati = (d.suggestions || []).map((s: any) => s.placePrediction).filter(Boolean).slice(0, 8)
        .map((x: any) => ({ id: String(x.placeId), testo: String(x.text?.text || '').replace(/,\s*Italia$/, '') }))
        .filter((x: any) => x.id && x.testo);
      return j({ risultati });
    }
    if (b?.azione === 'dettaglio') {
      const id = String(b.id || '');
      if (!/^[A-Za-z0-9_-]{10,300}$/.test(id)) return j({ errore: 'richiesta' }, 400);
      const r = await fetch('https://places.googleapis.com/v1/places/' + id + '?languageCode=it' + (sessione ? '&sessionToken=' + sessione : ''), { headers: { 'X-Goog-Api-Key': chiave, 'X-Goog-FieldMask': 'location,addressComponents' } });
      if (!r.ok) return j({ errore: 'google', stato: r.status }, 502);
      const d = await r.json();
      const comp = (t: string) => (d.addressComponents || []).find((c: any) => (c.types || []).includes(t))?.longText || '';
      return j({ lat: d.location?.latitude ?? null, lon: d.location?.longitude ?? null, citta: comp('locality') || comp('administrative_area_level_3') || '' });
    }
    return j({ errore: 'richiesta' }, 400);
  } catch (_e) {
    return j({ errore: 'interno' }, 500);
  }
});
