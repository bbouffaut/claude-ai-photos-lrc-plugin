#!/usr/bin/env node
/**
 * test_api.js — Script de test du serveur Claude Photo AI
 * 
 * Usage :
 *   node test_api.js                          # Test basique (image de placeholder)
 *   node test_api.js /path/to/photo.jpg       # Test avec votre photo
 *   node test_api.js /path/to/photo.jpg "Style cinématique désaturé"
 */

const https = require('https');
const http  = require('http');
const fs    = require('fs');
const path  = require('path');

const SERVER_URL = process.env.SERVER_URL || 'http://localhost:3000';
const API_KEY    = process.env.ANTHROPIC_API_KEY || '';

// Image JPEG minimale 1x1 pixel pour les tests sans photo réelle
const PLACEHOLDER_JPEG_BASE64 = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AJQAB/9k=';

async function testHealthCheck() {
    console.log('🔍 Test 1 : Health check...');
    
    return new Promise((resolve, reject) => {
        const url = new URL(SERVER_URL + '/health');
        const client = url.protocol === 'https:' ? https : http;
        
        client.get(SERVER_URL + '/health', (res) => {
            let data = '';
            res.on('data', chunk => { data += chunk; });
            res.on('end', () => {
                try {
                    const json = JSON.parse(data);
                    if (json.status === 'ok') {
                        console.log('   ✅ Serveur en ligne');
                        console.log(`   📦 Modèle: ${json.model}`);
                        console.log(`   🔑 Clé API configurée: ${json.hasApiKey ? 'oui' : 'non (à passer via X-API-Key)'}`);
                        resolve(true);
                    } else {
                        console.log('   ❌ Statut inattendu:', json);
                        resolve(false);
                    }
                } catch(e) {
                    console.log('   ❌ Réponse non-JSON:', data.substring(0, 200));
                    resolve(false);
                }
            });
        }).on('error', (e) => {
            console.log(`   ❌ Impossible de contacter le serveur: ${e.message}`);
            console.log('   → Assurez-vous que le serveur tourne: node server.js');
            resolve(false);
        });
    });
}

async function testAnalyze(imagePath, prompt) {
    console.log('\n🤖 Test 2 : Analyse et génération XMP...');
    
    let imageBase64;
    let imageDescription;
    
    if (imagePath && fs.existsSync(imagePath)) {
        console.log(`   📸 Photo: ${imagePath}`);
        const buffer = fs.readFileSync(imagePath);
        imageBase64 = buffer.toString('base64');
        imageDescription = path.basename(imagePath);
    } else {
        console.log('   📸 Utilisation d\'une image de test (1x1px)');
        imageBase64 = PLACEHOLDER_JPEG_BASE64;
        imageDescription = 'image_test.jpg';
    }
    
    const testPrompt = prompt || 'Optimise légèrement cette photo : améliore le contraste et la clarté, et réchauffe légèrement les tons';
    console.log(`   💬 Prompt: "${testPrompt}"`);
    
    const requestBody = JSON.stringify({
        image:  imageBase64,
        prompt: testPrompt,
    });
    
    return new Promise((resolve, reject) => {
        const urlObj  = new URL(SERVER_URL + '/analyze');
        const client  = urlObj.protocol === 'https:' ? https : http;
        
        const options = {
            hostname: urlObj.hostname,
            port:     urlObj.port || (urlObj.protocol === 'https:' ? 443 : 80),
            path:     '/analyze',
            method:   'POST',
            headers: {
                'Content-Type':   'application/json',
                'Content-Length': Buffer.byteLength(requestBody),
                ...(API_KEY ? { 'X-API-Key': API_KEY } : {}),
            }
        };
        
        const req = client.request(options, (res) => {
            let data = '';
            res.on('data', chunk => { data += chunk; });
            res.on('end', () => {
                if (res.statusCode === 200) {
                    console.log('   ✅ XMP généré avec succès !');
                    console.log(`   📄 Taille: ${data.length} caractères`);
                    
                    // Analyser le XMP reçu
                    const params = [];
                    const regex  = /crs:([A-Za-z0-9]+)="([^"]*)"/g;
                    let match;
                    while ((match = regex.exec(data)) !== null) {
                        // Ignorer les paramètres de métadonnées
                        if (!['Version', 'ProcessVersion', 'WhiteBalance'].includes(match[1])) {
                            params.push(`     ${match[1].padEnd(30)} = ${match[2]}`);
                        }
                    }
                    
                    if (params.length > 0) {
                        console.log('\n   📊 Paramètres générés par Claude :');
                        params.forEach(p => console.log(p));
                    }
                    
                    // Sauvegarder le XMP pour inspection
                    const outputPath = path.join(__dirname, 'test_output_claude.xmp');
                    fs.writeFileSync(outputPath, data, 'utf8');
                    console.log(`\n   💾 XMP sauvegardé: ${outputPath}`);
                    console.log('   → Glissez ce fichier dans Lightroom pour tester !');
                    
                    resolve(data);
                } else {
                    try {
                        const error = JSON.parse(data);
                        console.log(`   ❌ Erreur ${res.statusCode}: ${error.error}`);
                        if (error.suggestion) {
                            console.log(`   💡 Suggestion: ${error.suggestion}`);
                        }
                    } catch(e) {
                        console.log(`   ❌ Erreur ${res.statusCode}: ${data.substring(0, 300)}`);
                    }
                    resolve(null);
                }
            });
        });
        
        req.on('error', (e) => {
            console.log(`   ❌ Erreur: ${e.message}`);
            resolve(null);
        });
        
        req.setTimeout(130000, () => {
            req.destroy();
            console.log('   ❌ Timeout: pas de réponse après 130s');
            resolve(null);
        });
        
        req.write(requestBody);
        req.end();
    });
}

async function main() {
    console.log('╔══════════════════════════════════════╗');
    console.log('║  Claude Photo AI — Test du serveur   ║');
    console.log('╚══════════════════════════════════════╝\n');
    
    const imagePath = process.argv[2];
    const prompt    = process.argv[3];
    
    const serverOk = await testHealthCheck();
    if (!serverOk) {
        console.log('\n❌ Tests interrompus : serveur inaccessible');
        process.exit(1);
    }
    
    const xmp = await testAnalyze(imagePath, prompt);
    
    if (xmp) {
        console.log('\n🎉 Tous les tests réussis !');
        console.log('\nProchaines étapes :');
        console.log('  1. Installez le plugin dans Lightroom (Fichier → Gestionnaire de plugins)');
        console.log('  2. Sélectionnez des photos dans Lightroom');
        console.log('  3. Allez dans Bibliothèque → Plugins → Développer avec Claude AI');
    } else {
        console.log('\n⚠️  Le test d\'analyse a échoué.');
        console.log('   Vérifiez que votre clé API est correcte : export ANTHROPIC_API_KEY=sk-ant-...');
    }
}

main().catch(console.error);
