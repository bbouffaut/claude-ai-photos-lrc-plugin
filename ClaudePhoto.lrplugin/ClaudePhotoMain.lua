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
local LrObservableTable   = import 'LrObservableTable'

local logger = LrLogger('ClaudePhotoPlugin')
logger:enable('logfile')

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
    return {
        apiKey      = p.apiKey      or "",
        serverUrl   = p.serverUrl   or CONFIG.SERVER_URL,
        directApi   = p.directApi   or false,
        lastRefPath = p.lastRefPath or "",
        lastMode    = p.lastMode    or "prompt",
    }
end

local function savePrefs(t)
    local prefs = import 'LrPrefs'
    local p = prefs.prefsForPlugin()
    p.apiKey      = t.apiKey
    p.serverUrl   = t.serverUrl
    p.directApi   = t.directApi
    p.lastRefPath = t.lastRefPath or ""
    p.lastMode    = t.lastMode    or "prompt"
end

-- ============================================================
-- Utilitaires fichiers
-- ============================================================
local function getTempDir()
    local base = LrPathUtils.getStandardFilePath('temp')
    local dir  = LrPathUtils.child(base, 'ClaudePhoto_' .. tostring(os.time()))
    LrFileUtils.createDirectory(dir)
    return dir
end

local function cleanTempDir(dir)
    if dir and LrFileUtils.exists(dir) then
        LrFileUtils.delete(dir)
    end
end

local function writeFile(path, content)
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
    local cmd
    if WIN_ENV then
        cmd = string.format(
            'powershell -Command "[Convert]::ToBase64String([IO.File]::ReadAllBytes(\'%s\'))"',
            filePath)
    else
        cmd = string.format('base64 -i "%s"', filePath)
    end
    local handle = io.popen(cmd)
    if not handle then return nil, "Impossible d'encoder l'image" end
    local result = handle:read("*a")
    handle:close()
    result = result:gsub("%s+", "")
    if #result < 100 then return nil, "Base64 vide ou trop court" end
    return result
end

-- Convertir/redimensionner n'importe quelle image en JPEG temporaire
-- Supporte JPEG, PNG, TIFF, et RAW via sips (macOS) ou magick (Windows/Linux)
local function convertImageToJpeg(srcPath, outputDir, maxSize)
    local ext      = LrPathUtils.extension(srcPath):lower()
    local baseName = LrPathUtils.removeExtension(LrPathUtils.leafName(srcPath))
    local outPath  = LrPathUtils.child(outputDir, baseName .. '_ref.jpg')

    local cmd
    if WIN_ENV then
        -- ImageMagick (Windows) - a installer separement
        cmd = string.format('magick "%s" -resize %dx%d> -quality 85 "%s" 2>nul',
            srcPath, maxSize, maxSize, outPath)
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
            os.execute(cmd)
        end
    else
        -- macOS : sips est integre et gere JPEG, PNG, TIFF, RAW Apple, BMP, GIF
        cmd = string.format(
            'sips -Z %d --setProperty format jpeg "%s" --out "%s" 2>/dev/null',
            maxSize, srcPath, outPath)
        local ok = os.execute(cmd)
        -- Pour les RAW non Apple (Nikon NEF, Sony ARW, etc.), sips echoue
        -- Fallback : dcraw ou rawtherapee si disponibles
        if not ok or not LrFileUtils.exists(outPath) then
            cmd = string.format(
                'dcraw -c -w -T "%s" | sips -Z %d --setProperty format jpeg - --out "%s" 2>/dev/null',
                srcPath, maxSize, outPath)
            os.execute(cmd)
        end
        if not LrFileUtils.exists(outPath) then
            -- Dernier recours : copie directe (si c'est un JPEG mal detecte)
            LrFileUtils.copy(srcPath, outPath)
        end
    end

    if LrFileUtils.exists(outPath) then
        return outPath
    end
    return nil, "Impossible de convertir la photo modele en JPEG (format non supporte ?)"
end

-- ============================================================
-- Export JPEG depuis Lightroom (photo a developper)
-- ============================================================
local function exportPhotoToJpeg(photo, outputDir, maxSize)
    maxSize = maxSize or CONFIG.MAX_IMAGE_SIZE
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

    local exportedPaths = {}
    local success = false
    local errorMsg

    exportSession:doExportOnCurrentTask(function(info)
        if info.name == 'exportedPhoto' then
            table.insert(exportedPaths, info.path)
            success = true
        elseif info.name == 'exportFailed' then
            errorMsg = info.error or "Export echoue"
        end
    end)

    if success and #exportedPaths > 0 then
        return exportedPaths[1]
    end
    return nil, errorMsg or "Aucune photo exportee"
end

-- ============================================================
-- Prompts Claude selon le mode
-- ============================================================
local SYSTEM_PROMPT = [[Tu es un expert en post-traitement photographique et en Lightroom Classic / Adobe Camera Raw.

REGLES ABSOLUES :
1. Reponds UNIQUEMENT avec le contenu XML du fichier XMP — aucun texte avant ou apres, pas de backticks
2. Le XMP doit etre compatible Lightroom Classic 6+ (ProcessVersion 11.0)
3. Utilise exclusivement les parametres crs: avec les plages ci-dessous
4. N'inclus que les parametres effectivement modifies
5. Prefere les ajustements naturels et subtils aux valeurs extremes

PLAGES DE VALEURS :
Exposition  : Exposure2012 (-5/+5), Contrast2012 (-100/+100)
Tonalites   : Highlights2012 (-100/+100), Shadows2012 (-100/+100), Whites2012 (-100/+100), Blacks2012 (-100/+100)
Presence    : Clarity2012 (-100/+100), Texture (-100/+100), Dehaze (-100/+100)
Couleur     : Temperature (2000/50000 K), Tint (-150/+150), Vibrance (-100/+100), Saturation (-100/+100)
HSL Teinte  : HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
HSL Sat.    : SaturationAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
HSL Lum.    : LuminanceAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100/+100)
Courbe tone : ParametricShadows/Darks/Lights/Highlights (-100/+100)
              ParametricShadowSplit/MidtoneSplit/HighlightSplit (0/100)
Detail      : Sharpness (0/150), SharpenRadius (0.5/3.0), SharpenDetail (0/100), SharpenEdgeMasking (0/100)
              LuminanceSmoothing (0/100), ColorNoiseReduction (0/100)
Effets      : GrainAmount (0/100), GrainSize (25/100), GrainFrequency (0/100)
              VignetteAmount (-100/+100), VignetteMidpoint (0/100)
Calibration : ShadowTint (-100/+100), RedHue/GreenHue/BlueHue (-100/+100),
              RedSaturation/GreenSaturation/BlueSaturation (-100/+100)

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

-- ============================================================
-- Appel API directe
-- ============================================================
local function callClaudeDirectly(imageBase64, refBase64, mode, userPrompt, apiKey)
    local url = "https://api.anthropic.com/v1/messages"

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
        return nil, "Erreur reseau : impossible de contacter l'API Claude"
    end

    -- Extraction du texte XMP depuis la reponse JSON
    local xmpContent = result:match('"text"%s*:%s*"(.-[^\\])"')
    if not xmpContent then
        xmpContent = result:match('"text":"(.+)"')
    end
    if not xmpContent then
        logger:error("Reponse inattendue : " .. result:sub(1, 500))
        return nil, "Reponse Claude non parsable. Verifiez la cle API.\n" .. result:sub(1, 200)
    end

    xmpContent = xmpContent:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\t','\t'):gsub('\\r','\r'):gsub('\\\\','\\')
    return xmpContent
end

-- ============================================================
-- Appel via serveur Node.js
-- ============================================================
local function callClaudeViaServer(imageBase64, refBase64, mode, userPrompt, serverUrl)
    local normalizedServerUrl = normalizeServerUrl(serverUrl)
    local url = normalizedServerUrl .. "/analyze"

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
        return nil, "Impossible de contacter le serveur : " .. normalizedServerUrl
    end

    -- Reponse XMP directe
    if result:find("crs:") then
        return result
    end

    -- Reponse JSON enveloppee
    local xmp = result:match('"xmp"%s*:%s*"(.-[^\\])"')
    if xmp then
        return xmp:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\\\','\\')
    end

    local errMsg = result:match('"error"%s*:%s*"(.-)"')
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
    return params
end

local function applyXmpToPhoto(photo, xmpContent, tmpDir)
    local photoName = LrPathUtils.leafName(photo:getRawMetadata('path'))
    local baseName  = LrPathUtils.removeExtension(photoName)
    local xmpPath   = LrPathUtils.child(tmpDir, baseName .. '_claude.xmp')

    if not writeFile(xmpPath, xmpContent) then
        return false, "Impossible d'ecrire le XMP temporaire", xmpPath
    end

    local catalog = LrApplication.activeCatalog()
    local success = false
    local errorMsg

    catalog:withWriteAccessDo("Appliquer reglages Claude AI", function()
        local params = parseXmpToParams(xmpContent)
        if params and next(params) then
            for name, value in pairs(params) do
                if name ~= "Version" and name ~= "ProcessVersion" and name ~= "WhiteBalance" then
                    pcall(function() photo:applyDevelopSettings({ [name] = value }) end)
                end
            end
            success = true
        else
            -- Fallback XMP sidecar
            local originalPath = photo:getRawMetadata('path')
            local sidecar = LrPathUtils.removeExtension(originalPath) .. '.xmp'
            if LrFileUtils.copy(xmpPath, sidecar) then
                catalog:autoSyncPhotos(false)
                photo:readMetadataFromXmp()
                success = true
            else
                errorMsg = "Impossible de creer le XMP sidecar"
            end
        end
    end, { timeout = 30 })

    return success, errorMsg, xmpPath
end

-- ============================================================
-- Dialogue principal v2
-- ============================================================
local function showMainDialog(photos)
    local prefs = getPrefs()
    local f     = LrView.osFactory()
    local props = LrObservableTable.new()

    props.mode         = prefs.lastMode or "prompt"
    props.prompt       = "Rends cette photo plus chaleureuse et dramatique"
    props.refPath      = prefs.lastRefPath or ""
    props.directApi    = prefs.directApi
    props.apiKey       = prefs.apiKey
    props.serverUrl    = prefs.serverUrl
    props.showAdvanced = false

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
                text_color = LrView.resource('disabled_text_color'),
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
                    value         = "prompt",
                    checked_value = LrBinding.bindProperty(props, 'mode'),
                },
                f:radio_button {
                    title         = "Photo modele — reproduire son style",
                    value         = "reference",
                    checked_value = LrBinding.bindProperty(props, 'mode'),
                },
                f:radio_button {
                    title         = "Photo modele + instructions complementaires",
                    value         = "both",
                    checked_value = LrBinding.bindProperty(props, 'mode'),
                },
            },
        },

        -- Bloc photo modele
        f:group_box {
            title   = "Photo modele",
            visible = LrBinding.keyIsNotEqualToValue(props, 'mode', "prompt"),
            f:column {
                spacing = f:label_spacing(),
                f:static_text {
                    title = "Selectionnez l'image dont le style sera analyse et reproduit :",
                    font  = "<system/small>",
                    text_color = LrView.resource('disabled_text_color'),
                },
                f:row {
                    f:edit_field {
                        value          = LrBinding.bindProperty(props, 'refPath'),
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
                        title = LrBinding.andAllKeys(
                            LrBinding.bindProperty(props, 'refPath'),
                            function(p)
                                if not p or p == "" then
                                    return "Aucun fichier selectionne"
                                elseif LrFileUtils.exists(p) then
                                    return "OK : " .. LrPathUtils.leafName(p)
                                else
                                    return "Fichier introuvable : " .. p
                                end
                            end
                        ),
                        font = "<system/small>",
                        text_color = LrView.resource('disabled_text_color'),
                    },
                },
                f:static_text {
                    title = "Formats : JPEG, PNG, TIFF, RAW (NEF/CR2/CR3/ARW/DNG/RAF...)",
                    font  = "<system/small>",
                    text_color = LrView.resource('disabled_text_color'),
                },
            },
        },

        -- Bloc instructions texte
        f:group_box {
            title   = "Instructions",
            visible = LrBinding.keyIsNotEqualToValue(props, 'mode', "reference"),
            f:column {
                spacing = f:label_spacing(),
                f:static_text {
                    title = "Decrivez les modifications souhaitees :",
                    font  = "<system/small>",
                    text_color = LrView.resource('disabled_text_color'),
                },
                f:edit_field {
                    value           = LrBinding.bindProperty(props, 'prompt'),
                    width_in_chars  = 55,
                    height_in_lines = 3,
                    wraps           = true,
                },
                f:static_text {
                    title = "Suggestions :",
                    font  = "<system/small>",
                    text_color = LrView.resource('disabled_text_color'),
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
                        return table.unpack(btns)
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
            visible = LrBinding.bindProperty(props, 'showAdvanced'),
            f:column {
                spacing = f:label_spacing(),
                f:radio_button {
                    title         = "Serveur local Node.js (recommande)",
                    value         = false,
                    checked_value = LrBinding.bindProperty(props, 'directApi'),
                },
                f:radio_button {
                    title         = "Appel API direct",
                    value         = true,
                    checked_value = LrBinding.bindProperty(props, 'directApi'),
                },
                f:row {
                    visible = LrBinding.negativeOfKey(props, 'directApi'),
                    f:static_text { title = "URL complete du serveur :", width = LrView.share('lbl') },
                    f:edit_field { value = LrBinding.bindProperty(props, 'serverUrl'), width_in_chars = 35 },
                },
                f:static_text {
                    visible = LrBinding.negativeOfKey(props, 'directApi'),
                    title = "Exemple : http://localhost:3000",
                    font  = "<system/small>",
                    text_color = LrView.resource('disabled_text_color'),
                },
                f:row {
                    visible = LrBinding.bindProperty(props, 'directApi'),
                    f:static_text { title = "Cle API Claude :", width = LrView.share('lbl') },
                    f:password_field { value = LrBinding.bindProperty(props, 'apiKey'), width_in_chars = 35 },
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

    if result ~= 'ok' then return nil end

    local mode = props.mode

    -- Validations
    if mode == "reference" or mode == "both" then
        if not props.refPath or props.refPath == "" then
            LrDialogs.message("Erreur", "Selectionnez une photo modele.", "critical")
            return nil
        end
        if not LrFileUtils.exists(props.refPath) then
            LrDialogs.message("Erreur", "Photo modele introuvable :\n" .. props.refPath, "critical")
            return nil
        end
    end
    if mode == "prompt" or mode == "both" then
        if not props.prompt or props.prompt:match("^%s*$") then
            LrDialogs.message("Erreur", "Entrez des instructions.", "critical")
            return nil
        end
    end
    if props.directApi and (not props.apiKey or props.apiKey == "") then
        LrDialogs.message("Erreur", "Entrez votre cle API Claude.", "critical")
        return nil
    end
    if not props.directApi and not isValidServerUrl(props.serverUrl) then
        LrDialogs.message("Erreur",
            "Entrez l'URL complete du serveur, par exemple :\nhttp://localhost:3000", "critical")
        return nil
    end

    props.serverUrl = normalizeServerUrl(props.serverUrl)

    savePrefs({
        apiKey      = props.apiKey,
        serverUrl   = props.serverUrl,
        directApi   = props.directApi,
        lastRefPath = props.refPath,
        lastMode    = mode,
    })

    return {
        mode      = mode,
        prompt    = props.prompt,
        refPath   = props.refPath,
        directApi = props.directApi,
        apiKey    = props.apiKey,
        serverUrl = props.serverUrl,
    }
end

-- ============================================================
-- Dialogue resultats
-- ============================================================
local function showResultDialog(xmpContent, xmpPath, mode)
    local f      = LrView.osFactory()
    local params = parseXmpToParams(xmpContent)

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
            text_color = LrView.resource('disabled_text_color'),
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
            text_color = LrView.resource('disabled_text_color'),
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
            LrDialogs.message("Erreur — Photo modele",
                "Impossible de convertir la photo modele :\n" .. (refErr or "?"), "critical")
            cleanTempDir(tmpDir)
            return
        end

        local b64, encErr = fileToBase64(refJpeg)
        if not b64 then
            LrDialogs.message("Erreur — Photo modele",
                "Impossible d'encoder la photo modele : " .. (encErr or "?"), "critical")
            cleanTempDir(tmpDir)
            return
        end

        refBase64 = b64
        logger:info("Photo modele prete : " .. LrPathUtils.leafName(config.refPath) ..
                    " (" .. #refBase64 .. " chars b64)")
    end

    local progress = LrProgressScope { title = "Claude Photo AI" }

    for i, photo in ipairs(photos) do
        if progress:isCanceled() then break end

        local photoName = LrPathUtils.leafName(photo:getRawMetadata('path'))
        progress:setPortionComplete(i - 1, #photos)

        -- 1. Export JPEG
        progress:setCaption(string.format("[%d/%d] Export JPEG : %s", i, #photos, photoName))
        local jpegPath, exportErr = exportPhotoToJpeg(photo, tmpDir)
        if not jpegPath then
            table.insert(results.errors, photoName .. " : export echoue (" .. (exportErr or "?") .. ")")
            results.failed = results.failed + 1
            goto continue
        end

        -- 2. Encodage base64
        progress:setCaption(string.format("[%d/%d] Encodage : %s", i, #photos, photoName))
        local imageBase64, encErr = fileToBase64(jpegPath)
        if not imageBase64 then
            table.insert(results.errors, photoName .. " : encodage echoue (" .. (encErr or "?") .. ")")
            results.failed = results.failed + 1
            goto continue
        end

        -- 3. Appel Claude
        progress:setCaption(string.format("[%d/%d] Claude AI : %s", i, #photos, photoName))
        local xmpContent, apiErr

        if config.directApi then
            xmpContent, apiErr = callClaudeDirectly(
                imageBase64, refBase64, config.mode, config.prompt, config.apiKey)
        else
            xmpContent, apiErr = callClaudeViaServer(
                imageBase64, refBase64, config.mode, config.prompt, config.serverUrl)
        end

        if not xmpContent then
            table.insert(results.errors, photoName .. " : " .. (apiErr or "erreur API inconnue"))
            results.failed = results.failed + 1
            goto continue
        end

        -- Validation minimale
        if not xmpContent:find("crs:") then
            logger:error("Reponse non-XMP pour " .. photoName .. " : " .. xmpContent:sub(1, 400))
            table.insert(results.errors, photoName .. " : reponse invalide (pas de parametres crs:)")
            results.failed = results.failed + 1
            goto continue
        end

        -- 4. Application dans Lightroom
        progress:setCaption(string.format("[%d/%d] Application : %s", i, #photos, photoName))
        local ok, applyErr, xmpPath = applyXmpToPhoto(photo, xmpContent, tmpDir)

        if ok then
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
            table.insert(results.errors, photoName .. " : application echouee (" .. (applyErr or "?") .. ")")
            results.failed = results.failed + 1
        end

        ::continue::
    end

    progress:done()
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
    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
        LrDialogs.message(
            "Claude Photo AI",
            "Selectionnez au moins une photo dans Lightroom avant de lancer le plugin.",
            "warning")
        return
    end

    local config = showMainDialog(photos)
    if not config then return end

    processPhotos(photos, config)
end)
