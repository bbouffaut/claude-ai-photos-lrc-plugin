import https from 'https';

import { CONFIG } from './config';
import { log } from './logger';
import { AnalyzeMode, ClaudeApiResponse, ClaudeMessageContent } from './types';

const SYSTEM_PROMPT = `Tu es un expert en post-traitement photographique et en Lightroom Classic / Adobe Camera Raw.

RÈGLES ABSOLUES :
1. Réponds UNIQUEMENT avec le contenu XML du fichier XMP — aucun texte avant ou après, pas de backticks
2. Le XMP doit être compatible Lightroom Classic 6+ (ProcessVersion 11.0)
3. Tu peux utiliser TOUTES les structures XMP réellement utiles et compatibles Lightroom Classic, pas seulement les attributs crs: simples
4. Tu peux inclure des réglages avancés si cela sert le rendu demandé : crop, géométrie, courbes, calibration, masques, calques / retouches locales, réglages IA et autres structures XMP avancées supportées par Lightroom Classic
5. N'inclus que les paramètres effectivement modifiés et utiles au résultat
6. Préfère des réglages crédibles, cohérents et compatibles Lightroom à des blocs inventés ou invalides

IMPORTANT :
- Ne te limite pas à la liste des paramètres classiques
- Si un ajustement nécessite une structure XMP imbriquée, des descriptions RDF supplémentaires, des masques, des corrections locales, du recadrage ou des réglages IA, inclus-les
- Utilise les noms, namespaces et structures XMP attendus par Lightroom Classic / Adobe Camera Raw
- N'invente jamais de syntaxe pseudo-XMP

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

const buildUserMessage = (mode: AnalyzeMode, prompt: string): string => {
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
    }
};

const buildClaudeContent = (
    imageBase64: string,
    referenceBase64: string | null,
    mode: AnalyzeMode,
    prompt: string,
): ClaudeMessageContent[] => {
    const content: ClaudeMessageContent[] = [
        {
            type: 'image',
            source: {
                type: 'base64',
                media_type: 'image/jpeg',
                data: imageBase64,
            },
        },
    ];

    if (referenceBase64 && (mode === 'reference' || mode === 'both')) {
        content.push({
            type: 'image',
            source: {
                type: 'base64',
                media_type: 'image/jpeg',
                data: referenceBase64,
            },
        });
    }

    content.push({
        type: 'text',
        text: buildUserMessage(mode, prompt),
    });

    return content;
};

export const callClaudeAPI = (
    imageBase64: string,
    referenceBase64: string | null,
    mode: AnalyzeMode,
    prompt: string,
    apiKey: string,
): Promise<string> =>
    new Promise((resolve, reject) => {
        const content = buildClaudeContent(imageBase64, referenceBase64, mode, prompt);
        const body = JSON.stringify({
            model: CONFIG.MODEL,
            max_tokens: CONFIG.MAX_TOKENS,
            system: SYSTEM_PROMPT,
            messages: [{ role: 'user', content }],
        });

        const req = https.request(
            {
                hostname: 'api.anthropic.com',
                port: 443,
                path: '/v1/messages',
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(body),
                    'x-api-key': apiKey,
                    'anthropic-version': '2023-06-01',
                },
            },
            (res) => {
                let data = '';
                res.on('data', (chunk: Buffer) => {
                    data += chunk.toString();
                });
                res.on('end', () => {
                    try {
                        const parsed = JSON.parse(data) as ClaudeApiResponse;
                        if (parsed.error) {
                            reject(new Error(`API error: ${parsed.error.message ?? JSON.stringify(parsed.error)}`));
                            return;
                        }

                        const text = parsed.content?.[0]?.text;
                        if (!text) {
                            reject(new Error('Réponse API vide ou malformée'));
                            return;
                        }

                        resolve(text);
                    } catch (error) {
                        const message = error instanceof Error ? error.message : String(error);
                        reject(new Error(`Erreur parsing réponse: ${message}\n${data.slice(0, 300)}`));
                    }
                });
            },
        );

        const numImages = mode === 'prompt' ? 1 : 2;
        log('INFO', `Appel API — modèle: ${CONFIG.MODEL}, mode: ${mode}, images: ${numImages}`);

        req.on('error', (error) => reject(new Error(`Erreur réseau: ${error.message}`)));
        req.setTimeout(150_000, () => {
            req.destroy();
            reject(new Error('Timeout 150s — API Claude sans réponse'));
        });

        req.write(body);
        req.end();
    });

export const validateAndCleanXMP = (raw: string): string => {
    let xmp = raw.replace(/```xml\n?/g, '').replace(/```\n?/g, '').trim();

    if (!xmp.includes('<rdf:Description') && !xmp.includes('<x:xmpmeta') && !xmp.includes('<?xpacket')) {
        throw new Error('Le contenu généré ne ressemble pas à un XMP Lightroom valide');
    }

    if (!xmp.includes('<?xpacket')) {
        xmp = `<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>\n${xmp}`;
    }
    if (!xmp.includes("<?xpacket end='")) {
        xmp += `\n<?xpacket end='w'?>`;
    }

    return xmp;
};
