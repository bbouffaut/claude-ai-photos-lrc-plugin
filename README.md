# Claude Photo AI - Plugin Lightroom Classic

Développez vos photos avec l'intelligence artificielle : décrivez en langage naturel les modifications souhaitées, et Claude analyse votre photo puis génère automatiquement les réglages Lightroom.

---

## Structure des fichiers

```
ClaudePhoto.lrplugin/        ← Dossier du plugin (à installer dans Lightroom)
├── Info.lua                 ← Manifeste du plugin (version, menus)
└── ClaudePhotoMain.lua      ← Code principal (UI + workflow)

server/                      ← Serveur intermédiaire TypeScript
├── src/
│   ├── server.ts            ← Serveur HTTP local (pont vers l'API Claude)
│   └── test_api.ts          ← Script de test local
├── dist/                    ← JavaScript compilé (généré par `yarn build`)
├── package.json             ← Scripts Yarn
└── tsconfig.json            ← Configuration TypeScript

Makefile                     ← Commandes courantes pour lancer le serveur
```

---

## Prérequis

- **Lightroom Classic** 6.0 ou supérieur (CC ou version perpétuelle)
- **Node.js** 16+ (https://nodejs.org) — pour le serveur intermédiaire
- **Yarn** 1.x ou compatible
- **Clé API Anthropic** — https://console.anthropic.com

---

## Installation

### Étape 1 : Installer les dépendances du serveur

```bash
make install
```

Vous pouvez aussi lancer directement :

```bash
yarn --cwd server install
```

### Étape 2 : Démarrer le serveur local

Le plus simple :

```bash
cat > .env <<'EOF'
ANTHROPIC_API_KEY=sk-ant-votre-cle-ici
EOF

make dev
```

Le `Makefile` utilise `yarn` dans le dossier `server/`. Si vous préférez appeler les scripts vous-même :

```bash
cd server
yarn dev

# Vérifier que ça fonctionne
curl http://localhost:3000/health
```

Le serveur charge le fichier indiqué par la variable `ENV_FILE`. Si elle n'est pas définie, il charge `.env` depuis le répertoire courant. Il accepte `ANTHROPIC_API_KEY` et aussi `anthropic_key` pour compatibilité. Les variables déjà définies dans votre shell gardent la priorité.

Exemple avec un chemin personnalisé :

```bash
ENV_FILE=server/.env make dev
```

Pour lancer la version compilée localement :

```bash
make start
```

### Étape 3 : Installer le plugin dans Lightroom

1. Ouvrez Lightroom Classic
2. Menu **Fichier → Gestionnaire de modules externes**
3. Cliquez **Ajouter**
4. Naviguez jusqu'au dossier `ClaudePhoto.lrplugin` et sélectionnez-le
5. Cliquez **Ajouter le module externe**
6. Le plugin apparaît dans la liste — vérifiez qu'il est **activé** (coche verte)
7. Cliquez **Terminé**

### Étape 4 : Utiliser le plugin

1. Dans Lightroom, **sélectionnez une ou plusieurs photos** dans la Bibliothèque
2. Menu **Bibliothèque → Plugins → Développer avec Claude AI**
3. Entrez vos instructions en français (ou toute langue)
4. Cliquez **Analyser et Développer**
5. Les réglages sont appliqués automatiquement !

---

## Exemples de prompts

### Portraits
```
Rends ce portrait plus flatteur : peaux douces et naturelles, yeux très nets,
fond légèrement désaturé pour faire ressortir le sujet
```

### Paysages
```
Dramatise ce paysage : ciel très contrasté, récupère les détails dans les ombres,
sature légèrement les verts et les bleus, clarté maximale
```

### Style cinématique
```
Style film cinématographique : désature légèrement, refroidis les ombres vers 
le bleu/teal, réchauffe les hautes lumières vers l'orange, contraste doux
```

### Correction technique
```
Cette photo est surexposée d'environ 1.5 stops. Récupère les hautes lumières,
compense les ombres, et rétablis un blanc correct
```

### Noir et blanc
```
Convertis en noir et blanc expressif style Ansel Adams : ciel très sombre 
(filtre rouge simulé), peaux lumineuses, contraste élevé, forte clarté
```

### Ambiance vintage
```
Style photo vintage années 70 : vignettage prononcé, grain visible, 
tons chauds légèrement délavés, ombres remontées
```

---

## Développement local

Le `Makefile` expose les commandes les plus courantes :

```bash
make install   # installe les dépendances Yarn du serveur
make dev       # lance le serveur TypeScript en mode watch
make build     # compile TypeScript vers server/dist
make start     # compile puis lance la version JS compilée
make prod      # compile puis lance le serveur en mode production
make test      # exécute le script de test local
make health    # vérifie le endpoint /health
make clean     # supprime server/dist
```

Les scripts Yarn équivalents :

```bash
yarn --cwd server dev
yarn --cwd server build
yarn --cwd server start
yarn --cwd server test
yarn --cwd server typecheck
```

Exemple de fichier `.env` :

```dotenv
ANTHROPIC_API_KEY=sk-ant-votre-cle-ici
# ou
anthropic_key=sk-ant-votre-cle-ici
SERVER_URL=http://127.0.0.1:3000
# alias accepté aussi si besoin :
# SEVER_URL=http://127.0.0.1:3000
PORT=3000
```

---

## Configuration avancée

### Mode API directe (sans serveur)

Si vous ne voulez pas démarrer un serveur Node.js, vous pouvez configurer le plugin en mode "API directe" :

1. Dans la boîte de dialogue du plugin, cliquez **⚙ Configuration avancée**
2. Sélectionnez **API directe**
3. Entrez votre clé API Anthropic
4. La clé est sauvegardée dans les préférences Lightroom

> Note : Lightroom Classic a des limitations sur les requêtes HTTP très volumineuses.
> Pour les photos haute résolution, le serveur Node.js est recommandé.

### Changer l'URL du serveur

```bash
PORT=3001 make dev
```

Puis dans le plugin : Configuration avancée → URL complète du serveur → `http://localhost:3001`

### Logs du serveur

Les logs sont écrits dans `server/claude_photo_server.log`

---

## Tester sans Lightroom

Testez le serveur et l'API directement :

```bash
cd server

# Test avec une image réelle
yarn test prompt /path/to/photo.jpg "Style cinématique désaturé"

# Test basique (sans photo)
yarn test

# Equivalent via Makefile
make test prompt /path/to/photo.jpg "Style cinématique désaturé"

# Test via curl
curl -X POST http://localhost:3000/analyze-file \
  -H "Content-Type: application/json" \
  -d '{"imagePath": "/Users/vous/photo.jpg", "prompt": "Optimise cette photo"}'
```

---

## Format XMP généré

Claude génère des fichiers XMP Adobe Camera Raw compatibles avec Lightroom Classic 6+. Exemple de sortie :

```xml
<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
<rdf:Description rdf:about=''
  xmlns:crs='http://ns.adobe.com/camera-raw-settings/1.0/'
  crs:Version='14.4'
  crs:ProcessVersion='11.0'
  crs:WhiteBalance='Custom'
  crs:Temperature="5500"
  crs:Tint="5"
  crs:Exposure2012="-0.50"
  crs:Contrast2012="25"
  crs:Highlights2012="-40"
  crs:Shadows2012="20"
  crs:Whites2012="-10"
  crs:Blacks2012="-15"
  crs:Clarity2012="15"
  crs:Vibrance="10"
  crs:Saturation="5"
/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>
```

Vous pouvez aussi **glisser-déposer ce fichier .xmp directement dans Lightroom** ou l'appliquer manuellement via Développement → Copier les réglages.

---

## Dépannage

### "Impossible de contacter le serveur"
→ Vérifiez que `make dev` ou `yarn --cwd server dev` est bien en cours d'exécution
→ Testez : `curl http://localhost:3000/health`

### "Clé API manquante"
→ Ajoutez `ANTHROPIC_API_KEY` ou `anthropic_key` dans le fichier pointé par `ENV_FILE`
→ Ou utilisez `.env` à la racine du projet si `ENV_FILE` n'est pas défini
→ Ou définissez `ANTHROPIC_API_KEY` dans votre shell avant de lancer le serveur
→ Ou utilisez le mode API directe dans la configuration du plugin

### "Le XMP généré ne contient aucun paramètre"
→ Vérifiez votre clé API sur console.anthropic.com
→ Assurez-vous d'avoir du crédit disponible
→ Consultez les logs : `server/claude_photo_server.log`

### "Export JPEG échoué"
→ Vérifiez que Lightroom a accès en écriture au dossier temp
→ Essayez de réexporter manuellement la photo en JPEG

### Le plugin n'apparaît pas dans le menu
→ Rechargez les plugins : Fichier → Gestionnaire de modules → Recharger les modules

---

## Architecture technique

```
Lightroom Classic (Lua)
    │
    ├── Sélection photo(s)
    ├── Export JPEG temporaire (redimensionné max 1568px)  
    ├── Encodage base64
    ├── Requête HTTP POST → localhost:3000/analyze
    │
    ▼
Serveur Node.js / TypeScript (server/src/server.ts)
    │
    ├── Reçoit { image: "base64...", prompt: "..." }
    ├── Construit le message Claude (vision + texte)
    ├── POST → api.anthropic.com/v1/messages
    │
    ▼
Claude API (claude-sonnet-4-6)
    │
    ├── Analyse l'image
    ├── Comprend les instructions
    ├── Génère le XMP avec les réglages appropriés
    │
    ▼
Serveur Node.js
    │
    ├── Valide le XMP
    ├── Retourne le contenu XMP au plugin
    │
    ▼
Lightroom Classic
    ├── Parse le XMP
    ├── Applique les paramètres au développement
    └── Affiche les réglages dans le panneau Développement
```

---

## Licence

MIT — Libre d'utilisation et de modification.
Clé API Anthropic requise (tarification à l'usage sur console.anthropic.com).

*Développé avec Claude Opus — Anthropic*
