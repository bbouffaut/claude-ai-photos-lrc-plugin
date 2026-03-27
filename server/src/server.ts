import fs from 'fs';
import http, { IncomingMessage, ServerResponse } from 'http';
import { callClaudeAPI, validateAndCleanXMP } from './claude';
import { CONFIG } from './config';
import { log } from './logger';
import { AnalyzeFilePayload, AnalyzeMode, AnalyzePayload } from './types';

const sendJson = (res: ServerResponse, statusCode: number, payload: unknown): void => {
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(payload));
};

const getHeaderValue = (header: string | string[] | undefined): string =>
    Array.isArray(header) ? header[0] ?? '' : header ?? '';

const handleAnalyze = async (body: string, apiKeyFromHeader: string, res: ServerResponse): Promise<void> => {
    let payload: AnalyzePayload;

    try {
        payload = JSON.parse(body) as AnalyzePayload;
    } catch {
        sendJson(res, 400, { error: 'JSON invalide dans le corps de la requête' });
        return;
    }

    const image = payload.image;
    const mode = payload.mode ?? 'prompt';
    const prompt = payload.prompt ?? '';
    const reference = payload.reference;
    const apiKey = apiKeyFromHeader || CONFIG.API_KEY;
    const validModes: AnalyzeMode[] = ['prompt', 'reference', 'both'];

    if (!apiKey) {
        sendJson(res, 401, {
            error: 'Clé API manquante. Définissez ANTHROPIC_API_KEY ou passez X-API-Key dans le header.',
        });
        return;
    }
    if (!image) {
        sendJson(res, 400, { error: 'Champ "image" (base64) manquant' });
        return;
    }
    if (!validModes.includes(mode)) {
        sendJson(res, 400, { error: `Mode invalide: "${mode}". Valeurs: ${validModes.join(', ')}` });
        return;
    }
    if ((mode === 'reference' || mode === 'both') && !reference) {
        sendJson(res, 400, { error: `Champ "reference" (base64) obligatoire pour le mode "${mode}"` });
        return;
    }
    if ((mode === 'prompt' || mode === 'both') && !prompt) {
        sendJson(res, 400, { error: `Champ "prompt" obligatoire pour le mode "${mode}"` });
        return;
    }

    log(
        'INFO',
        `Requête reçue — mode: ${mode}, image: ${Math.round(image.length / 1024)}KB${
            reference ? `, référence: ${Math.round(reference.length / 1024)}KB` : ''
        }`,
    );

    try {
        const xmpRaw = await callClaudeAPI(image, reference ?? null, mode, prompt, apiKey);
        const xmpFinal = validateAndCleanXMP(xmpRaw);

        log('INFO', `XMP généré — ${xmpFinal.length} chars`);
        res.writeHead(200, {
            'Content-Type': 'application/xml',
            'X-Claude-Model': CONFIG.MODEL,
            'X-Mode': mode,
        });
        res.end(xmpFinal);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        log('ERROR', message);
        sendJson(res, 500, {
            error: message,
            suggestion: 'Vérifiez la clé API, les images base64, et les logs du serveur.',
        });
    }
};

const readRequestBody = (req: IncomingMessage, maxSizeBytes: number): Promise<string> =>
    new Promise((resolve, reject) => {
        let body = '';
        let size = 0;

        req.on('data', (chunk: Buffer) => {
            size += chunk.length;
            if (size > maxSizeBytes) {
                reject(Object.assign(new Error('Payload trop volumineux (>16MB)'), { statusCode: 413 }));
                req.destroy();
                return;
            }
            body += chunk.toString();
        });
        req.on('end', () => resolve(body));
        req.on('error', reject);
    });

const handleAnalyzeFile = async (body: string, apiKeyFromHeader: string, res: ServerResponse): Promise<void> => {
    try {
        const payload = JSON.parse(body) as AnalyzeFilePayload;
        const apiKey = apiKeyFromHeader || CONFIG.API_KEY;
        const mode = payload.mode ?? 'prompt';
        const prompt = payload.prompt ?? 'Optimise cette photo';

        if (!apiKey) {
            sendJson(res, 401, {
                error: 'Clé API manquante. Définissez ANTHROPIC_API_KEY ou passez X-API-Key dans le header.',
            });
            return;
        }
        if (!payload.imagePath || !fs.existsSync(payload.imagePath)) {
            sendJson(res, 404, { error: `Fichier introuvable: ${payload.imagePath}` });
            return;
        }

        const imageBase64 = fs.readFileSync(payload.imagePath).toString('base64');
        let referenceBase64: string | null = null;

        if ((mode === 'reference' || mode === 'both') && payload.referencePath) {
            if (!fs.existsSync(payload.referencePath)) {
                sendJson(res, 404, { error: `Photo modèle introuvable: ${payload.referencePath}` });
                return;
            }
            referenceBase64 = fs.readFileSync(payload.referencePath).toString('base64');
        }

        const xmpRaw = await callClaudeAPI(imageBase64, referenceBase64, mode, prompt, apiKey);
        const xmpFinal = validateAndCleanXMP(xmpRaw);

        res.writeHead(200, { 'Content-Type': 'application/xml' });
        res.end(xmpFinal);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        log('ERROR', message);
        sendJson(res, 500, { error: message });
    }
};

const server = http.createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');

    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    if (req.method === 'GET' && req.url === '/health') {
        sendJson(res, 200, {
            status: 'ok',
            version: CONFIG.VERSION,
            model: CONFIG.MODEL,
            hasApiKey: Boolean(CONFIG.API_KEY),
            modes: ['prompt', 'reference', 'both'],
        });
        return;
    }

    if (req.method === 'POST' && req.url === '/analyze') {
        try {
            const body = await readRequestBody(req, CONFIG.MAX_BODY_SIZE_BYTES);
            await handleAnalyze(body, getHeaderValue(req.headers['x-api-key']), res);
        } catch (error) {
            const statusCode =
                typeof error === 'object' &&
                error !== null &&
                'statusCode' in error &&
                typeof (error as { statusCode?: number }).statusCode === 'number'
                    ? (error as { statusCode: number }).statusCode
                    : 500;
            const message = error instanceof Error ? error.message : String(error);
            sendJson(res, statusCode, { error: message });
        }
        return;
    }

    if (req.method === 'POST' && req.url === '/analyze-file') {
        try {
            const body = await readRequestBody(req, CONFIG.MAX_BODY_SIZE_BYTES);
            await handleAnalyzeFile(body, getHeaderValue(req.headers['x-api-key']), res);
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            sendJson(res, 500, { error: message });
        }
        return;
    }

    sendJson(res, 404, {
        error: 'Route inconnue',
        routes: [
            'GET  /health',
            'POST /analyze       { image, mode, prompt?, reference? }',
            'POST /analyze-file  { imagePath, mode, prompt?, referencePath? }',
        ],
    });
});

server.listen(CONFIG.PORT, '127.0.0.1', () => {
    log('INFO', '╔══════════════════════════════════════╗');
    log('INFO', '║  Claude Photo AI v2 — Serveur local  ║');
    log('INFO', '╚══════════════════════════════════════╝');
    log('INFO', `Port: ${CONFIG.PORT} | Modèle: ${CONFIG.MODEL}`);
    log('INFO', `Clé API: ${CONFIG.API_KEY ? `${CONFIG.API_KEY.slice(0, 14)}...` : 'non configurée'}`);

    console.log(`\n✅ Claude Photo AI v2 prêt sur http://localhost:${CONFIG.PORT}`);
    console.log('   Modes disponibles : prompt | reference | both');
    console.log(`   Health check      : http://localhost:${CONFIG.PORT}/health\n`);
});

server.on('error', (error: NodeJS.ErrnoException) => {
    if (error.code === 'EADDRINUSE') {
        console.error(`\n❌ Port ${CONFIG.PORT} occupé — essayez: PORT=3001 yarn start`);
    } else {
        console.error('\n❌ Erreur serveur:', error.message);
    }
    process.exit(1);
});
