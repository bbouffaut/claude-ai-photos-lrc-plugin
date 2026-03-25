/**
 * server.js — Serveur intermédiaire pour le plugin Claude Photo AI
 *
 * Ce serveur fait le pont entre le plugin Lightroom (Lua) et l'API Claude.
 * Il est nécessaire car Lightroom ne peut pas faire d'appels HTTPS complexes
 * avec des corps de requête volumineux (images base64).
 *
 * Démarrage : node server.js
 * Ou avec votre clé API : ANTHROPIC_API_KEY=sk-ant-... node server.js
 */

const http     = require('http');
const https    = require('https');
const fs       = require('fs');
const path     = require('path');
const readline = require('readline');

// ============================================================
// Configuration
// ============================================================
const CONFIG = {
    PORT:        process.env.PORT        || 3000,
    API_KEY:     process.env.ANTHROPIC_API_KEY || '',
    MODEL:       'claude-opus-4-5',
    MAX_TOKENS:  2048,
    LOG_FILE:    path.join(__dirname, 'claude_photo_server.log'),
};

// ============================================================
// Logger
// ============================================================
function log(level, message) {
    const timestamp = new Date().toISOString();
    const line = `[${timestamp}] [${level}] ${message}`;
    console.log(line);
    fs.appendFileSync(CONFIG.LOG_FILE, line + '\n', { encoding: 'utf8', flag: 'a' });
}

// ============================================================
// Prompt système pour Claude
// ============================================================
const SYSTEM_PROMPT = `Tu es un expert en post-traitement photographique et en Lightroom Classic.

Ta mission : analyser une photo et les instructions de l'utilisateur, puis générer un fichier XMP Adobe Lightroom valide contenant UNIQUEMENT les ajustements Develop demandés.

RÈGLES ABSOLUES :
1. Réponds UNIQUEMENT avec le contenu XML du fichier XMP, sans aucun texte avant ou après, pas de backticks, pas d'explications
2. Le XMP doit être compatible Lightroom Classic 6+ / Adobe Camera Raw
3. Utilise les paramètres crs: (Camera Raw Settings) avec les plages correctes
4. N'inclus que les paramètres utiles — pas besoin de lister tous les défauts
5. Sois précis : de petits ajustements subtils sont souvent préférables aux extrêmes

PLAGES DE VALEURS VALIDES :
Lumière : Exposure2012 (-5/+5), Contrast2012 (-100/+100), Highlights2012 (-100/+100),
          Shadows2012 (-100/+100), Whites2012 (-100/+100), Blacks2012 (-100/+100)
Présence : Clarity2012 (-100/+100), Dehaze (-100/+100), Texture (-100/+100)
Couleur  : Vibrance (-100/+100), Saturation (-100/+100), Temperature (2000/50000), Tint (-150/+150)
HSL      : HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
           SaturationAdjustmentRed/... (-100/+100), LuminanceAdjustmentRed/... (-100/+100)
Détail   : Sharpness (0/150), SharpenRadius (0.5/3.0), SharpenDetail (0/100),
           LuminanceSmoothing (0/100), ColorNoiseReduction (0/100)
Courbes  : ParametricShadows (-100/+100), ParametricDarks (-100/+100),
           ParametricLights (-100/+100), ParametricHighlights (-100/+100)
Effets   : GrainAmount (0/100), GrainSize (25/100), VignetteAmount (-100/+100)
Calibration : ShadowTint (-100/+100), RedHue (-100/+100), RedSaturation (-100/+100),
              GreenHue (-100/+100), GreenSaturation (-100/+100), BlueHue (-100/+100), BlueSaturation (-100/+100)

FORMAT DE SORTIE OBLIGATOIRE (commence directement par <?xpacket) :
<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
<rdf:Description rdf:about=''
  xmlns:crs='http://ns.adobe.com/camera-raw-settings/1.0/'
  crs:Version='14.4'
  crs:ProcessVersion='11.0'
  crs:WhiteBalance='Custom'
  crs:Exposure2012="0.00"
  [... autres paramètres ...]
/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>`;

// ============================================================
// Appel à l'API Claude
// ============================================================
async function callClaudeAPI(imageBase64, userPrompt, apiKey) {
    return new Promise((resolve, reject) => {
        const requestBody = JSON.stringify({
            model:      CONFIG.MODEL,
            max_tokens: CONFIG.MAX_TOKENS,
            system:     SYSTEM_PROMPT,
            messages: [
                {
                    role: 'user',
                    content: [
                        {
                            type: 'image',
                            source: {
                                type:       'base64',
                                media_type: 'image/jpeg',
                                data:       imageBase64,
                            }
                        },
                        {
                            type: 'text',
                            text: userPrompt
                        }
                    ]
                }
            ]
        });

        const options = {
            hostname: 'api.anthropic.com',
            port:     443,
            path:     '/v1/messages',
            method:   'POST',
            headers: {
                'Content-Type':      'application/json',
                'Content-Length':    Buffer.byteLength(requestBody),
                'x-api-key':         apiKey,
                'anthropic-version': '2023-06-01',
            }
        };

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => { data += chunk; });
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    
                    if (parsed.error) {
                        reject(new Error(`API Error: ${parsed.error.message || JSON.stringify(parsed.error)}`));
                        return;
                    }
                    
                    if (!parsed.content || !parsed.content[0]) {
                        reject(new Error('Réponse API vide ou malformée'));
                        return;
                    }
                    
                    const xmpContent = parsed.content[0].text;
                    resolve(xmpContent);
                } catch (e) {
                    reject(new Error('Erreur parsing réponse API: ' + e.message));
                }
            });
        });

        req.on('error', (e) => {
            reject(new Error('Erreur réseau: ' + e.message));
        });

        req.setTimeout(120000, () => {
            req.destroy();
            reject(new Error('Timeout: l\'API Claude n\'a pas répondu en 120s'));
        });

        req.write(requestBody);
        req.end();
    });
}

// ============================================================
// Validation et nettoyage du XMP
// ============================================================
function validateAndCleanXMP(xmpContent) {
    // Supprimer les éventuels backticks Markdown
    xmpContent = xmpContent.replace(/```xml\n?/g, '').replace(/```\n?/g, '');
    xmpContent = xmpContent.trim();
    
    // Vérifier la présence des marqueurs XMP requis
    const hasXpacket = xmpContent.includes('<?xpacket');
    const hasXmpmeta = xmpContent.includes('xmpmeta');
    const hasCrs     = xmpContent.includes('crs:');
    
    if (!hasCrs) {
        throw new Error('Le XMP généré ne contient aucun paramètre Camera Raw (crs:)');
    }
    
    // Si pas de déclaration xpacket, l'ajouter
    if (!hasXpacket) {
        xmpContent = `<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>\n` + xmpContent;
    }
    if (!xmpContent.includes('<?xpacket end=')) {
        xmpContent += `\n<?xpacket end='w'?>`;
    }
    
    return xmpContent;
}

// ============================================================
// Serveur HTTP
// ============================================================
const server = http.createServer(async (req, res) => {
    // CORS pour faciliter les tests depuis le navigateur
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
    
    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }
    
    // ── GET /health ── vérification que le serveur tourne
    if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status:    'ok',
            version:   '1.0.0',
            model:     CONFIG.MODEL,
            hasApiKey: !!CONFIG.API_KEY,
        }));
        return;
    }
    
    // ── POST /analyze ── endpoint principal
    if (req.method === 'POST' && req.url === '/analyze') {
        let body = '';
        
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', async () => {
            try {
                log('INFO', `Requête reçue : ${body.length} bytes`);
                
                // Parser le JSON
                let payload;
                try {
                    payload = JSON.parse(body);
                } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'JSON invalide dans le corps de la requête' }));
                    return;
                }
                
                const { image, prompt } = payload;
                
                // Récupérer la clé API (header ou config)
                const apiKey = req.headers['x-api-key'] || CONFIG.API_KEY;
                
                if (!apiKey) {
                    res.writeHead(401, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ 
                        error: 'Clé API manquante. Définissez ANTHROPIC_API_KEY ou passez X-API-Key dans le header.' 
                    }));
                    return;
                }
                
                if (!image) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Champ "image" (base64) manquant' }));
                    return;
                }
                
                if (!prompt) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Champ "prompt" manquant' }));
                    return;
                }
                
                log('INFO', `Appel Claude API — Modèle: ${CONFIG.MODEL}, Prompt: "${prompt.substring(0, 80)}..."`);
                
                // Appeler l'API Claude
                const xmpRaw = await callClaudeAPI(image, prompt, apiKey);
                
                log('INFO', `Réponse reçue : ${xmpRaw.length} chars`);
                
                // Valider et nettoyer le XMP
                const xmpContent = validateAndCleanXMP(xmpRaw);
                
                log('INFO', 'XMP validé et nettoyé avec succès');
                
                // Retourner le XMP directement (ou en JSON)
                res.writeHead(200, { 
                    'Content-Type': 'application/xml',
                    'X-Claude-Model': CONFIG.MODEL,
                });
                res.end(xmpContent);
                
            } catch (error) {
                log('ERROR', error.message);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ 
                    error: error.message,
                    suggestion: 'Vérifiez votre clé API et que la photo a bien été encodée en base64'
                }));
            }
        });
        
        return;
    }
    
    // ── POST /analyze-file ── pour tester depuis curl avec un fichier JPEG local
    if (req.method === 'POST' && req.url === '/analyze-file') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', async () => {
            try {
                const payload   = JSON.parse(body);
                const imagePath = payload.imagePath;
                const prompt    = payload.prompt || 'Optimise cette photo';
                const apiKey    = req.headers['x-api-key'] || CONFIG.API_KEY;
                
                if (!fs.existsSync(imagePath)) {
                    res.writeHead(404, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: `Fichier introuvable: ${imagePath}` }));
                    return;
                }
                
                const imageBuffer = fs.readFileSync(imagePath);
                const imageBase64 = imageBuffer.toString('base64');
                
                const xmpRaw     = await callClaudeAPI(imageBase64, prompt, apiKey);
                const xmpContent = validateAndCleanXMP(xmpRaw);
                
                res.writeHead(200, { 'Content-Type': 'application/xml' });
                res.end(xmpContent);
                
            } catch (error) {
                log('ERROR', error.message);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: error.message }));
            }
        });
        return;
    }
    
    // Route inconnue
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ 
        error: 'Route inconnue',
        routes: [
            'GET  /health',
            'POST /analyze       { image: "base64...", prompt: "..." }',
            'POST /analyze-file  { imagePath: "/path/to/photo.jpg", prompt: "..." }',
        ]
    }));
});

// ============================================================
// Démarrage
// ============================================================
function promptForApiKey(callback) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question('Clé API Anthropic (laissez vide pour configurer plus tard) : ', (answer) => {
        rl.close();
        callback(answer.trim());
    });
}

async function start() {
    log('INFO', '╔══════════════════════════════════════╗');
    log('INFO', '║   Claude Photo AI — Serveur local    ║');
    log('INFO', '╚══════════════════════════════════════╝');
    
    if (!CONFIG.API_KEY) {
        console.log('\n⚠️  Aucune clé API trouvée dans ANTHROPIC_API_KEY');
        console.log('   Vous pourrez la passer via le header X-API-Key sur chaque requête,');
        console.log('   ou la configurer dans le plugin Lightroom.\n');
    } else {
        log('INFO', `Clé API configurée (${CONFIG.API_KEY.substring(0, 10)}...)`);
    }
    
    server.listen(CONFIG.PORT, '127.0.0.1', () => {
        log('INFO', `Serveur démarré sur http://localhost:${CONFIG.PORT}`);
        console.log('\n✅ Serveur Claude Photo AI prêt !');
        console.log(`   URL: http://localhost:${CONFIG.PORT}`);
        console.log(`   Health check: http://localhost:${CONFIG.PORT}/health`);
        console.log('\n   Laissez ce terminal ouvert pendant que vous utilisez Lightroom.\n');
    });
    
    server.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
            log('ERROR', `Le port ${CONFIG.PORT} est déjà utilisé. Changez PORT= dans la commande.`);
            console.error(`\n❌ Port ${CONFIG.PORT} occupé. Essayez: PORT=3001 node server.js`);
        } else {
            log('ERROR', e.message);
        }
        process.exit(1);
    });
}

start();
