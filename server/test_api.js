#!/usr/bin/env node
/**
 * test_api.js v2 — Test des trois modes du serveur Claude Photo AI
 *
 * Usage :
 *   node test_api.js                                         # health check uniquement
 *   node test_api.js prompt   photo.jpg "Style cinématique"
 *   node test_api.js reference photo.jpg modele.jpg
 *   node test_api.js both      photo.jpg modele.jpg "Ajoute plus de grain"
 */

const http = require('http');
const fs   = require('fs');
const path = require('path');

const SERVER = process.env.SERVER_URL || 'http://localhost:3000';
const MODE   = process.argv[2] || 'health';
const IMG    = process.argv[3];
const ARG4   = process.argv[4];
const ARG5   = process.argv[5];

function request(method, url, body) {
    return new Promise((resolve, reject) => {
        const u = new URL(url);
        const opts = {
            hostname: u.hostname, port: u.port || 80,
            path: u.pathname, method,
            headers: body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {},
        };
        const req = http.request(opts, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => resolve({ status: res.statusCode, body: data }));
        });
        req.on('error', reject);
        req.setTimeout(160000, () => { req.destroy(); reject(new Error('Timeout')); });
        if (body) req.write(body);
        req.end();
    });
}

async function main() {
    console.log('╔══════════════════════════════════════╗');
    console.log('║  Claude Photo AI v2 — Tests          ║');
    console.log('╚══════════════════════════════════════╝\n');

    // Health check
    console.log('🔍 Health check...');
    const h = await request('GET', SERVER + '/health').catch(e => ({ status: 0, body: e.message }));
    if (h.status === 200) {
        const j = JSON.parse(h.body);
        console.log(`   ✅ Serveur OK — modèle: ${j.model} | clé: ${j.hasApiKey ? 'oui' : 'non'}`);
        console.log(`   Modes: ${j.modes.join(', ')}`);
    } else {
        console.log(`   ❌ Serveur inaccessible: ${h.body}`);
        process.exit(1);
    }

    if (MODE === 'health' || !IMG) {
        console.log('\n✅ Health check réussi. Lancez avec un mode et des images pour tester.');
        return;
    }

    if (!fs.existsSync(IMG)) { console.error('❌ Image introuvable:', IMG); process.exit(1); }

    const imageBase64 = fs.readFileSync(IMG).toString('base64');
    let   payload     = { image: imageBase64, mode: MODE };

    if (MODE === 'prompt') {
        payload.prompt = ARG4 || 'Style cinématique désaturé';
    } else if (MODE === 'reference') {
        if (!ARG4 || !fs.existsSync(ARG4)) { console.error('❌ Photo modèle introuvable:', ARG4); process.exit(1); }
        payload.reference = fs.readFileSync(ARG4).toString('base64');
    } else if (MODE === 'both') {
        if (!ARG4 || !fs.existsSync(ARG4)) { console.error('❌ Photo modèle introuvable:', ARG4); process.exit(1); }
        payload.reference = fs.readFileSync(ARG4).toString('base64');
        payload.prompt    = ARG5 || 'Ajoute un grain subtil et un léger vignettage';
    }

    console.log(`\n🤖 Test mode "${MODE}"...`);
    if (payload.prompt)    console.log(`   Prompt    : "${payload.prompt}"`);
    if (MODE !== 'prompt') console.log(`   Référence : ${Math.round(payload.reference.length/1024)}KB`);
    console.log(`   Image     : ${Math.round(payload.image.length/1024)}KB`);

    const r = await request('POST', SERVER + '/analyze', JSON.stringify(payload))
        .catch(e => ({ status: 0, body: e.message }));

    if (r.status === 200) {
        const params = [...r.body.matchAll(/crs:([A-Za-z0-9]+)="([^"]*)"/g)]
            .filter(m => !['Version','ProcessVersion','WhiteBalance'].includes(m[1]))
            .map(m => `   ${m[1].padEnd(30)} = ${m[2]}`);

        console.log(`\n   ✅ XMP généré — ${r.body.length} chars, ${params.length} paramètre(s)`);
        if (params.length) { console.log('\n   Paramètres :'); params.forEach(p => console.log(p)); }

        const out = path.join(__dirname, `test_${MODE}_output.xmp`);
        fs.writeFileSync(out, r.body);
        console.log(`\n   💾 Sauvegardé : ${out}`);
        console.log('   → Glissez ce .xmp dans Lightroom pour vérifier le résultat !');
    } else {
        try {
            const err = JSON.parse(r.body);
            console.log(`\n   ❌ Erreur ${r.status}: ${err.error}`);
            if (err.suggestion) console.log(`   💡 ${err.suggestion}`);
        } catch (_) {
            console.log(`\n   ❌ Erreur ${r.status}: ${r.body.slice(0, 300)}`);
        }
    }
}

main().catch(console.error);
