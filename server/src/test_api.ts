#!/usr/bin/env node

import fs from 'fs';
import http from 'http';
import path from 'path';

import { CONFIG } from './config';
import { RequestResult, TestMode, TestPayload } from './types';

const MODE = (process.argv[2] as TestMode | undefined) ?? 'health';
const IMG = process.argv[3];
const ARG4 = process.argv[4];
const ARG5 = process.argv[5];

const request = (method: string, url: string, body?: string): Promise<RequestResult> =>
    new Promise((resolve, reject) => {
        const parsedUrl = new URL(url);
        const hostname = parsedUrl.hostname;
        const req = http.request(
            {
                hostname,
                port: parsedUrl.port ? Number(parsedUrl.port) : 80,
                path: parsedUrl.pathname,
                method,
                family: hostname === 'localhost' ? 4 : undefined,
                headers: body
                    ? {
                          'Content-Type': 'application/json',
                          'Content-Length': Buffer.byteLength(body),
                      }
                    : {},
            },
            (res) => {
                let data = '';
                res.on('data', (chunk: Buffer) => {
                    data += chunk.toString();
                });
                res.on('end', () => resolve({ status: res.statusCode ?? 0, body: data }));
            },
        );

        req.on('error', reject);
        req.setTimeout(160_000, () => {
            req.destroy();
            reject(new Error('Timeout'));
        });
        if (body) {
            req.write(body);
        }
        req.end();
    });

const main = async (): Promise<void> => {
    console.log('╔══════════════════════════════════════╗');
    console.log('║  Claude Photo AI v2 — Tests          ║');
    console.log('╚══════════════════════════════════════╝\n');

    console.log('🔍 Health check...');
    const health = await request('GET', `${CONFIG.SERVER_URL}/health`).catch((error: Error) => ({
        status: 0,
        body: error.message,
    }));

    if (health.status === 200) {
        const parsed = JSON.parse(health.body) as {
            model: string;
            hasApiKey: boolean;
            modes: string[];
        };
        console.log(`   ✅ Serveur OK — modèle: ${parsed.model} | clé: ${parsed.hasApiKey ? 'oui' : 'non'}`);
        console.log(`   Modes: ${parsed.modes.join(', ')}`);
    } else {
        console.log(`   ❌ Serveur inaccessible: ${health.body}`);
        process.exit(1);
    }

    if (MODE === 'health' || !IMG) {
        console.log('\n✅ Health check réussi. Lancez avec un mode et des images pour tester.');
        return;
    }

    if (!fs.existsSync(IMG)) {
        console.error('❌ Image introuvable:', IMG);
        process.exit(1);
    }

    const payload: TestPayload = {
        image: fs.readFileSync(IMG).toString('base64'),
        mode: MODE,
    };

    if (MODE === 'prompt') {
        payload.prompt = ARG4 ?? 'Style cinématique désaturé';
    } else if (MODE === 'reference') {
        if (!ARG4 || !fs.existsSync(ARG4)) {
            console.error('❌ Photo modèle introuvable:', ARG4);
            process.exit(1);
        }
        payload.reference = fs.readFileSync(ARG4).toString('base64');
    } else if (MODE === 'both') {
        if (!ARG4 || !fs.existsSync(ARG4)) {
            console.error('❌ Photo modèle introuvable:', ARG4);
            process.exit(1);
        }
        payload.reference = fs.readFileSync(ARG4).toString('base64');
        payload.prompt = ARG5 ?? 'Ajoute un grain subtil et un léger vignettage';
    }

    console.log(`\n🤖 Test mode "${MODE}"...`);
    if (payload.prompt) {
        console.log(`   Prompt    : "${payload.prompt}"`);
    }
    if (payload.reference) {
        console.log(`   Référence : ${Math.round(payload.reference.length / 1024)}KB`);
    }
    console.log(`   Image     : ${Math.round(payload.image.length / 1024)}KB`);

    const result = await request('POST', `${CONFIG.SERVER_URL}/analyze`, JSON.stringify(payload)).catch(
        (error: Error) => ({
            status: 0,
            body: error.message,
        }),
    );

    if (result.status === 200) {
        const params = [...result.body.matchAll(/crs:([A-Za-z0-9]+)="([^"]*)"/g)]
            .filter((match) => !['Version', 'ProcessVersion', 'WhiteBalance'].includes(match[1]))
            .map((match) => `   ${match[1].padEnd(30)} = ${match[2]}`);

        console.log(`\n   ✅ XMP généré — ${result.body.length} chars, ${params.length} paramètre(s)`);
        if (params.length > 0) {
            console.log('\n   Paramètres :');
            params.forEach((param) => console.log(param));
        }

        const outputPath = path.join(__dirname, `..`, `test_${MODE}_output.xmp`);
        fs.writeFileSync(outputPath, result.body);
        console.log(`\n   💾 Sauvegardé : ${outputPath}`);
        console.log('   → Glissez ce .xmp dans Lightroom pour vérifier le résultat !');
    } else {
        try {
            const parsedError = JSON.parse(result.body) as { error: string; suggestion?: string };
            console.log(`\n   ❌ Erreur ${result.status}: ${parsedError.error}`);
            if (parsedError.suggestion) {
                console.log(`   💡 ${parsedError.suggestion}`);
            }
        } catch {
            console.log(`\n   ❌ Erreur ${result.status}: ${result.body.slice(0, 300)}`);
        }
    }
};

main().catch((error: Error) => {
    console.error(error);
    process.exit(1);
});
