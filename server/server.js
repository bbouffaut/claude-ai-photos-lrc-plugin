/**
 * server.js  v2.0 — Serveur Claude Photo AI
 *
 * Nouveauté v2 : supporte une photo modèle en plus du prompt texte.
 *
 * Payload POST /analyze :
 *   {
 *     image:     "base64...",          // photo à développer (obligatoire)
 *     mode:      "prompt"|"reference"|"both",
 *     prompt:    "instructions...",    // obligatoire si mode=prompt ou mode=both
 *     reference: "base64...",          // obligatoire si mode=reference ou mode=both
 *   }
 *
 * Démarrage :
 *   ANTHROPIC_API_KEY=sk-ant-... node server.js
 */

const http  = require('http');
const https = require('https');
const fs    = require('fs');
const path  = require('path');

// ============================================================
// Configuration
// ============================================================
const CONFIG = {
    PORT:       process.env.PORT             || 3000,
    API_KEY:    process.env.ANTHROPIC_API_KEY || '',
    MODEL:      'claude-sonnet-4-6',
    MAX_TOKENS: 2048,
    LOG_FILE:   path.join(__dirname, 'claude_photo_server.log'),
};

// ============================================================
// Logger
// ============================================================
function log(level, message) {
    const ts   = new Date().toISOString();
    const line = `[${ts}] [${level}] ${message}`;
    console.log(line);
    try { fs.appendFileSync(CONFIG.LOG_FILE, line + '\n'); } catch (_) {}
}

// ============================================================
// Prompt système (commun à tous les modes)
// ============================================================
const SYSTEM_PROMPT = `Tu es un expert en post-traitement photographique et en Lightroom Classic / Adobe Camera Raw.

RÈGLES ABSOLUES :
1. Réponds UNIQUEMENT avec le contenu XML du fichier XMP — aucun texte avant ou après, pas de backticks
2. Le XMP doit être compatible Lightroom Classic 6+ (ProcessVersion 11.0)
3. Utilise exclusivement les paramètres crs: avec les plages ci-dessous
4. N'inclus que les paramètres effectivement modifiés (pas les valeurs par défaut)
5. Préfère les ajustements naturels et subtils aux valeurs extrêmes

PLAGES DE VALEURS :
Exposition  : Exposure2012 (-5/+5), Contrast2012 (-100/+100)
Tonalités   : Highlights2012 (-100/+100), Shadows2012 (-100/+100), Whites2012 (-100/+100), Blacks2012 (-100/+100)
Présence    : Clarity2012 (-100/+100), Texture (-100/+100), Dehaze (-100/+100)
Couleur     : Temperature (2000/50000 K), Tint (-150/+150), Vibrance (-100/+100), Saturation (-100/+100)
HSL Teinte  : HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
HSL Sat.    : SaturationAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
HSL Lum.    : LuminanceAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
Courbe tone : ParametricShadows/Darks/Lights/Highlights (-100/+100)
              ParametricShadowSplit/MidtoneSplit/HighlightSplit (0/100)
Détail      : Sharpness (0/150), SharpenRadius (0.5/3.0), SharpenDetail (0/100), SharpenEdgeMasking (0/100)
              LuminanceSmoothing (0/100), ColorNoiseReduction (0/100)
Effets      : GrainAmount (0/100), GrainSize (25/100), GrainFrequency (0/100)
              VignetteAmount (-100/+100), VignetteMidpoint (0/100)
Calibration : ShadowTint (-100/+100), RedHue/GreenHue/BlueHue (-100/+100),
              RedSaturation/GreenSaturation/BlueSaturation (-100/+100)

FORMAT DE SORTIE OBLIGATOIRE (commence immédiatement par <?xpacket) :
<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
<rdf:Description rdf:about=''
  xmlns:crs='http://ns.adobe.com/camera-raw-settings/1.0/'
  crs:Version='14.4'
  crs:ProcessVersion='11.0'
  crs:WhiteBalance='Custom'
  [PARAMÈTRES]
/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>`;

// ============================================================
// Construction du message utilisateur selon le mode
// ============================================================
function buildUserMessage(mode, prompt) {
    switch (mode) {
        case 'prompt':
            return `Voici la photo à développer.\n\nInstructions : ${prompt}`;

        case 'reference':
            return `La PREMIÈRE IMAGE est la photo à développer.
La DEUXIÈME IMAGE est la photo modèle dont tu dois analyser et reproduire fidèlement le style.

Analyse en détail la photo modèle :
• Balance des blancs et température de couleur
• Exposition globale, gestion des hautes lumières et des ombres (courbe de tonalité)
• Contraste général : doux/dur, courbe en S ou aplatie
• Vibrance, saturation, palette de couleurs dominante
• Ajustements HSL éventuels (décalages de teinte, boosts de certaines couleurs)
• Grain photographique, vignettage, effets de style
• Caractère artistique général : chaud/froid, coloré/désaturé, lumineux/sombre, mat/contrasté

Génère un XMP qui transpose fidèlement ce style sur la première photo,
en tenant compte de ses propres caractéristiques (exposition native, dominante couleur, etc.)
pour que le résultat soit naturel et cohérent — pas une copie mécanique mais une interprétation intelligente.`;

        case 'both':
            return `La PREMIÈRE IMAGE est la photo à développer.
La DEUXIÈME IMAGE est la photo modèle dont tu dois t'inspirer pour le style général.

Étape 1 — Analyse le style de la photo modèle (balance des blancs, contraste, palette, HDR, grain, vignettage…)
Étape 2 — Applique ce style à la première photo en t'adaptant à ses caractéristiques propres
Étape 3 — Par-dessus ce style, applique ces ajustements complémentaires : ${prompt}

Si les instructions complémentaires entrent en conflit avec le style modèle sur un point précis,
les instructions ont la priorité sur ce point uniquement.`;

        default:
            return `Optimise cette photo. ${prompt || ''}`;
    }
}

// ============================================================
// Construction du tableau content Claude (images + texte)
// ============================================================
function buildClaudeContent(imageBase64, referenceBase64, mode, prompt) {
    const content = [];

    // Image 1 — toujours présente : la photo à développer
    content.push({
        type: 'image',
        source: {
            type:       'base64',
            media_type: 'image/jpeg',
            data:       imageBase64,
        },
    });

    // Image 2 — photo modèle (modes reference et both uniquement)
    if (referenceBase64 && (mode === 'reference' || mode === 'both')) {
        content.push({
            type: 'image',
            source: {
                type:       'base64',
                media_type: 'image/jpeg',
                data:       referenceBase64,
            },
        });
    }

    // Message texte
    content.push({
        type: 'text',
        text: buildUserMessage(mode, prompt),
    });

    return content;
}

// ============================================================
// Appel à l'API Claude
// ============================================================
function callClaudeAPI(imageBase64, referenceBase64, mode, prompt, apiKey) {
    return new Promise((resolve, reject) => {
        const content = buildClaudeContent(imageBase64, referenceBase64, mode, prompt);

        const body = JSON.stringify({
            model:      CONFIG.MODEL,
            max_tokens: CONFIG.MAX_TOKENS,
            system:     SYSTEM_PROMPT,
            messages:   [{ role: 'user', content }],
        });

        const options = {
            hostname: 'api.anthropic.com',
            port:     443,
            path:     '/v1/messages',
            method:   'POST',
            headers:  {
                'Content-Type':      'application/json',
                'Content-Length':    Buffer.byteLength(body),
                'x-api-key':         apiKey,
                'anthropic-version': '2023-06-01',
            },
        };

        const numImages = (mode === 'prompt') ? 1 : 2;
        log('INFO', `Appel API — modèle: ${CONFIG.MODEL}, mode: ${mode}, images: ${numImages}`);

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => { data += chunk; });
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    if (parsed.error) {
                        reject(new Error(`API error: ${parsed.error.message || JSON.stringify(parsed.error)}`));
                        return;
                    }
                    if (!parsed.content?.[0]?.text) {
                        reject(new Error('Réponse API vide ou malformée'));
                        return;
                    }
                    resolve(parsed.content[0].text);
                } catch (e) {
                    reject(new Error('Erreur parsing réponse: ' + e.message + '\n' + data.slice(0, 300)));
                }
            });
        });

        req.on('error', e => reject(new Error('Erreur réseau: ' + e.message)));
        req.setTimeout(150_000, () => {
            req.destroy();
            reject(new Error('Timeout 150s — API Claude sans réponse'));
        });

        req.write(body);
        req.end();
    });
}

// ============================================================
// Validation et nettoyage du XMP
// ============================================================
function validateAndCleanXMP(raw) {
    // Supprimer éventuels blocs Markdown
    let xmp = raw.replace(/```xml\n?/g, '').replace(/```\n?/g, '').trim();

    if (!xmp.includes('crs:')) {
        throw new Error('Le XMP généré ne contient aucun paramètre Camera Raw (crs:)');
    }

    // Ajouter les balises xpacket si absentes
    if (!xmp.includes('<?xpacket')) {
        xmp = `<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>\n` + xmp;
    }
    if (!xmp.includes('<?xpacket end=')) {
        xmp += `\n<?xpacket end='w'?>`;
    }

    return xmp;
}

// ============================================================
// Handler générique pour les requêtes POST /analyze
// ============================================================
async function handleAnalyze(body, apiKeyFromHeader, res) {
    let payload;
    try {
        payload = JSON.parse(body);
    } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'JSON invalide dans le corps de la requête' }));
        return;
    }

    const { image, mode = 'prompt', prompt = '', reference } = payload;
    const apiKey = apiKeyFromHeader || CONFIG.API_KEY;

    // --- Validations ---
    if (!apiKey) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            error: 'Clé API manquante. Définissez ANTHROPIC_API_KEY ou passez X-API-Key dans le header.',
        }));
        return;
    }

    if (!image) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Champ "image" (base64) manquant' }));
        return;
    }

    const validModes = ['prompt', 'reference', 'both'];
    if (!validModes.includes(mode)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: `Mode invalide: "${mode}". Valeurs: ${validModes.join(', ')}` }));
        return;
    }

    if ((mode === 'reference' || mode === 'both') && !reference) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            error: `Champ "reference" (base64) obligatoire pour le mode "${mode}"`,
        }));
        return;
    }

    if ((mode === 'prompt' || mode === 'both') && !prompt) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: `Champ "prompt" obligatoire pour le mode "${mode}"` }));
        return;
    }

    log('INFO', `Requête reçue — mode: ${mode}, image: ${Math.round(image.length/1024)}KB` +
        (reference ? `, référence: ${Math.round(reference.length/1024)}KB` : ''));

    try {
        const xmpRaw  = await callClaudeAPI(image, reference || null, mode, prompt, apiKey);
        const xmpFinal = validateAndCleanXMP(xmpRaw);

        log('INFO', `XMP généré — ${xmpFinal.length} chars`);

        res.writeHead(200, {
            'Content-Type':   'application/xml',
            'X-Claude-Model': CONFIG.MODEL,
            'X-Mode':         mode,
        });
        res.end(xmpFinal);

    } catch (err) {
        log('ERROR', err.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            error:      err.message,
            suggestion: 'Vérifiez la clé API, les images base64, et les logs du serveur.',
        }));
    }
}

// ============================================================
// Serveur HTTP
// ============================================================
const server = http.createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin',  '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');

    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    // ── GET /health ──────────────────────────────────────────
    if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status:     'ok',
            version:    '2.0.0',
            model:      CONFIG.MODEL,
            hasApiKey:  !!CONFIG.API_KEY,
            modes:      ['prompt', 'reference', 'both'],
        }));
        return;
    }

    // ── POST /analyze ─────────────────────────────────────────
    if (req.method === 'POST' && req.url === '/analyze') {
        let body = '';
        // Augmenter la limite de taille pour 2 images base64 (~8MB max)
        let size = 0;
        req.on('data', chunk => {
            size += chunk.length;
            if (size > 16 * 1024 * 1024) {   // 16 MB hard limit
                req.destroy();
                res.writeHead(413, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Payload trop volumineux (>16MB)' }));
                return;
            }
            body += chunk.toString();
        });
        req.on('end', () => handleAnalyze(body, req.headers['x-api-key'], res));
        return;
    }

    // ── POST /analyze-file ── test local avec chemin disque ──
    if (req.method === 'POST' && req.url === '/analyze-file') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', async () => {
            try {
                const payload     = JSON.parse(body);
                const apiKey      = req.headers['x-api-key'] || CONFIG.API_KEY;
                const mode        = payload.mode || 'prompt';
                const prompt      = payload.prompt || 'Optimise cette photo';

                if (!payload.imagePath || !fs.existsSync(payload.imagePath)) {
                    res.writeHead(404, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: `Fichier introuvable: ${payload.imagePath}` }));
                    return;
                }

                const imageBase64 = fs.readFileSync(payload.imagePath).toString('base64');
                let   refBase64   = null;

                if ((mode === 'reference' || mode === 'both') && payload.referencePath) {
                    if (!fs.existsSync(payload.referencePath)) {
                        res.writeHead(404, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify({ error: `Photo modèle introuvable: ${payload.referencePath}` }));
                        return;
                    }
                    refBase64 = fs.readFileSync(payload.referencePath).toString('base64');
                }

                const xmpRaw   = await callClaudeAPI(imageBase64, refBase64, mode, prompt, apiKey);
                const xmpFinal = validateAndCleanXMP(xmpRaw);

                res.writeHead(200, { 'Content-Type': 'application/xml' });
                res.end(xmpFinal);

            } catch (err) {
                log('ERROR', err.message);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: err.message }));
            }
        });
        return;
    }

    // ── 404 ───────────────────────────────────────────────────
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
        error:  'Route inconnue',
        routes: [
            'GET  /health',
            'POST /analyze       { image, mode, prompt?, reference? }',
            'POST /analyze-file  { imagePath, mode, prompt?, referencePath? }',
        ],
    }));
});

// ============================================================
// Démarrage
// ============================================================
server.listen(CONFIG.PORT, '127.0.0.1', () => {
    log('INFO', '╔══════════════════════════════════════╗');
    log('INFO', '║  Claude Photo AI v2 — Serveur local  ║');
    log('INFO', '╚══════════════════════════════════════╝');
    log('INFO', `Port: ${CONFIG.PORT} | Modèle: ${CONFIG.MODEL}`);
    log('INFO', `Clé API: ${CONFIG.API_KEY ? CONFIG.API_KEY.slice(0, 14) + '...' : 'non configurée'}`);

    console.log(`\n✅ Claude Photo AI v2 prêt sur http://localhost:${CONFIG.PORT}`);
    console.log('   Modes disponibles : prompt | reference | both');
    console.log('   Health check      : http://localhost:' + CONFIG.PORT + '/health\n');
});

server.on('error', e => {
    if (e.code === 'EADDRINUSE') {
        console.error(`\n❌ Port ${CONFIG.PORT} occupé — essayez: PORT=3001 node server.js`);
    } else {
        console.error('\n❌ Erreur serveur:', e.message);
    }
    process.exit(1);
});
