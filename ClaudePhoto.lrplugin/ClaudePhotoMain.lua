--[[
    ClaudePhotoMain.lua
    Point d'entrée principal du plugin Claude Photo AI pour Lightroom Classic
    
    Workflow :
    1. L'utilisateur sélectionne une ou plusieurs photos dans Lightroom
    2. Le plugin affiche une boîte de dialogue pour saisir le prompt
    3. La photo est exportée en JPEG temporaire
    4. Le JPEG + le prompt sont envoyés au serveur local (Node.js)
    5. Le serveur appelle l'API Claude avec l'image et le prompt
    6. Claude retourne un fichier XMP avec les réglages Lightroom
    7. Le plugin importe le XMP et applique les réglages à la photo originale
--]]

local LrApplication     = import 'LrApplication'
local LrCatalog         = import 'LrCatalog'
local LrDialogs         = import 'LrDialogs'
local LrExportSession   = import 'LrExportSession'
local LrFileUtils       = import 'LrFileUtils'
local LrHttp            = import 'LrHttp'
local LrLogger          = import 'LrLogger'
local LrPathUtils       = import 'LrPathUtils'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'
local LrView            = import 'LrView'
local LrBinding         = import 'LrBinding'
local LrObservableTable = import 'LrObservableTable'
local LrStringUtils     = import 'LrStringUtils'
local LrDevelopController = import 'LrDevelopController'
local LrPhoto           = import 'LrPhoto'

local logger = LrLogger('ClaudePhotoPlugin')
logger:enable('logfile')

-- ============================================================
-- Configuration
-- ============================================================
local CONFIG = {
    -- URL du serveur intermédiaire local (Node.js ou Python)
    SERVER_URL = "http://localhost:3000",
    -- Ou appel direct à l'API Anthropic (nécessite clé API dans les préférences)
    DIRECT_API = false,
    -- Taille max du JPEG envoyé (en pixels, côté le plus long)
    MAX_IMAGE_SIZE = 1568,
    -- Qualité JPEG pour l'envoi
    JPEG_QUALITY = 85,
    -- Timeout HTTP en secondes
    HTTP_TIMEOUT = 120,
}

-- ============================================================
-- Utilitaires
-- ============================================================

-- Lire les préférences du plugin
local function getPrefs()
    local prefs = import 'LrPrefs'
    local pluginPrefs = prefs.prefsForPlugin()
    return {
        apiKey    = pluginPrefs.apiKey or "",
        serverUrl = pluginPrefs.serverUrl or CONFIG.SERVER_URL,
        directApi = pluginPrefs.directApi or false,
    }
end

-- Sauvegarder les préférences
local function savePrefs(apiKey, serverUrl, directApi)
    local prefs = import 'LrPrefs'
    local pluginPrefs = prefs.prefsForPlugin()
    pluginPrefs.apiKey    = apiKey
    pluginPrefs.serverUrl = serverUrl
    pluginPrefs.directApi = directApi
end

-- Créer un dossier temporaire unique
local function getTempDir()
    local tmpBase = LrPathUtils.getStandardFilePath('temp')
    local tmpDir  = LrPathUtils.child(tmpBase, 'ClaudePhoto_' .. tostring(os.time()))
    LrFileUtils.createDirectory(tmpDir)
    return tmpDir
end

-- Nettoyer le dossier temporaire
local function cleanTempDir(dir)
    if dir and LrFileUtils.exists(dir) then
        LrFileUtils.delete(dir)
    end
end

-- Encoder un fichier en base64 (via shell si disponible)
local function fileToBase64(filePath)
    -- Utilisation de la commande système base64
    local cmd
    if WIN_ENV then
        -- Windows : PowerShell
        cmd = string.format(
            'powershell -Command "[Convert]::ToBase64String([IO.File]::ReadAllBytes(\'%s\'))"',
            filePath
        )
    else
        -- macOS / Linux
        cmd = string.format('base64 -i "%s"', filePath)
    end
    
    local handle = io.popen(cmd)
    if not handle then
        return nil, "Impossible d'encoder l'image en base64"
    end
    local result = handle:read("*a")
    handle:close()
    -- Supprimer les sauts de ligne insérés par base64
    result = result:gsub("%s+", "")
    return result
end

-- Lire le contenu d'un fichier
local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Écrire le contenu dans un fichier
local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

-- ============================================================
-- Export JPEG temporaire
-- ============================================================
local function exportPhotoToJpeg(photo, outputDir)
    local exportSettings = {
        LR_export_destinationType         = "specificFolder",
        LR_export_destinationPathPrefix   = outputDir,
        LR_export_useSubfolder            = false,
        LR_format                         = "JPEG",
        LR_jpeg_quality                   = CONFIG.JPEG_QUALITY / 100,
        LR_minimizeEmbeddedMetadata       = true,
        LR_outputSharpeningOn             = false,
        LR_size_doConstrain               = true,
        LR_size_maxHeight                 = CONFIG.MAX_IMAGE_SIZE,
        LR_size_maxWidth                  = CONFIG.MAX_IMAGE_SIZE,
        LR_size_resizeType                = "longEdge",
        LR_size_units                     = "pixels",
        LR_removeLocationMetadata         = false,
        LR_useWatermark                   = false,
        LR_export_colorSpace              = "sRGB",
        LR_collisionHandling              = "rename",
        -- Exporter SANS les développements (image originale) pour analyse fidèle
        -- Ou avec développements si vous voulez l'état actuel
        LR_extensionCase                  = "lowercase",
    }
    
    local exportSession = LrExportSession({
        photosToExport = { photo },
        exportSettings = exportSettings,
    })
    
    local exportedPaths = {}
    local success = false
    local errorMsg = nil
    
    exportSession:doExportOnCurrentTask(function(info)
        if info.name == 'exportedPhoto' then
            table.insert(exportedPaths, info.path)
            success = true
        elseif info.name == 'exportFailed' then
            errorMsg = info.error or "Export échoué"
            success = false
        end
    end)
    
    if success and #exportedPaths > 0 then
        return exportedPaths[1]
    else
        return nil, errorMsg or "Aucune photo exportée"
    end
end

-- ============================================================
-- Appel API Claude (direct ou via serveur)
-- ============================================================

-- Construction du prompt système pour générer un XMP valide
local function buildSystemPrompt()
    return [[Tu es un expert en post-traitement photographique et en Lightroom Classic.
    
Ta mission : analyser une photo et les instructions de l'utilisateur, puis générer un fichier XMP Adobe Lightroom valide contenant UNIQUEMENT les ajustements demandés.

RÈGLES IMPORTANTES :
1. Réponds UNIQUEMENT avec le contenu XML du fichier XMP, sans aucun texte avant ou après
2. Le XMP doit être un fichier valide compatible Lightroom Classic 6+
3. Utilise les paramètres Adobe Camera Raw (crs:) avec les plages correctes
4. N'inclus que les paramètres modifiés par rapport aux valeurs par défaut
5. Sois précis et conservateur : de petits ajustements subtils valent mieux que des corrections extrêmes

PLAGES DE VALEURS LIGHTROOM :
- Exposure2012 : -5.0 à +5.0 (exposition)
- Contrast2012 : -100 à +100 (contraste)
- Highlights2012 : -100 à +100 (hautes lumières)
- Shadows2012 : -100 à +100 (ombres)
- Whites2012 : -100 à +100 (blancs)
- Blacks2012 : -100 à +100 (noirs)
- Clarity2012 : -100 à +100 (clarté)
- Dehaze : -100 à +100 (brume)
- Vibrance : -100 à +100 (vibrance)
- Saturation : -100 à +100 (saturation)
- Temperature : 2000 à 50000 (température couleur en Kelvin)
- Tint : -150 à +150 (teinte)
- Sharpness : 0 à 150 (netteté)
- LuminanceSmoothing : 0 à 100 (réduction bruit luminance)
- ColorNoiseReduction : 0 à 100 (réduction bruit couleur)
- HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta : -100 à +100
- SaturationAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta : -100 à +100
- LuminanceAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta : -100 à +100
- ParametricShadows : -100 à +100
- ParametricLights : -100 à +100
- ParametricHighlights : -100 à +100
- ParametricShadowSplit : 0 à 100
- ParametricMidtoneSplit : 0 à 100
- ParametricHighlightSplit : 0 à 100
- GrainAmount : 0 à 100
- GrainSize : 25 à 100
- GrainFrequency : 0 à 100
- VignetteAmount : -100 à +100 (vignettage)
- VignetteMidpoint : 0 à 100

TEMPLATE XMP À UTILISER :
<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
<rdf:Description rdf:about=''
  xmlns:crs='http://ns.adobe.com/camera-raw-settings/1.0/'
  crs:Version='14.4'
  crs:ProcessVersion='11.0'
  crs:WhiteBalance='Custom'
  [PARAMÈTRES ICI]
/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>]]
end

-- Appel direct à l'API Anthropic
local function callClaudeDirectly(imageBase64, userPrompt, apiKey)
    local url = "https://api.anthropic.com/v1/messages"
    
    -- Construction du body JSON manuellement (Lua n'a pas de JSON natif)
    local systemPrompt = buildSystemPrompt()
    -- Échapper les guillemets dans les prompts
    systemPrompt = systemPrompt:gsub('"', '\\"'):gsub('\n', '\\n')
    userPrompt   = userPrompt:gsub('"', '\\"'):gsub('\n', '\\n')
    
    local jsonBody = string.format([[{
        "model": "claude-opus-4-5",
        "max_tokens": 2048,
        "system": "%s",
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": "%s"
                        }
                    },
                    {
                        "type": "text",
                        "text": "%s"
                    }
                ]
            }
        ]
    }]], systemPrompt, imageBase64, userPrompt)
    
    local headers = {
        { field = "Content-Type",      value = "application/json" },
        { field = "x-api-key",         value = apiKey },
        { field = "anthropic-version", value = "2023-06-01" },
    }
    
    local result, hdrs = LrHttp.post(url, jsonBody, headers, "POST", CONFIG.HTTP_TIMEOUT)
    
    if not result then
        return nil, "Erreur réseau : impossible de contacter l'API Claude"
    end
    
    -- Parser la réponse JSON manuellement (extraction basique)
    -- Chercher le contenu texte dans la réponse
    local xmpContent = result:match('"text"%s*:%s*"(.-[^\\])"')
    if not xmpContent then
        -- Essayer une extraction plus large
        xmpContent = result:match('"text":"(.*)"')
    end
    
    if not xmpContent then
        logger:error("Réponse API inattendue : " .. result)
        return nil, "Impossible de parser la réponse de Claude. Vérifiez la clé API."
    end
    
    -- Décoder les séquences d'échappement JSON
    xmpContent = xmpContent:gsub('\\"', '"')
    xmpContent = xmpContent:gsub('\\n', '\n')
    xmpContent = xmpContent:gsub('\\t', '\t')
    xmpContent = xmpContent:gsub('\\r', '\r')
    xmpContent = xmpContent:gsub('\\\\', '\\')
    
    return xmpContent
end

-- Appel via le serveur intermédiaire local
local function callClaudeViaServer(imageBase64, userPrompt, serverUrl)
    local url = serverUrl .. "/analyze"
    
    -- Encoder le prompt pour JSON
    local escapedPrompt = userPrompt:gsub('"', '\\"'):gsub('\n', '\\n')
    
    local jsonBody = string.format([[{
        "image": "%s",
        "prompt": "%s"
    }]], imageBase64, escapedPrompt)
    
    local headers = {
        { field = "Content-Type", value = "application/json" },
    }
    
    local result, hdrs = LrHttp.post(url, jsonBody, headers, "POST", CONFIG.HTTP_TIMEOUT)
    
    if not result then
        return nil, "Erreur : impossible de contacter le serveur local à " .. serverUrl
    end
    
    -- Le serveur retourne directement le contenu XMP
    if result:find("<?xpacket") or result:find("<x:xmpmeta") then
        return result
    end
    
    -- Ou le serveur retourne du JSON avec le XMP
    local xmpContent = result:match('"xmp"%s*:%s*"(.-[^\\])"')
    if xmpContent then
        xmpContent = xmpContent:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\\\', '\\')
        return xmpContent
    end
    
    -- Vérifier les erreurs
    local errorMsg = result:match('"error"%s*:%s*"(.-)"')
    return nil, errorMsg or ("Réponse inattendue du serveur : " .. result:sub(1, 200))
end

-- ============================================================
-- Application du XMP à la photo
-- ============================================================
local function applyXmpToPhoto(photo, xmpContent, tmpDir)
    -- Écrire le XMP dans un fichier temporaire
    local photoName = LrPathUtils.leafName(photo:getRawMetadata('path'))
    local baseName  = LrPathUtils.removeExtension(photoName)
    local xmpPath   = LrPathUtils.child(tmpDir, baseName .. '_claude.xmp')
    
    if not writeFile(xmpPath, xmpContent) then
        return false, "Impossible d'écrire le fichier XMP temporaire"
    end
    
    -- Appliquer le XMP via le catalogue Lightroom
    local catalog = LrApplication.activeCatalog()
    local success = false
    local errorMsg = nil
    
    catalog:withWriteAccessDo("Appliquer réglages Claude AI", function()
        -- Méthode 1 : Développement via setRawMetadata (XMP settings)
        -- Lire et parser le XMP pour extraire les paramètres
        local params = parseXmpToParams(xmpContent)
        
        if params and next(params) ~= nil then
            -- Appliquer chaque paramètre via l'API Develop
            for paramName, paramValue in pairs(params) do
                local ok, err = pcall(function()
                    photo:applyDevelopSettings({ [paramName] = paramValue })
                end)
                if not ok then
                    logger:warn("Paramètre non appliqué : " .. paramName .. " = " .. tostring(paramValue))
                end
            end
            success = true
        else
            -- Méthode 2 : Copier le XMP à côté de la photo originale
            local originalPath = photo:getRawMetadata('path')
            local originalBase = LrPathUtils.removeExtension(originalPath)
            local sidecarXmp   = originalBase .. '.xmp'
            
            if LrFileUtils.copy(xmpPath, sidecarXmp) then
                -- Forcer Lightroom à relire le XMP sidecar
                catalog:autoSyncPhotos(false)
                photo:readMetadataFromXmp()
                success = true
            else
                errorMsg = "Impossible de créer le XMP sidecar à côté de la photo"
            end
        end
    end, { timeout = 30 })
    
    return success, errorMsg, xmpPath
end

-- Parser les paramètres XMP en table Lua
function parseXmpToParams(xmpContent)
    local params = {}
    
    -- Extraire tous les attributs crs:NomParametre="valeur"
    for paramName, paramValue in xmpContent:gmatch('crs:([%w]+)%s*=%s*"([^"]*)"') do
        -- Convertir en nombre si possible
        local numVal = tonumber(paramValue)
        if numVal then
            params[paramName] = numVal
        else
            params[paramName] = paramValue
        end
    end
    
    return params
end

-- ============================================================
-- Interface utilisateur principale
-- ============================================================
local function showMainDialog(photos)
    local prefs = getPrefs()
    local f     = LrView.osFactory()
    
    local props = LrObservableTable.new()
    props.prompt    = "Rends cette photo plus chaleureuse et dramatique, augmente légèrement le contraste et rehausse les ombres"
    props.directApi = prefs.directApi
    props.apiKey    = prefs.apiKey
    props.serverUrl = prefs.serverUrl
    props.showAdvanced = false
    
    -- Suggestions de prompts prédéfinis
    local suggestions = {
        "Photo de portrait naturel : peaux douces, yeux nets, lumière flatteuse",
        "Paysage dramatique : ciel contrasté, couleurs saturées, clarté maximale",
        "Style cinématique désaturé : tons froids, contrastes doux, ambiance film",
        "Photo de nuit : réduire le bruit, récupérer les détails dans les ombres",
        "Style rétro vintage : vignettage, grain, tons chauds légèrement délavés",
        "HDR naturel : récupérer hautes lumières et ombres sans effet artificiel",
        "Portrait noir et blanc : contraste expressif, peaux lumineuses",
        "Coucher de soleil : booster les oranges et rouges, réchauffer les tons",
    }
    
    local contents = f:column {
        spacing = f:dialog_spacing(),
        bind_to_object = props,
        
        -- En-tête
        f:row {
            f:static_text {
                title = "🤖 Claude Photo AI",
                font  = "<system/bold>",
                fill_horizontal = 1,
            },
            f:static_text {
                title = string.format("%d photo(s) sélectionnée(s)", #photos),
                font  = "<system>",
                text_color = LrView.resource('disabled_text_color'),
            },
        },
        
        f:separator { fill_horizontal = 1 },
        
        -- Zone de prompt
        f:static_text {
            title = "Décrivez les modifications souhaitées :",
            font  = "<system/bold>",
        },
        
        f:edit_field {
            value           = LrBinding.bindProperty(props, 'prompt'),
            width_in_chars  = 60,
            height_in_lines = 4,
            wraps           = true,
        },
        
        -- Suggestions rapides
        f:static_text {
            title = "Suggestions :",
            font  = "<system>",
            text_color = LrView.resource('disabled_text_color'),
        },
        
        f:column {
            spacing = f:label_spacing(),
            (function()
                local rows = {}
                for i = 1, #suggestions do
                    table.insert(rows, f:push_button {
                        title  = suggestions[i]:sub(1, 60) .. (suggestions[i]:len() > 60 and "..." or ""),
                        font   = "<system/small>",
                        action = function()
                            props.prompt = suggestions[i]
                        end,
                    })
                end
                return table.unpack(rows)
            end)()
        },
        
        f:separator { fill_horizontal = 1 },
        
        -- Configuration avancée (dépliable)
        f:push_button {
            title  = "⚙ Configuration avancée",
            action = function()
                props.showAdvanced = not props.showAdvanced
            end,
        },
        
        f:group_box {
            title   = "Configuration",
            visible = LrBinding.bindProperty(props, 'showAdvanced'),
            
            f:column {
                spacing = f:label_spacing(),
                
                f:row {
                    f:static_text {
                        title = "Mode :",
                        width = LrView.share('label_width'),
                    },
                    f:radio_button {
                        title = "Serveur local (recommandé)",
                        value = false,
                        checked_value = LrBinding.bindProperty(props, 'directApi'),
                    },
                },
                f:row {
                    f:static_text { title = "", width = LrView.share('label_width') },
                    f:radio_button {
                        title = "API directe (clé API requise)",
                        value = true,
                        checked_value = LrBinding.bindProperty(props, 'directApi'),
                    },
                },
                
                f:row {
                    visible = LrBinding.negativeOfKey(props, 'directApi'),
                    f:static_text {
                        title = "URL serveur :",
                        width = LrView.share('label_width'),
                    },
                    f:edit_field {
                        value          = LrBinding.bindProperty(props, 'serverUrl'),
                        width_in_chars = 40,
                    },
                },
                
                f:row {
                    visible = LrBinding.bindProperty(props, 'directApi'),
                    f:static_text {
                        title = "Clé API Claude :",
                        width = LrView.share('label_width'),
                    },
                    f:password_field {
                        value          = LrBinding.bindProperty(props, 'apiKey'),
                        width_in_chars = 40,
                    },
                },
                
                f:static_text {
                    title = "Obtenez votre clé sur console.anthropic.com",
                    font  = "<system/small>",
                    text_color = LrView.resource('disabled_text_color'),
                    visible    = LrBinding.bindProperty(props, 'directApi'),
                },
            },
        },
    }
    
    local result = LrDialogs.presentModalDialog {
        title    = "Claude Photo AI — Développement IA",
        contents = contents,
        actionVerb   = "Analyser et Développer",
        cancelVerb   = "Annuler",
        otherVerb    = nil,
    }
    
    if result == 'ok' then
        -- Sauvegarder les préférences
        savePrefs(props.apiKey, props.serverUrl, props.directApi)
        return {
            prompt    = props.prompt,
            directApi = props.directApi,
            apiKey    = props.apiKey,
            serverUrl = props.serverUrl,
        }
    end
    
    return nil
end

-- ============================================================
-- Affichage des résultats / prévisualisation XMP
-- ============================================================
local function showResultDialog(xmpContent, photoPath, xmpPath)
    local f = LrView.osFactory()
    
    -- Extraire et afficher les paramètres principaux du XMP
    local params = parseXmpToParams(xmpContent)
    local paramList = {}
    
    -- Paramètres importants à afficher en priorité
    local priority = {
        "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
        "Whites2012", "Blacks2012", "Clarity2012", "Vibrance", "Saturation",
        "Temperature", "Tint", "Dehaze", "Sharpness"
    }
    
    for _, name in ipairs(priority) do
        if params[name] then
            table.insert(paramList, string.format("%-25s = %s", name, tostring(params[name])))
        end
    end
    
    -- Autres paramètres
    for name, value in pairs(params) do
        local found = false
        for _, p in ipairs(priority) do
            if p == name then found = true; break end
        end
        if not found then
            table.insert(paramList, string.format("%-25s = %s", name, tostring(value)))
        end
    end
    
    local paramText = #paramList > 0 
        and table.concat(paramList, "\n")
        or  "(aucun paramètre détecté)"
    
    local contents = f:column {
        spacing = f:dialog_spacing(),
        
        f:static_text {
            title = "✅ Réglages Claude AI appliqués avec succès !",
            font  = "<system/bold>",
        },
        
        f:separator { fill_horizontal = 1 },
        
        f:static_text {
            title = "Paramètres appliqués (" .. #paramList .. ") :",
            font  = "<system/bold>",
        },
        
        f:edit_field {
            value           = paramText,
            read_only       = true,
            width_in_chars  = 55,
            height_in_lines = 10,
            font            = "<system/small>",
        },
        
        f:separator { fill_horizontal = 1 },
        
        f:static_text {
            title = "Fichier XMP sauvegardé : " .. xmpPath,
            font  = "<system/small>",
            text_color = LrView.resource('disabled_text_color'),
        },
        
        f:static_text {
            title = "Conseil : Vous pouvez aussi glisser le fichier XMP directement dans Lightroom.",
            font  = "<system/small>",
            text_color = LrView.resource('disabled_text_color'),
        },
    }
    
    LrDialogs.presentModalDialog {
        title      = "Claude Photo AI — Résultats",
        contents   = contents,
        actionVerb = "Fermer",
        cancelVerb = false,
    }
end

-- ============================================================
-- Workflow principal
-- ============================================================
local function processPhotos(photos, config)
    local catalog = LrApplication.activeCatalog()
    local tmpDir  = getTempDir()
    local results = { success = 0, failed = 0, errors = {} }
    
    local progress = LrProgressScope {
        title       = "Claude Photo AI",
        functionContext = nil,
    }
    
    for i, photo in ipairs(photos) do
        if progress:isCanceled() then break end
        
        local photoName = LrPathUtils.leafName(photo:getRawMetadata('path'))
        progress:setCaption(string.format("Traitement %d/%d : %s", i, #photos, photoName))
        progress:setPortionComplete(i - 1, #photos)
        
        -- Étape 1 : Export JPEG
        progress:setCaption("Export JPEG : " .. photoName)
        local jpegPath, exportErr = exportPhotoToJpeg(photo, tmpDir)
        
        if not jpegPath then
            table.insert(results.errors, photoName .. " : export échoué (" .. (exportErr or "?") .. ")")
            results.failed = results.failed + 1
            goto continue
        end
        
        -- Étape 2 : Encoder en base64
        progress:setCaption("Encodage image : " .. photoName)
        local imageBase64, encErr = fileToBase64(jpegPath)
        
        if not imageBase64 then
            table.insert(results.errors, photoName .. " : encodage échoué (" .. (encErr or "?") .. ")")
            results.failed = results.failed + 1
            goto continue
        end
        
        -- Étape 3 : Appel API Claude
        progress:setCaption("Appel Claude AI : " .. photoName)
        local xmpContent, apiErr
        
        if config.directApi then
            xmpContent, apiErr = callClaudeDirectly(imageBase64, config.prompt, config.apiKey)
        else
            xmpContent, apiErr = callClaudeViaServer(imageBase64, config.prompt, config.serverUrl)
        end
        
        if not xmpContent then
            table.insert(results.errors, photoName .. " : API error (" .. (apiErr or "?") .. ")")
            results.failed = results.failed + 1
            goto continue
        end
        
        -- Valider que c'est bien un XMP
        if not xmpContent:find("<?xpacket") and not xmpContent:find("<x:xmpmeta") and not xmpContent:find("crs:") then
            table.insert(results.errors, photoName .. " : réponse invalide (pas un XMP)")
            logger:error("Réponse non-XMP reçue : " .. xmpContent:sub(1, 500))
            results.failed = results.failed + 1
            goto continue
        end
        
        -- Étape 4 : Appliquer le XMP
        progress:setCaption("Application des réglages : " .. photoName)
        local ok, applyErr, xmpPath = applyXmpToPhoto(photo, xmpContent, tmpDir)
        
        if ok then
            results.success = results.success + 1
            -- Afficher le détail pour la première photo réussie
            if i == 1 then
                LrTasks.startAsyncTask(function()
                    LrDialogs.stopModalWithResult(nil, 'ok')
                    showResultDialog(xmpContent, photo:getRawMetadata('path'), xmpPath)
                end)
            end
        else
            table.insert(results.errors, photoName .. " : application échouée (" .. (applyErr or "?") .. ")")
            results.failed = results.failed + 1
        end
        
        ::continue::
    end
    
    progress:done()
    cleanTempDir(tmpDir)
    
    -- Rapport final
    if results.failed > 0 then
        local errorText = table.concat(results.errors, "\n")
        LrDialogs.message(
            "Claude Photo AI — Rapport",
            string.format("Succès : %d | Erreurs : %d\n\nDétails :\n%s", 
                results.success, results.failed, errorText),
            "warning"
        )
    end
    
    return results
end

-- ============================================================
-- Point d'entrée
-- ============================================================
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()
    
    if not photos or #photos == 0 then
        LrDialogs.message(
            "Claude Photo AI",
            "Veuillez sélectionner au moins une photo dans Lightroom avant d'utiliser ce plugin.",
            "warning"
        )
        return
    end
    
    -- Afficher la boîte de dialogue principale
    local config = showMainDialog(photos)
    if not config then return end
    
    -- Validation
    if config.directApi and (not config.apiKey or config.apiKey == "") then
        LrDialogs.message("Erreur", "Veuillez entrer votre clé API Claude dans la configuration.", "critical")
        return
    end
    
    if not config.prompt or config.prompt:match("^%s*$") then
        LrDialogs.message("Erreur", "Veuillez entrer des instructions de développement.", "critical")
        return
    end
    
    -- Traiter les photos
    processPhotos(photos, config)
end)
