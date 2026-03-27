import https from 'https';

import { CONFIG } from './config';
import { log } from './logger';
import { AnalyzeMode, ClaudeApiResponse, ClaudeMessageContent } from './types';

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

    if (!xmp.includes('crs:')) {
        throw new Error('Le XMP généré ne contient aucun paramètre Camera Raw (crs:)');
    }

    if (!xmp.includes('<?xpacket')) {
        xmp = `<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>\n${xmp}`;
    }
    if (!xmp.includes("<?xpacket end='")) {
        xmp += `\n<?xpacket end='w'?>`;
    }

    return xmp;
};
