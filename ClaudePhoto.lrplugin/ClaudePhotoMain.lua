--[[
    ClaudePhotoMain.lua  v2.0
    Plugin Claude Photo AI pour Lightroom Classic

    Nouveauté v2 : photo modèle dont le style est à reproduire.

    Modes disponibles :
      A) Prompt seul      — description textuelle des modifications
      B) Photo modèle     — reproduire le style d'une photo de référence (fichier disque)
      C) Les deux         — photo modèle + instructions complémentaires

    Workflow :
      1. Sélectionner des photos dans Lightroom
      2. Choisir le mode et remplir le formulaire
      3. Export JPEG temporaire de chaque photo à traiter
      4. Encodage base64 (photo + modèle si présent)
      5. Envoi au serveur Node.js / API Claude directe
      6. Réception du XMP, application dans Lightroom
--]]

local LrApplication       = import 'LrApplication'
local LrDialogs           = import 'LrDialogs'
local LrExportSession     = import 'LrExportSession'
local LrFileUtils         = import 'LrFileUtils'
local LrHttp              = import 'LrHttp'
local LrLogger            = import 'LrLogger'
local LrPathUtils         = import 'LrPathUtils'
local LrProgressScope     = import 'LrProgressScope'
local LrTasks             = import 'LrTasks'
local LrView              = import 'LrView'
local LrBinding           = import 'LrBinding'
local LrFunctionContext   = import 'LrFunctionContext'
local unpack              = unpack or table.unpack

local logger = LrLogger('ClaudePhotoPlugin')
logger:enable('logfile')
local logInfo, logWarn, logError

local function safeSnippet(value, limit)
    if value == nil then return "<nil>" end
    local s = tostring(value):gsub("[%c]+", " ")
    limit = limit or 200
    if #s > limit then
        s = s:sub(1, limit) .. "..."
    end
    return s
end

local function getDefaultDebugLogPath()
    local appData = LrPathUtils.getStandardFilePath('appData')
    if appData and appData ~= "" then
        local lightroomDir = LrPathUtils.child(appData, 'Adobe/Lightroom')
        if LrFileUtils.exists(lightroomDir) then
            return LrPathUtils.child(lightroomDir, 'ClaudePhoto_debug.log')
        end
    end

    local fallback = LrPathUtils.getStandardFilePath('temp')
    return LrPathUtils.child(fallback, 'ClaudePhoto_debug.log')
end

local function normalizeDebugLogPath(path)
    if not path then return "" end
    return path:gsub("^%s+", ""):gsub("%s+$", "")
end

local function getCacheDir()
    local appData = LrPathUtils.getStandardFilePath('appData')
    if appData and appData ~= "" then
        local lightroomDir = LrPathUtils.child(appData, 'Adobe/Lightroom')
        if LrFileUtils.exists(lightroomDir) then
            local cacheDir = LrPathUtils.child(lightroomDir, 'ClaudePhotoCache')
            if not LrFileUtils.exists(cacheDir) then
                LrFileUtils.createAllDirectories(cacheDir)
            end
            return cacheDir
        end
    end

    local fallback = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'ClaudePhotoCache')
    if not LrFileUtils.exists(fallback) then
        LrFileUtils.createAllDirectories(fallback)
    end
    return fallback
end

local function hashString(value)
    local hash = 2166136261
    for i = 1, #value do
        hash = (hash * 16777619) % 4294967296
        hash = (hash + value:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function buildCacheKey(photoPath, config)
    return table.concat({
        "photo=" .. tostring(photoPath or ""),
        "mode=" .. tostring(config.mode or ""),
        "prompt=" .. tostring(config.prompt or ""),
        "refPath=" .. tostring(config.refPath or ""),
    }, "\n")
end

local function getCacheFilePath(photoPath, config)
    return LrPathUtils.child(getCacheDir(), hashString(buildCacheKey(photoPath, config)) .. ".xmp")
end

local function getCachedXmp(photoPath, config)
    local cacheFile = getCacheFilePath(photoPath, config)
    if not LrFileUtils.exists(cacheFile) then
        return nil, cacheFile
    end

    local content = readFile(cacheFile)
    if content and content ~= "" then
        logInfo("Cache hit for photo=" .. tostring(photoPath) .. " -> " .. tostring(cacheFile))
        return content, cacheFile
    end

    logWarn("Cache file exists but is empty/unreadable: " .. tostring(cacheFile))
    return nil, cacheFile
end

local function saveCachedXmp(photoPath, config, xmpContent)
    local cacheFile = getCacheFilePath(photoPath, config)
    local f = io.open(cacheFile, "w")
    if not f then
        logWarn("Failed to open cache file for writing: " .. tostring(cacheFile))
        return cacheFile
    end
    f:write(xmpContent)
    f:close()
    logInfo("Cache stored for photo=" .. tostring(photoPath) .. " -> " .. tostring(cacheFile))
    return cacheFile
end

local function getDebugLogPath()
    local prefs = import 'LrPrefs'
    local p = prefs.prefsForPlugin()
    local configured = normalizeDebugLogPath(p.debugLogPath or "")
    if configured ~= "" then
        return configured
    end
    return getDefaultDebugLogPath()
end

local function appendDebugLog(line)
    local path = getDebugLogPath()
    local f = io.open(path, "a")
    if not f then
        local fallback = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'ClaudePhoto_debug.log')
        if fallback ~= path then
            f = io.open(fallback, "a")
        end
    end
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(line) .. "\n")
    f:close()
end

logInfo = function(message)
    local line = "[ClaudePhoto] " .. tostring(message)
    logger:info(line)
    appendDebugLog(line)
end

logWarn = function(message)
    local line = "[ClaudePhoto] " .. tostring(message)
    if logger.warn then
        logger:warn(line)
    else
        logger:info(line)
    end
    appendDebugLog(line)
end

logError = function(message)
    local line = "[ClaudePhoto] " .. tostring(message)
    logger:error(line)
    appendDebugLog(line)
end

-- ============================================================
-- Configuration
-- ============================================================
local CONFIG = {
    SERVER_URL     = "http://localhost:3000",
    DIRECT_API     = false,
    MAX_IMAGE_SIZE = 1568,   -- px, cote long de la photo a traiter
    MAX_REF_SIZE   = 1024,   -- px, cote long de la photo modele
    JPEG_QUALITY   = 85,
    HTTP_TIMEOUT   = 150,
}

-- ============================================================
-- Preferences persistantes
-- ============================================================
local function getPrefs()
    local prefs = import 'LrPrefs'
    local p = prefs.prefsForPlugin()
    local values = {
        apiKey      = p.apiKey      or "",
        serverUrl   = p.serverUrl   or CONFIG.SERVER_URL,
        directApi   = p.directApi   or false,
        lastRefPath = p.lastRefPath or "",
        lastMode    = p.lastMode    or "prompt",
        debugLogPath = normalizeDebugLogPath(p.debugLogPath or ""),
    }
    logInfo("Prefs loaded: mode=" .. tostring(values.lastMode)
        .. ", directApi=" .. tostring(values.directApi)
        .. ", serverUrl=" .. safeSnippet(values.serverUrl, 120)
        .. ", hasApiKey=" .. tostring(values.apiKey ~= "")
        .. ", refPath=" .. safeSnippet(values.lastRefPath, 180)
        .. ", debugLogPath=" .. safeSnippet(values.debugLogPath ~= "" and values.debugLogPath or getDefaultDebugLogPath(), 220))
    return values
end

local function savePrefs(t)
    local prefs = import 'LrPrefs'
    local p = prefs.prefsForPlugin()
    p.apiKey      = t.apiKey
    p.serverUrl   = t.serverUrl
    p.directApi   = t.directApi
    p.lastRefPath = t.lastRefPath or ""
    p.lastMode    = t.lastMode    or "prompt"
    p.debugLogPath = normalizeDebugLogPath(t.debugLogPath or "")
    logInfo("Prefs saved: mode=" .. tostring(t.lastMode)
        .. ", directApi=" .. tostring(t.directApi)
        .. ", serverUrl=" .. safeSnippet(t.serverUrl, 120)
        .. ", hasApiKey=" .. tostring((t.apiKey or "") ~= "")
        .. ", refPath=" .. safeSnippet(t.lastRefPath, 180)
        .. ", debugLogPath=" .. safeSnippet(((t.debugLogPath or "") ~= "" and t.debugLogPath) or getDefaultDebugLogPath(), 220))
end

-- ============================================================
-- Utilitaires fichiers
-- ============================================================
local function getTempDir()
    local base = LrPathUtils.getStandardFilePath('temp')
    local dir  = LrPathUtils.child(base, 'ClaudePhoto_' .. tostring(os.time()))
    LrFileUtils.createDirectory(dir)
    logInfo("Temp dir created: " .. tostring(dir))
    return dir
end

local function cleanTempDir(dir)
    if dir and LrFileUtils.exists(dir) then
        logInfo("Cleaning temp dir: " .. tostring(dir))
        LrFileUtils.delete(dir)
    end
end

local function writeFile(path, content)
    logInfo("Writing file: " .. tostring(path) .. " (" .. tostring(content and #content or 0) .. " chars)")
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function normalizeServerUrl(url)
    if not url then return "" end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    url = url:gsub("/+$", "")
    return url
end

local function isValidServerUrl(url)
    url = normalizeServerUrl(url)
    return url ~= "" and (url:match("^https?://") ~= nil)
end

-- Encodage base64 via commande systeme
local function fileToBase64(filePath)
    logInfo("Encoding file to base64: " .. tostring(filePath))
    local cmd
    if WIN_ENV then
        cmd = string.format(
            'powershell -Command "[Convert]::ToBase64String([IO.File]::ReadAllBytes(\'%s\'))"',
            filePath)
    else
        cmd = string.format('base64 -i "%s"', filePath)
    end
    local handle = io.popen(cmd)
    if not handle then
        logError("fileToBase64: io.popen failed for " .. tostring(filePath))
        return nil, "Impossible d'encoder l'image"
    end
    local result = handle:read("*a")
    handle:close()
    result = result:gsub("%s+", "")
    if #result < 100 then
        logError("fileToBase64: output too short for " .. tostring(filePath) .. " (" .. tostring(#result) .. " chars)")
        return nil, "Base64 vide ou trop court"
    end
    logInfo("Base64 encoded: " .. tostring(filePath) .. " (" .. tostring(#result) .. " chars)")
    return result
end

-- Convertir/redimensionner n'importe quelle image en JPEG temporaire
-- Supporte JPEG, PNG, TIFF, et RAW via sips (macOS) ou magick (Windows/Linux)
local function convertImageToJpeg(srcPath, outputDir, maxSize)
    local ext      = LrPathUtils.extension(srcPath):lower()
    local baseName = LrPathUtils.removeExtension(LrPathUtils.leafName(srcPath))
    local outPath  = LrPathUtils.child(outputDir, baseName .. '_ref.jpg')

    logInfo("Converting reference image to JPEG: src=" .. tostring(srcPath)
        .. ", ext=" .. tostring(ext)
        .. ", maxSize=" .. tostring(maxSize)
        .. ", out=" .. tostring(outPath))

    local cmd
    if WIN_ENV then
        -- ImageMagick (Windows) - a installer separement
        cmd = string.format('magick "%s" -resize %dx%d> -quality 85 "%s" 2>nul',
            srcPath, maxSize, maxSize, outPath)
        logInfo("convertImageToJpeg command: " .. safeSnippet(cmd, 220))
        local ok = os.execute(cmd)
        if not ok or not LrFileUtils.exists(outPath) then
            -- Fallback PowerShell pour JPEG/PNG
            cmd = string.format(
                'powershell -Command "Add-Type -AssemblyName System.Drawing; ' ..
                '$img=[System.Drawing.Image]::FromFile(\'%s\'); ' ..
                '$r=[Math]::Min(%d/$img.Width,%d/$img.Height); ' ..
                'if($r -lt 1){ $w=[int]($img.Width*$r); $h=[int]($img.Height*$r) }' ..
                'else{ $w=$img.Width; $h=$img.Height }; ' ..
                '$b=New-Object System.Drawing.Bitmap $w,$h; ' ..
                '$g=[System.Drawing.Graphics]::FromImage($b); ' ..
                '$g.DrawImage($img,0,0,$w,$h); ' ..
                '$b.Save(\'%s\',[System.Drawing.Imaging.ImageFormat]::Jpeg)"',
                srcPath, maxSize, maxSize, outPath)
            logWarn("Primary conversion failed, trying PowerShell fallback")
            logInfo("convertImageToJpeg fallback command: " .. safeSnippet(cmd, 220))
            os.execute(cmd)
        end
    else
        -- macOS : sips est integre et gere JPEG, PNG, TIFF, RAW Apple, BMP, GIF
        cmd = string.format(
            'sips -Z %d --setProperty format jpeg "%s" --out "%s" 2>/dev/null',
            maxSize, srcPath, outPath)
        logInfo("convertImageToJpeg command: " .. safeSnippet(cmd, 220))
        local ok = os.execute(cmd)
        -- Pour les RAW non Apple (Nikon NEF, Sony ARW, etc.), sips echoue
        -- Fallback : dcraw ou rawtherapee si disponibles
        if not ok or not LrFileUtils.exists(outPath) then
            cmd = string.format(
                'dcraw -c -w -T "%s" | sips -Z %d --setProperty format jpeg - --out "%s" 2>/dev/null',
                srcPath, maxSize, outPath)
            logWarn("Primary conversion failed, trying dcraw fallback")
            logInfo("convertImageToJpeg fallback command: " .. safeSnippet(cmd, 220))
            os.execute(cmd)
        end
        if not LrFileUtils.exists(outPath) then
            -- Dernier recours : copie directe (si c'est un JPEG mal detecte)
            logWarn("Fallback conversion failed, trying direct copy to " .. tostring(outPath))
            LrFileUtils.copy(srcPath, outPath)
        end
    end

    if LrFileUtils.exists(outPath) then
        logInfo("Reference image converted successfully: " .. tostring(outPath))
        return outPath
    end
    logError("Reference image conversion failed: src=" .. tostring(srcPath))
    return nil, "Impossible de convertir la photo modele en JPEG (format non supporte ?)"
end

-- ============================================================
-- Export JPEG depuis Lightroom (photo a developper)
-- ============================================================
local function exportPhotoToJpeg(photo, outputDir, maxSize)
    maxSize = maxSize or CONFIG.MAX_IMAGE_SIZE
    local photoPath = photo:getRawMetadata('path')
    logInfo("Exporting photo to JPEG: " .. tostring(photoPath)
        .. ", outputDir=" .. tostring(outputDir)
        .. ", maxSize=" .. tostring(maxSize))
    local exportSettings = {
        LR_export_destinationType       = "specificFolder",
        LR_export_destinationPathPrefix = outputDir,
        LR_export_useSubfolder          = false,
        LR_format                       = "JPEG",
        LR_jpeg_quality                 = CONFIG.JPEG_QUALITY / 100,
        LR_minimizeEmbeddedMetadata     = true,
        LR_outputSharpeningOn           = false,
        LR_size_doConstrain             = true,
        LR_size_maxHeight               = maxSize,
        LR_size_maxWidth                = maxSize,
        LR_size_resizeType              = "longEdge",
        LR_size_units                   = "pixels",
        LR_removeLocationMetadata       = false,
        LR_useWatermark                 = false,
        LR_export_colorSpace            = "sRGB",
        LR_collisionHandling            = "rename",
        LR_extensionCase                = "lowercase",
    }

    local exportSession = LrExportSession({
        photosToExport = { photo },
        exportSettings = exportSettings,
    })

    local errorMsg
    local exportedPath

    for _, rendition in exportSession:renditions { stopIfCanceled = true } do
        local success, pathOrMessage = rendition:waitForRender()
        if success then
            exportedPath = pathOrMessage
            logInfo("Export produced file: " .. tostring(exportedPath))
        else
            errorMsg = pathOrMessage or "Export echoue"
            logError("Export failed for " .. tostring(photoPath) .. ": " .. tostring(errorMsg))
        end
    end

    if exportedPath and LrFileUtils.exists(exportedPath) then
        logInfo("Export succeeded for " .. tostring(photoPath) .. ": " .. tostring(exportedPath))
        return exportedPath
    end

    logError("Export did not produce a file for " .. tostring(photoPath) .. ": " .. tostring(errorMsg or "Aucune photo exportee"))
    return nil, errorMsg or "Aucune photo exportee"
end

-- ============================================================
-- Prompts Claude selon le mode
-- ============================================================
local SYSTEM_PROMPT = [[Tu es un expert en post-traitement photographique et en Lightroom Classic / Adobe Camera Raw.

REGLES ABSOLUES :
1. Reponds UNIQUEMENT avec le contenu XML du fichier XMP — aucun texte avant ou apres, pas de backticks
2. Le XMP doit etre compatible Lightroom Classic 6+ (ProcessVersion 11.0)
3. Tu peux utiliser TOUTES les structures XMP reellement utiles et compatibles Lightroom Classic, pas seulement les attributs crs: simples
4. Tu peux inclure des reglages avances si cela sert le rendu demande : crop, geometrie, courbes, calibration, masques, calques / retouches locales, reglages IA et autres structures XMP avancees supportees par Lightroom Classic
5. N'inclus que les parametres effectivement modifies et utiles au resultat
6. Prefere des reglages credibles, coherents et compatibles Lightroom a des blocs inventes ou invalides

IMPORTANT :
- Ne te limite pas a la liste des parametres classiques
- Si un ajustement necessite une structure XMP imbriquee, des descriptions RDF supplementaires, des masques, des corrections locales, du recadrage ou des reglages IA, inclus-les
- Utilise les noms, namespaces et structures XMP attendus par Lightroom Classic / Adobe Camera Raw
- N'invente jamais de syntaxe pseudo-XMP

FORMAT DE SORTIE OBLIGATOIRE :
<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
<rdf:Description rdf:about=''
  xmlns:crs='http://ns.adobe.com/camera-raw-settings/1.0/'
  crs:Version='14.4'
  crs:ProcessVersion='11.0'
  crs:WhiteBalance='Custom'
  [PARAMETRES]
/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>]]

-- Message utilisateur selon le mode
local function buildUserMessage(mode, userPrompt)
    if mode == "prompt" then
        return string.format(
            "Voici la photo a developper.\n\nInstructions : %s",
            userPrompt or "")

    elseif mode == "reference" then
        return [[La PREMIERE IMAGE est la photo a developper.
La DEUXIEME IMAGE est la photo modele dont tu dois analyser et reproduire le style.

Analyse minutieusement la photo modele :
- Balance des blancs et temperature de couleur
- Exposition globale et gestion des hautes lumieres / ombres
- Contraste general et courbe de tonalite
- Vibrance, saturation, palette de couleurs dominante
- Eventuels ajustements HSL (decalages de teinte, boost ou reduction de certaines couleurs)
- Grain, vignettage, effets de style
- Regard artistique general : style chaud/froid, lave/sature, lumineux/sombre

Genere un XMP qui transpose fidelement ce style sur la premiere photo,
en tenant compte de ses caracteristiques propres (exposition native, dominante couleur, etc.)
pour que le resultat soit naturel et coherent.]]

    elseif mode == "both" then
        return string.format(
            [[La PREMIERE IMAGE est la photo a developper.
La DEUXIEME IMAGE est la photo modele dont tu dois t'inspirer pour le style general.

Reproduis le style global de la photo modele (balance des blancs, contraste, palette,
gestion des hautes lumieres et ombres, effets eventuels), PUIS applique ces ajustements
complementaires par-dessus :

%s

Si les instructions complementaires contredisent le style modele sur un point precis,
les instructions ont la priorite sur ce point uniquement.]],
            userPrompt or "")
    end

    return "Optimise cette photo."
end

-- ============================================================
-- JSON escape minimal
-- ============================================================
local function jsonEscape(s)
    if not s then return "" end
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"',  '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

local function isLikelyXmp(content)
    if not content then return false end
    return content:find("<?xpacket", 1, true)
        or content:find("<x:xmpmeta", 1, true)
        or content:find("<rdf:Description", 1, true)
end

-- ============================================================
-- Appel API directe
-- ============================================================
local function callClaudeDirectly(imageBase64, refBase64, mode, userPrompt, apiKey)
    local url = "https://api.anthropic.com/v1/messages"
    logInfo("Calling Claude direct API: mode=" .. tostring(mode)
        .. ", imageB64=" .. tostring(imageBase64 and #imageBase64 or 0)
        .. ", refB64=" .. tostring(refBase64 and #refBase64 or 0)
        .. ", promptLen=" .. tostring(userPrompt and #userPrompt or 0)
        .. ", hasApiKey=" .. tostring(apiKey and apiKey ~= ""))

    -- Construction du contenu multi-images
    local contentParts = {}

    -- Image 1 : photo a traiter
    table.insert(contentParts, string.format(
        '{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"%s"}}',
        imageBase64))

    -- Image 2 : photo modele (si applicable)
    if refBase64 and (mode == "reference" or mode == "both") then
        table.insert(contentParts, string.format(
            '{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"%s"}}',
            refBase64))
    end

    -- Message texte
    local msg = buildUserMessage(mode, userPrompt)
    table.insert(contentParts, string.format('{"type":"text","text":"%s"}', jsonEscape(msg)))

    local jsonBody = string.format(
        '{"model":"claude-sonnet-4-6","max_tokens":2048,"system":"%s","messages":[{"role":"user","content":[%s]}]}',
        jsonEscape(SYSTEM_PROMPT),
        table.concat(contentParts, ","))

    local headers = {
        { field = "Content-Type",      value = "application/json" },
        { field = "x-api-key",         value = apiKey },
        { field = "anthropic-version", value = "2023-06-01" },
    }

    local result = LrHttp.post(url, jsonBody, headers, "POST", CONFIG.HTTP_TIMEOUT)
    if not result then
        logError("Direct API call failed: no response from " .. tostring(url))
        return nil, "Erreur reseau : impossible de contacter l'API Claude"
    end
    logInfo("Direct API raw response snippet: " .. safeSnippet(result, 400))

    -- Extraction du texte XMP depuis la reponse JSON
    local xmpContent = result:match('"text"%s*:%s*"(.-[^\\])"')
    if not xmpContent then
        xmpContent = result:match('"text":"(.+)"')
    end
    if not xmpContent then
        logError("Direct API unexpected response: " .. safeSnippet(result, 500))
        return nil, "Reponse Claude non parsable. Verifiez la cle API.\n" .. result:sub(1, 200)
    end

    xmpContent = xmpContent:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\t','\t'):gsub('\\r','\r'):gsub('\\\\','\\')
    logInfo("Direct API extracted XMP snippet: " .. safeSnippet(xmpContent, 300))
    return xmpContent
end

-- ============================================================
-- Appel via serveur Node.js
-- ============================================================
local function callClaudeViaServer(imageBase64, refBase64, mode, userPrompt, serverUrl)
    local normalizedServerUrl = normalizeServerUrl(serverUrl)
    local url = normalizedServerUrl .. "/analyze"
    logInfo("Calling local server: url=" .. tostring(url)
        .. ", mode=" .. tostring(mode)
        .. ", imageB64=" .. tostring(imageBase64 and #imageBase64 or 0)
        .. ", refB64=" .. tostring(refBase64 and #refBase64 or 0)
        .. ", promptLen=" .. tostring(userPrompt and #userPrompt or 0))

    local parts = {
        string.format('"image":"%s"', imageBase64),
        string.format('"mode":"%s"', jsonEscape(mode)),
        string.format('"prompt":"%s"', jsonEscape(userPrompt or "")),
    }
    if refBase64 and (mode == "reference" or mode == "both") then
        table.insert(parts, string.format('"reference":"%s"', refBase64))
    end

    local jsonBody = "{" .. table.concat(parts, ",") .. "}"

    local headers = {
        { field = "Content-Type", value = "application/json" },
    }

    local result = LrHttp.post(url, jsonBody, headers, "POST", CONFIG.HTTP_TIMEOUT)
    if not result then
        logError("Local server call failed: no response from " .. tostring(url))
        return nil, "Impossible de contacter le serveur : " .. normalizedServerUrl
    end
    logInfo("Local server raw response snippet: " .. safeSnippet(result, 400))

    -- Reponse XMP directe
    if isLikelyXmp(result) then
        logInfo("Local server returned direct XMP")
        return result
    end

    -- Reponse JSON enveloppee
    local xmp = result:match('"xmp"%s*:%s*"(.-[^\\])"')
    if xmp then
        xmp = xmp:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\\\','\\')
        logInfo("Local server returned wrapped XMP snippet: " .. safeSnippet(xmp, 300))
        return xmp
    end

    local errMsg = result:match('"error"%s*:%s*"(.-)"')
    logError("Local server returned error/unexpected payload: " .. safeSnippet(errMsg or result, 300))
    return nil, errMsg or ("Reponse inattendue du serveur : " .. result:sub(1, 300))
end

-- ============================================================
-- Application du XMP a la photo Lightroom
-- ============================================================
function parseXmpToParams(xmpContent)
    local params = {}
    for name, value in xmpContent:gmatch('crs:([%w]+)%s*=%s*"([^"]*)"') do
        params[name] = tonumber(value) or value
    end
    for name, value in xmpContent:gmatch("crs:([%w]+)%s*=%s*'([^']*)'") do
        params[name] = tonumber(value) or value
    end
    local count = 0
    for _ in pairs(params) do count = count + 1 end
    logInfo("Parsed XMP params: " .. tostring(count))
    if count == 0 then
        logWarn("No parsable crs:* attributes found in XMP snippet: " .. safeSnippet(xmpContent, 400))
    end
    return params
end

local function applyXmpToPhoto(photo, xmpContent, tmpDir)
    local photoName = LrPathUtils.leafName(photo:getRawMetadata('path'))
    local baseName  = LrPathUtils.removeExtension(photoName)
    local xmpPath   = LrPathUtils.child(tmpDir, baseName .. '_claude.xmp')
    logInfo("Applying XMP to photo: " .. tostring(photoName) .. ", xmpPath=" .. tostring(xmpPath))

    if not writeFile(xmpPath, xmpContent) then
        logError("Failed to write temporary XMP: " .. tostring(xmpPath))
        return false, "Impossible d'ecrire le XMP temporaire", xmpPath
    end

    local catalog = LrApplication.activeCatalog()
    local success = false
    local errorMsg

    catalog:withWriteAccessDo("Appliquer reglages Claude AI", function()
        local params = parseXmpToParams(xmpContent)
        if params and next(params) then
            local applyParams = {}
            local paramNames = {}
            for name, value in pairs(params) do
                if name ~= "Version" and name ~= "ProcessVersion" and name ~= "WhiteBalance" then
                    applyParams[name] = value
                    table.insert(paramNames, name)
                end
            end

            table.sort(paramNames)
            logInfo("Attempting develop apply for " .. tostring(photoName)
                .. " with " .. tostring(#paramNames) .. " param(s): "
                .. safeSnippet(table.concat(paramNames, ", "), 350))

            local batchOk, batchErr = LrTasks.pcall(function()
                photo:applyDevelopSettings(applyParams)
            end)

            if batchOk then
                logInfo("Batch applyDevelopSettings succeeded for " .. tostring(photoName)
                    .. " with " .. tostring(#paramNames) .. " param(s)")
                success = true
            else
                local appliedCount = 0
                logWarn("Batch applyDevelopSettings failed for " .. tostring(photoName)
                    .. ": " .. safeSnippet(batchErr, 220)
                    .. ". Falling back to per-parameter apply.")

                for _, name in ipairs(paramNames) do
                    local value = applyParams[name]
                    local ok, err = LrTasks.pcall(function()
                        photo:applyDevelopSettings({ [name] = value })
                    end)
                    if ok then
                        appliedCount = appliedCount + 1
                        logInfo("Applied param for " .. tostring(photoName)
                            .. ": " .. tostring(name) .. "=" .. safeSnippet(value, 80))
                    else
                        logWarn("applyDevelopSettings failed for " .. tostring(photoName)
                            .. ", param=" .. tostring(name) .. ", value=" .. safeSnippet(value, 80)
                            .. ", err=" .. safeSnippet(err, 180))
                    end
                end

                logInfo("Applied develop settings to " .. tostring(photoName) .. ": " .. tostring(appliedCount) .. " param(s)")
                if appliedCount > 0 then
                    success = true
                else
                    errorMsg = "Aucun parametre Lightroom applicable dans le XMP recu"
                    logError("No develop parameters could be applied for " .. tostring(photoName))
                end
            end
        else
            -- Fallback XMP sidecar
            local originalPath = photo:getRawMetadata('path')
            local sidecar = LrPathUtils.removeExtension(originalPath) .. '.xmp'
            logWarn("No direct params parsed, trying sidecar fallback: " .. tostring(sidecar))
            if LrFileUtils.exists(sidecar) then
                logInfo("Existing sidecar found, deleting before overwrite: " .. tostring(sidecar))
                LrFileUtils.delete(sidecar)
            end

            local sidecarOk = writeFile(sidecar, xmpContent)
            if sidecarOk then
                catalog:autoSyncPhotos(false)
                photo:readMetadataFromXmp()
                logInfo("Sidecar fallback applied successfully: " .. tostring(sidecar))
                success = true
            else
                errorMsg = "Impossible de creer le XMP sidecar"
                logError("Sidecar fallback failed: " .. tostring(sidecar)
                    .. ", parentExists=" .. tostring(LrFileUtils.exists(LrPathUtils.parent(sidecar)))
                    .. ", tempXmpExists=" .. tostring(LrFileUtils.exists(xmpPath)))
            end
        end
    end, { timeout = 30 })

    if success then
        logInfo("XMP applied successfully to " .. tostring(photoName))
    else
        logError("XMP apply failed for " .. tostring(photoName) .. ": " .. tostring(errorMsg))
    end
    return success, errorMsg, xmpPath
end

-- ============================================================
-- Dialogue principal v2
-- ============================================================
local function showMainDialog(photos)
    return LrFunctionContext.callWithContext("showMainDialog", function(context)
        local prefs = getPrefs()
        local f     = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        logInfo("Opening main dialog for " .. tostring(#photos) .. " selected photo(s)")

        props.mode         = prefs.lastMode or "prompt"
        props.prompt       = "Rends cette photo plus chaleureuse et dramatique"
        props.refPath      = prefs.lastRefPath or ""
        props.directApi    = prefs.directApi
        props.apiKey       = prefs.apiKey
        props.serverUrl    = prefs.serverUrl
        props.showAdvanced = false
        props.debugLogPath = prefs.debugLogPath ~= "" and prefs.debugLogPath or getDefaultDebugLogPath()

        local suggestions = {
            "Style cinematique : desaturation douce, ombres bleutees, hautes lumieres chaudes (teal & orange)",
            "Portrait naturel : peaux veloutees, yeux tres nets, fond desature pour isoler le sujet",
            "Paysage dramatique : ciel contraste, hautes lumieres recuperees, vibrance et clarte elevees",
            "Golden hour : tons tres chauds, ombres remontees, contraste doux et lumineux",
            "Noir et blanc expressif : fort contraste, grain subtil, courbe en S marquee",
            "Style film vintage : vignettage, grain, teintes delavees, ombres tirant vers le marron",
            "Correction minimale : exposition +0.5 stop, recup hautes lumieres, reduction bruit",
        }

        local function validateRef(p)
            return p and p ~= "" and LrFileUtils.exists(p)
        end

        local function browseForRef()
            logInfo("Opening file picker for reference image")
            local paths = LrDialogs.runOpenPanel {
                title                   = "Choisir la photo modele",
                canChooseFiles          = true,
                canChooseDirectories    = false,
                allowsMultipleSelection = false,
                fileTypes               = { "jpg","jpeg","png","tif","tiff","bmp",
                                            "nef","cr2","cr3","arw","dng","raf","rw2","orf","pef","srw" },
            }
            if paths and #paths > 0 then
                props.refPath = paths[1]
                logInfo("Reference image selected: " .. tostring(props.refPath))
            else
                logInfo("Reference image selection cancelled")
            end
        end

        local contents = f:column {
            spacing = f:dialog_spacing(),
            bind_to_object = props,

        -- En-tete
        f:row {
            f:static_text {
                title = "Claude Photo AI  v2",
                font  = "<system/bold>",
                fill_horizontal = 1,
            },
            f:static_text {
                title = string.format("%d photo(s)", #photos),
                font  = "<system/small>",
            },
        },

        f:separator { fill_horizontal = 1 },

        -- Choix du mode
        f:group_box {
            title = "Mode de developpement",
            f:column {
                spacing = f:label_spacing(),
                f:radio_button {
                    title         = "Instructions textuelles",
                    checked_value = "prompt",
                    value         = LrView.bind('mode'),
                },
                f:radio_button {
                    title         = "Photo modele — reproduire son style",
                    checked_value = "reference",
                    value         = LrView.bind('mode'),
                },
                f:radio_button {
                    title         = "Photo modele + instructions complementaires",
                    checked_value = "both",
                    value         = LrView.bind('mode'),
                },
            },
        },

        -- Bloc photo modele
        f:group_box {
            title   = "Photo modele",
            visible = LrView.bind {
                key = 'mode',
                transform = function(value) return value ~= "prompt" end,
            },
            f:column {
                spacing = f:label_spacing(),
                f:static_text {
                    title = "Selectionnez l'image dont le style sera analyse et reproduit :",
                    font  = "<system/small>",
                },
                f:row {
                    f:edit_field {
                        value          = LrView.bind('refPath'),
                        width_in_chars = 42,
                        immediate      = true,
                    },
                    f:push_button {
                        title  = "Parcourir...",
                        action = browseForRef,
                    },
                },
                f:row {
                    f:static_text {
                        title = LrView.bind {
                            key = 'refPath',
                            transform = function(p)
                                if not p or p == "" then
                                    return "Aucun fichier selectionne"
                                elseif LrFileUtils.exists(p) then
                                    return "OK : " .. LrPathUtils.leafName(p)
                                else
                                    return "Fichier introuvable : " .. p
                                end
                            end,
                        },
                        font = "<system/small>",
                    },
                },
                f:static_text {
                    title = "Formats : JPEG, PNG, TIFF, RAW (NEF/CR2/CR3/ARW/DNG/RAF...)",
                    font  = "<system/small>",
                },
            },
        },

        -- Bloc instructions texte
        f:group_box {
            title   = "Instructions",
            visible = LrView.bind {
                key = 'mode',
                transform = function(value) return value ~= "reference" end,
            },
            f:column {
                spacing = f:label_spacing(),
                f:static_text {
                    title = "Decrivez les modifications souhaitees :",
                    font  = "<system/small>",
                },
                f:edit_field {
                    value           = LrView.bind('prompt'),
                    width_in_chars  = 55,
                    height_in_lines = 3,
                    wraps           = true,
                },
                f:static_text {
                    title = "Suggestions :",
                    font  = "<system/small>",
                },
                f:column {
                    spacing = f:label_spacing(),
                    (function()
                        local btns = {}
                        for _, s in ipairs(suggestions) do
                            local lbl = #s > 68 and s:sub(1, 65) .. "..." or s
                            table.insert(btns, f:push_button {
                                title  = lbl,
                                font   = "<system/small>",
                                action = function() props.prompt = s end,
                            })
                        end
                        return unpack(btns)
                    end)()
                },
            },
        },

        f:separator { fill_horizontal = 1 },

        -- Config avancee
        f:push_button {
            title  = "Configuration avancee",
            action = function() props.showAdvanced = not props.showAdvanced end,
        },

        f:group_box {
            title   = "API",
            visible = LrView.bind('showAdvanced'),
            f:column {
                spacing = f:label_spacing(),
                f:radio_button {
                    title         = "Serveur local Node.js (recommande)",
                    checked_value = false,
                    value         = LrView.bind('directApi'),
                },
                f:radio_button {
                    title         = "Appel API direct",
                    checked_value = true,
                    value         = LrView.bind('directApi'),
                },
                f:row {
                    visible = LrView.bind {
                        key = 'directApi',
                        transform = function(value) return not value end,
                    },
                    f:static_text { title = "URL complete du serveur :", width = 140 },
                    f:edit_field { value = LrView.bind('serverUrl'), width_in_chars = 35 },
                },
                f:static_text {
                    visible = LrView.bind {
                        key = 'directApi',
                        transform = function(value) return not value end,
                    },
                    title = "Exemple : http://localhost:3000",
                    font  = "<system/small>",
                },
                f:row {
                    visible = LrView.bind('directApi'),
                    f:static_text { title = "Cle API Claude :", width = 140 },
                    f:password_field { value = LrView.bind('apiKey'), width_in_chars = 35 },
                },
                f:separator { fill_horizontal = 1 },
                f:row {
                    f:static_text { title = "Fichier de log :", width = 140 },
                    f:edit_field { value = LrView.bind('debugLogPath'), width_in_chars = 35 },
                },
                f:static_text {
                    title = "Laissez vide pour utiliser : " .. getDefaultDebugLogPath(),
                    font  = "<system/small>",
                },
            },
        },
        }

        local result = LrDialogs.presentModalDialog {
            title      = "Claude Photo AI  v2",
            contents   = contents,
            actionVerb = "Analyser et Developper",
            cancelVerb = "Annuler",
        }
        logInfo("Main dialog closed with result=" .. tostring(result))

        if result ~= 'ok' then return nil end

        local mode = props.mode

        -- Validations
        if mode == "reference" or mode == "both" then
            if not props.refPath or props.refPath == "" then
                logWarn("Validation failed: missing reference image")
                LrDialogs.message("Erreur", "Selectionnez une photo modele.", "critical")
                return nil
            end
            if not LrFileUtils.exists(props.refPath) then
                logWarn("Validation failed: reference image missing on disk: " .. tostring(props.refPath))
                LrDialogs.message("Erreur", "Photo modele introuvable :\n" .. props.refPath, "critical")
                return nil
            end
        end
        if mode == "prompt" or mode == "both" then
            if not props.prompt or props.prompt:match("^%s*$") then
                logWarn("Validation failed: empty prompt")
                LrDialogs.message("Erreur", "Entrez des instructions.", "critical")
                return nil
            end
        end
        if props.directApi and (not props.apiKey or props.apiKey == "") then
            logWarn("Validation failed: missing API key")
            LrDialogs.message("Erreur", "Entrez votre cle API Claude.", "critical")
            return nil
        end
        if not props.directApi and not isValidServerUrl(props.serverUrl) then
            logWarn("Validation failed: invalid server URL: " .. tostring(props.serverUrl))
            LrDialogs.message("Erreur",
                "Entrez l'URL complete du serveur, par exemple :\nhttp://localhost:3000", "critical")
            return nil
        end

        props.serverUrl = normalizeServerUrl(props.serverUrl)
        props.debugLogPath = normalizeDebugLogPath(props.debugLogPath)
        logInfo("Dialog confirmed: mode=" .. tostring(mode)
            .. ", directApi=" .. tostring(props.directApi)
            .. ", serverUrl=" .. safeSnippet(props.serverUrl, 120)
            .. ", hasApiKey=" .. tostring((props.apiKey or "") ~= "")
            .. ", refPath=" .. safeSnippet(props.refPath, 180)
            .. ", prompt=" .. safeSnippet(props.prompt, 180)
            .. ", debugLogPath=" .. safeSnippet(props.debugLogPath ~= "" and props.debugLogPath or getDefaultDebugLogPath(), 220))

        savePrefs({
            apiKey      = props.apiKey,
            serverUrl   = props.serverUrl,
            directApi   = props.directApi,
            lastRefPath = props.refPath,
            lastMode    = mode,
            debugLogPath = props.debugLogPath,
        })

        return {
            mode      = mode,
            prompt    = props.prompt,
            refPath   = props.refPath,
            directApi = props.directApi,
            apiKey    = props.apiKey,
            serverUrl = props.serverUrl,
            debugLogPath = props.debugLogPath,
        }
    end)
end

-- ============================================================
-- Dialogue resultats
-- ============================================================
local function showResultDialog(xmpContent, xmpPath, mode)
    local f      = LrView.osFactory()
    local params = parseXmpToParams(xmpContent)
    logInfo("Opening result dialog: mode=" .. tostring(mode)
        .. ", xmpPath=" .. tostring(xmpPath)
        .. ", xmpChars=" .. tostring(xmpContent and #xmpContent or 0))

    local priority = {
        "Exposure2012","Contrast2012","Highlights2012","Shadows2012",
        "Whites2012","Blacks2012","Clarity2012","Texture","Dehaze",
        "Vibrance","Saturation","Temperature","Tint",
        "Sharpness","LuminanceSmoothing","ColorNoiseReduction",
        "GrainAmount","VignetteAmount",
    }

    local lines = {}
    for _, name in ipairs(priority) do
        if params[name] then
            table.insert(lines, string.format("%-28s= %s", name, tostring(params[name])))
        end
    end
    for name, value in pairs(params) do
        local found = false
        for _, p in ipairs(priority) do if p == name then found = true; break end end
        if not found and name ~= "Version" and name ~= "ProcessVersion" and name ~= "WhiteBalance" then
            table.insert(lines, string.format("%-28s= %s", name, tostring(value)))
        end
    end

    local modeLabels = {
        prompt    = "Prompt texte",
        reference = "Photo modele",
        both      = "Photo modele + instructions",
    }

    local contents = f:column {
        spacing = f:dialog_spacing(),
        f:static_text { title = "Reglages appliques avec succes !", font = "<system/bold>" },
        f:static_text {
            title = "Mode : " .. (modeLabels[mode] or mode) .. "   " .. #lines .. " parametre(s)",
            font  = "<system/small>",
        },
        f:separator { fill_horizontal = 1 },
        f:edit_field {
            value           = #lines > 0 and table.concat(lines, "\n") or "(aucun parametre detecte)",
            read_only       = true,
            width_in_chars  = 55,
            height_in_lines = 14,
            font            = "<system/small>",
        },
        f:separator { fill_horizontal = 1 },
        f:static_text {
            title = xmpPath,
            font  = "<system/small>",
        },
    }

    LrDialogs.presentModalDialog {
        title      = "Claude Photo AI — Resultats",
        contents   = contents,
        actionVerb = "Fermer",
        cancelVerb = false,
    }
end

-- ============================================================
-- Workflow principal
-- ============================================================
local function processPhotos(photos, config)
    local tmpDir  = getTempDir()
    local results = { success = 0, failed = 0, errors = {} }
    logInfo("Starting batch: count=" .. tostring(#photos)
        .. ", mode=" .. tostring(config.mode)
        .. ", directApi=" .. tostring(config.directApi)
        .. ", serverUrl=" .. safeSnippet(config.serverUrl, 120)
        .. ", hasApiKey=" .. tostring((config.apiKey or "") ~= "")
        .. ", refPath=" .. safeSnippet(config.refPath, 180)
        .. ", cacheDir=" .. safeSnippet(getCacheDir(), 220))

    -- Preparer la photo modele UNE SEULE FOIS pour tout le lot
    local refBase64 = nil
    if config.mode == "reference" or config.mode == "both" then
        local progress0 = LrProgressScope {
            title   = "Claude Photo AI",
            caption = "Preparation de la photo modele...",
        }

        local refJpeg, refErr = convertImageToJpeg(config.refPath, tmpDir, CONFIG.MAX_REF_SIZE)
        progress0:done()

        if not refJpeg then
            logError("Reference preparation failed: " .. tostring(refErr))
            LrDialogs.message("Erreur — Photo modele",
                "Impossible de convertir la photo modele :\n" .. (refErr or "?"), "critical")
            cleanTempDir(tmpDir)
            return
        end

        local b64, encErr = fileToBase64(refJpeg)
        if not b64 then
            logError("Reference encoding failed: " .. tostring(encErr))
            LrDialogs.message("Erreur — Photo modele",
                "Impossible d'encoder la photo modele : " .. (encErr or "?"), "critical")
            cleanTempDir(tmpDir)
            return
        end

        refBase64 = b64
        logInfo("Reference ready: " .. LrPathUtils.leafName(config.refPath) ..
                    " (" .. #refBase64 .. " chars b64)")
    end

    local progress = LrProgressScope { title = "Claude Photo AI" }

    for i, photo in ipairs(photos) do
        if progress:isCanceled() then
            logWarn("Batch cancelled by user at item " .. tostring(i) .. "/" .. tostring(#photos))
            break
        end

        local photoName = LrPathUtils.leafName(photo:getRawMetadata('path'))
        logInfo("Processing photo " .. tostring(i) .. "/" .. tostring(#photos) .. ": " .. tostring(photoName))
        progress:setPortionComplete(i - 1, #photos)

        repeat
            local cachedXmp, cacheFile = getCachedXmp(photo:getRawMetadata('path'), config)

            -- 1. Export JPEG
            progress:setCaption(string.format("[%d/%d] Export JPEG : %s", i, #photos, photoName))
            local jpegPath, exportErr = exportPhotoToJpeg(photo, tmpDir)
            if not jpegPath then
                logError("Step export failed for " .. tostring(photoName) .. ": " .. tostring(exportErr))
                table.insert(results.errors, photoName .. " : export echoue (" .. (exportErr or "?") .. ")")
                results.failed = results.failed + 1
                break
            end

            -- 2. Encodage base64
            progress:setCaption(string.format("[%d/%d] Encodage : %s", i, #photos, photoName))
            local imageBase64, encErr = fileToBase64(jpegPath)
            if not imageBase64 then
                logError("Step encode failed for " .. tostring(photoName) .. ": " .. tostring(encErr))
                table.insert(results.errors, photoName .. " : encodage echoue (" .. (encErr or "?") .. ")")
                results.failed = results.failed + 1
                break
            end

            -- 3. Appel Claude
            progress:setCaption(string.format("[%d/%d] Claude AI : %s", i, #photos, photoName))
            local xmpContent, apiErr
            if cachedXmp then
                xmpContent = cachedXmp
                logInfo("Using cached XMP for " .. tostring(photoName) .. ": " .. tostring(cacheFile))
            else
                if config.directApi then
                    xmpContent, apiErr = callClaudeDirectly(
                        imageBase64, refBase64, config.mode, config.prompt, config.apiKey)
                else
                    xmpContent, apiErr = callClaudeViaServer(
                        imageBase64, refBase64, config.mode, config.prompt, config.serverUrl)
                end
            end

            if not xmpContent then
                logError("Step API failed for " .. tostring(photoName) .. ": " .. tostring(apiErr))
                table.insert(results.errors, photoName .. " : " .. (apiErr or "erreur API inconnue"))
                results.failed = results.failed + 1
                break
            end
            logInfo("Received XMP for " .. tostring(photoName) .. ": " .. tostring(#xmpContent) .. " chars")

            -- Validation minimale
            if not isLikelyXmp(xmpContent) then
                logError("Response is not valid XMP for " .. photoName .. ": " .. safeSnippet(xmpContent, 400))
                table.insert(results.errors, photoName .. " : reponse invalide (XMP Lightroom non detecte)")
                results.failed = results.failed + 1
                break
            end
            if not cachedXmp then
                saveCachedXmp(photo:getRawMetadata('path'), config, xmpContent)
            end

            -- 4. Application dans Lightroom
            progress:setCaption(string.format("[%d/%d] Application : %s", i, #photos, photoName))
            local ok, applyErr, xmpPath = applyXmpToPhoto(photo, xmpContent, tmpDir)

            if ok then
                logInfo("Photo processed successfully: " .. tostring(photoName) .. ", xmpPath=" .. tostring(xmpPath))
                results.success = results.success + 1
                if i == 1 then
                    local cap_xmp  = xmpContent
                    local cap_path = xmpPath
                    local cap_mode = config.mode
                    LrTasks.startAsyncTask(function()
                        showResultDialog(cap_xmp, cap_path, cap_mode)
                    end)
                end
            else
                logError("Apply step failed for " .. tostring(photoName) .. ": " .. tostring(applyErr))
                table.insert(results.errors, photoName .. " : application echouee (" .. (applyErr or "?") .. ")")
                results.failed = results.failed + 1
            end
        until true
    end

    progress:done()
    logInfo("Batch finished: success=" .. tostring(results.success) .. ", failed=" .. tostring(results.failed))
    cleanTempDir(tmpDir)

    if results.failed > 0 then
        LrDialogs.message(
            "Claude Photo AI — Rapport",
            string.format("Succes : %d   Erreurs : %d\n\n%s",
                results.success, results.failed, table.concat(results.errors, "\n")),
            "warning")
    end

    return results
end

-- ============================================================
-- Point d'entree
-- ============================================================
LrTasks.startAsyncTask(function()
    logInfo("Plugin task started")
    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()
    logInfo("Selected photo count: " .. tostring(photos and #photos or 0))

    if not photos or #photos == 0 then
        logWarn("No selected photo, aborting")
        LrDialogs.message(
            "Claude Photo AI",
            "Selectionnez au moins une photo dans Lightroom avant de lancer le plugin.",
            "warning")
        return
    end

    local config = showMainDialog(photos)
    if not config then
        logWarn("Dialog returned no config, aborting")
        return
    end

    processPhotos(photos, config)
end)
