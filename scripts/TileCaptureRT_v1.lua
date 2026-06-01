-- needs UE4SS experimental-latest (with FText support)
-- to adjust exposure, see SetIntensity and r.TonemapperGamma calls below

local UEHelpers = require("UEHelpers")

local captureWidgetBanner = 'TileCaptureRT loaded. Press Ctrl+F to capture.'

local chunkSize = 25600 -- do not change this

-- these locations use coordinates as an interest point (roughly in the center), aligned to chunk boundaries

local locations = {
    lifepod = { left = -337193, top = 433406, alt = 1000, size = chunkSize },
    planetary = { left = -222771, top = 432320, alt = 500, size = chunkSize*2 },
    turbine = { left = -160717, top = 436872, alt = 500, size = chunkSize*2 },
    the_pit = { left = -344231.96875, top = 449815.84375, alt=1000, size = chunkSize},
    glyph = { left= -232185.984375, top=431499.40625, alt=500, size= chunkSize*3},
    all = { left = -222771, top = 432320, alt = 1000, size = 409600 },
}

--local cc = locations.lifepod
--local cc = locations.turbine
--local cc = locations.planetary
--local cc = locations.the_pit
--local cc = locations.glyph
local cc = locations.all

local tileSize = 2048 -- Resolution of the final exported image per chunk (e.g., 512x512px)
local streamingDelay = 4000 -- delay to wait for chunk to load after teleporting pawn
local loadDistanceThreshold = chunkSize*4 -- distance from last load point before triggering another load wait

local SavePath = "C:\\Temp\\Capture\\"

local Altitude = cc.alt
local size = cc.size

-- local bb = {left=cc.left-cc.size/2, top=cc.top-cc.size/2, right=cc.left+cc.size/2, bottom=cc.top+cc.size/2}
-- bb = {left=-382366, top=361996, right=-85030, bottom=502627} -- global map/doesn't work now

local captureStopped = true

local forceOverwrite = false

-- Table to track all hidden dynamic actors so we can restore them later
local hiddenDynamicActors = {}

function fileExists(filename)
    local file = io.open(filename, "r")
    if file then
        file:close()
        return true
    else
        return false
    end
end

-- Function to find and hide all streamed-in movable actors safely
local function hideMovableActors()
    local actors = FindAllOf("Actor")
    if actors then
        for _, actor in ipairs(actors) do
            -- Check if the actor is movable and currently visible
            if actor:IsValid() and not actor.bHidden then
                local moveComp = actor:GetComponentByClass("MovementComponent")
                if moveComp and moveComp:IsValid() then

                    local className = actor:GetClass():GetName()
                    -- Exclude essential actors, lights, sky, and cameras from being hidden
                    if not string.find(className, "Light") and not string.find(className, "Sky") and not string.find(className, "PlayerController") and not string.find(className, "SceneCapture") then
                        actor:SetActorHiddenInGame(true)
                        table.insert(hiddenDynamicActors, actor)
                    end

                end
            end
        end
    end
end

local function forceLOD0()
    local meshes = FindAllOf("StaticMeshComponent")
    for _,m in ipairs(meshes) do
        if m:IsValid() then
            m:SetForcedLodModel(1)

            m.MinLOD = 0
            m.StreamingDistanceMultiplier = 100
            m.bForceMipStreaming = true
            m.NeverDistanceCull = true
            m.CachedMaxDrawDistance = 0

            if m.bEnableNanite then
                -- Force Nanite to use highest detail
                m.ForcedLodModel = 1  -- LOD0
                m.NaniteMaxPixelsPerEdge = 0.1  -- Smaller = more triangles
                m.NaniteMinPixelsPerEdge = 0    -- Force maximum detail

                m.NaniteFallbackRelativeError = 0.5  -- Force fallback quality
                m.bForceNaniteRepresentation = true   -- Ensure Nanite is used

            end

        end
    end

    local landscapes = FindAllOf("LandscapeComponent")
    for _,l in ipairs(landscapes) do
        if l:IsValid() then
            l.ForcedLOD = 0
            l.LODDistributionSetting = 3
            l.CachedMaxDrawDistance = 0
            l.LODBias = -10
        end
    end

    local hism = FindAllOf("HierarchicalInstancedStaticMeshComponent")
    for _,h in ipairs(hism) do
        if h:IsValid() then
            h:SetForcedLodModel(1)
            h.InstanceLODDistanceScale = 100
            h.CachedMaxDrawDistance = 0
        end
    end
end

local function toggleEffects(bHide)
    if bHide then
        hiddenDynamicActors = {} -- Reset the tracker on capture start
    end

    local names = {
        'WaterBodyOceanComponent',
        'ExponentialHeightFogComponent',
    }

    for _, name in ipairs(names) do
        local o = FindFirstOf(name)
        if o and o:IsValid() and o.SetHiddenInGame then
            o.SetHiddenInGame(bHide, true)
        end
    end

    local timeComponent = FindFirstOf("UWETimeOfDayComponent")
    if timeComponent and timeComponent:IsValid() then
        timeComponent:SetTimeOfDay(0.5)
        timeComponent:FreezeTime(bHide)
    end
    
    local sky = FindFirstOf("BP_UWESky_C")
    if sky and sky:IsValid() and sky.SunDirectionalLight then
        local light = sky.SunDirectionalLight
        light:SetIntensity(bHide and 60.0 or 10.0)

        
        -- light.IndirectLightingIntensity = 30.0
        -- light.SpecularScale = 0.02
        -- light.VolumetricScatteringIntensity = 0

        if sky.SkyLight then
            --sky.SkyLight:SetIntensity(bHide and 1.5 or 1.0)
        end

    end

    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local world = pc:GetWorld()
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if world and world:IsValid() and ksl and ksl:IsValid() then
            -- note that not all command work in script runtime, most need actual user input in console
            local cmds0 = {
                --'r.BloomQuality 0',
                --'r.Tonemapper.Quality 0',
                --'r.TonemapperGamma 6',

                'r.AmbientOcclusionLevels 0',
                'r.ContactShadows 0',
                'r.DistanceFieldAO 0',
                'r.Shadow.FilterMethod 1', -- 3 for PCSS (softer, lighter-looking shadows)
                'r.Shadow.MaxCSMResolution 512', --(lower resolution = blurrier = lighter)
                'r.Shadow.CSM.MaxCascades 1',
                'r.Shadow.RadiusThreshold 0.001', --to 0.5 (higher threshold = fewer shadows cast)

                'r.ForceLOD 0', -- not recognized
                'r.ParticleLODBias -10',
                'r.HLOD 0', -- not recognized
                'r.HLOD.DistanceScale 0', -- not recognized

                'r.LandscapeLODDistributionScale 3',
                'r.LandscapeLOD0DistributionScale 3',
                'r.LandscapeLODBias -3',

                'r.ViewDistanceScale 3', -- recognized but doesn't do shit
                'foliage.ForceLOD 0',
                'r.Nanite.MaxPixelsPerEdge 0.5',
                'r.LandscapeLOD0ScreenSize 10',
                'r.Streaming.FullyLoadUsedTextures 1',
                'r.Streaming.UseAllMips 1',

                'r.Nanite.MaxPixelsPerEdge 0.25',
                'r.Nanite.ViewMeshLODBias.Offset -4',
                'r.ScreenPercentage 200',
                'r.ViewDistanceScale 100',

            }

            local cmds = {
            }

            for _, cmd in ipairs(cmds) do
                ksl:ExecuteConsoleCommand(world, cmd, nil)
            end


            ksl:ExecuteConsoleCommand(world, "slomo " .. (bHide and "0.00000001" or "1"), nil)
        end
    end

    -- Restore hidden dynamic objects when stopping the capture
    if not bHide then
        for _, actor in ipairs(hiddenDynamicActors) do
            if actor and actor:IsValid() then
                actor:SetActorHiddenInGame(false)
            end
        end
        hiddenDynamicActors = {}
    end
end

-- widget

local VISIBLE = 4
local HIDDEN = 2

local captureWidget = FindObject("UserWidget", "captureWidget")
local captureWidgetTextBlock = FindObject("TextBlock", "captureWidgetTextBlock")

local function FLinearColor(R,G,B,A) return {R=R,G=G,B=B,A=A} end
local function FSlateColor(R,G,B,A) return {SpecifiedColor=FLinearColor(R,G,B,A), ColorUseRule=0} end

local function setText(text)
    captureWidgetTextBlock = FindObject("TextBlock", "captureWidgetTextBlock") -- required
    if captureWidgetTextBlock and captureWidgetTextBlock:IsValid() and FText then
        captureWidgetTextBlock:SetText(FText(text))
    end
end

local function _print(s) 
    setText(s)
    print('[TileCaptureRT] ' .. s)
end

local function setAlignment(slot, alignment)
    local b = 0
    local alignments = {
        center = {anchor = {0.5, 0.5}, align = {0.5, 0.5}, pos = {0, 0}},
        top = {anchor = {0.5, 0}, align = {0.5, 0}, pos = {0, b}},
        bottom = {anchor = {0.5, 1}, align = {0.5, 1}, pos = {0, -b}},
        topleft = {anchor = {0, 0}, align = {0, 0}, pos = {b, b}},
        topright = {anchor = {1, 0}, align = {1, 0}, pos = {-b, b}},
        bottomleft = {anchor = {0, 1}, align = {0, 1}, pos = {b, -b}},
        bottomright = {anchor = {1, 1}, align = {1, 1}, pos = {-b, -b}}
    }
    local a = alignments[alignment] or alignments.center
    slot:SetAnchors({Minimum = {X = a.anchor[1], Y = a.anchor[2]}, Maximum = {X = a.anchor[1], Y = a.anchor[2]}})
    slot:SetAlignment({X = a.align[1], Y = a.align[2]})
    slot:SetPosition({X = a.pos[1], Y = a.pos[2]})
end

local function createTextWidget()
    if captureWidget and captureWidget:IsValid() then
        return
    end

    local gi = UEHelpers.GetGameInstance()
    widget = StaticConstructObject(StaticFindObject("/Script/UMG.UserWidget"), gi, FName("captureWidgetUserWidget"))
    widget.WidgetTree = StaticConstructObject(StaticFindObject("/Script/UMG.WidgetTree"), widget, FName("captureWidgetSimpleTree"))

    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), widget.WidgetTree, FName("captureWidgetCanvas"))
    widget.WidgetTree.RootWidget = canvas

    local bg = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), canvas, FName("captureWidgetBG"))
    bg:SetBrushColor(FLinearColor(0,0,0,0.25))
    bg:SetPadding({Left = 15, Top = 10, Right = 15, Bottom = 10})

    local slot = canvas:AddChildToCanvas(bg)
    slot:SetAutoSize(true)
    setAlignment(slot, alignment or 'topright')

    local text = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), bg, FName("captureWidgetTextBlock"))
    text.Font.Size = 24
    text:SetColorAndOpacity(FSlateColor(1,1,1,1))
    text:SetShadowOffset({X = 1, Y = 1})
    text:SetShadowColorAndOpacity(FLinearColor(0,0,0,0.5))
    text:SetText(FText(captureWidgetBanner))
    text:SetVisibility(VISIBLE)
    textBlock = text
    bg:SetContent(text)

    bg:SetVisibility(VISIBLE)
    widget:SetVisibility(VISIBLE)

    widget:AddToViewport(99)

    captureWidget = widget
end

-- /widget

local function TakeOrthoByRenderTarget()
    local PC = FindFirstOf("PlayerController")
    if not PC or not PC:IsValid() then return end

    local World = PC:GetWorld()
    local KismetRenderingLibrary = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local CaptureClass = StaticFindObject("/Script/Engine.SceneCapture2D")

    if not KismetRenderingLibrary or not CaptureClass then
        print("Failed to find Rendering Library or Capture Class.")
        return
    end

    local sizeChunks = math.ceil(size / chunkSize)

    local cx = math.floor(cc.left / chunkSize)
    local cy = math.floor(cc.top / chunkSize)

    local half = math.floor(sizeChunks / 2)

    local minIndexX = cx - half
    local minIndexY = cy - half

    local maxIndexX = minIndexX + sizeChunks - 1
    local maxIndexY = minIndexY + sizeChunks - 1

    local cols = sizeChunks
    local rows = sizeChunks
    local totalChunks = cols * rows

    local minX = minIndexX * chunkSize
    local minY = minIndexY * chunkSize


    local Rotation = { Pitch = 90.0, Yaw = 0.0, Roll = 0.0 }

    local actorZ = Altitude

    -- 1. Spawn the hidden Capture Actor
    local CaptureActor = World:SpawnActor(CaptureClass, { X = 0, Y = 0, Z = ActorZ }, Rotation)
    if not CaptureActor or not CaptureActor:IsValid() then return end

    local CaptureComp = CaptureActor.CaptureComponent2D
    CaptureComp:K2_SetWorldRotation({ Pitch = -90.0, Yaw = -90.0, Roll = 0.0 }, false, {}, true)
    CaptureComp:K2_SetRelativeLocation({X = 0, Y = 0, Z = 0 }, false, {}, true)

    -- 2. Create the Render Target
    local RT = KismetRenderingLibrary:CreateRenderTarget2D(World, tileSize, tileSize, 2, { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }, false, false)

    -- 3. Configure the Capture Component
    CaptureComp.TextureTarget = RT
    CaptureComp.ProjectionType = 1 -- Orthographic
    CaptureComp.OrthoWidth = chunkSize -- Camera covers exactly one chunk perfectly
    CaptureComp.CaptureSource = 2  -- 2-FinalColorLDR, 3 - RawHDR (removes vignetting)
    CaptureComp.bCaptureEveryFrame = false
    CaptureComp.bCaptureOnMovement = false

    --CaptureComp.LODDistanceFactor = 0.01 -- near-forced LOD0 behavior
    --CaptureComp.MaxViewDistanceOverride = 0
    --CaptureComp.bUseFieldOfViewForLOD = false

    --CaptureComp.OrthoNearPlane = -100000
    --CaptureComp.OrthoFarPlane = 100000
    --CaptureComp.PostProcessSettings = {}
    --CaptureComp.PostProcessBlendWeight = 0
    --CaptureComp.bUseCustomProjectionMatrix = false

    -- Attach the Streaming Source directly to the CaptureActor
    local StreamingSourceClass = StaticFindObject("/Script/Engine.WorldPartitionStreamingSourceComponent")
    if StreamingSourceClass then
        local StreamingComp = CaptureActor:AddComponentByClass(StreamingSourceClass, false, {}, false)
        if StreamingComp then
            StreamingComp.DefaultLoadingRange = loadDistanceThreshold * 2 -- Cover a wide area around the camera
            StreamingComp.Priority = 1
            StreamingComp.bEnableStreaming = true
            StreamingComp:EnableStreamingSource()
            -- print("[MapCapture] Attached WorldPartitionStreamingSource to Camera.")
        end
    end

    _print(string.format("Saving %d chunk(s) (%dp) to %s...", totalChunks, tileSize, SavePath))

    local chunkIndex = 0
    local lastLoc = nil

    local function CaptureNextChunk()
        if captureStopped or chunkIndex >= totalChunks then
            toggleEffects(false)
            captureStopped = true
            _print("Capture finished. Ctrl+R to reload script, Ctrl+F to capture.")
            return
        end

        local c = chunkIndex % cols
        local r = math.floor(chunkIndex / cols)

        local CenterX = minX + (c + 0.5) * chunkSize
        local CenterY = minY + (r + 0.5) * chunkSize

        ExecuteInGameThread(function()

            local loc = { X = CenterX, Y = CenterY, Z = Altitude}
            
            -- Move Camera (The streaming source component is attached and moves with it)
            CaptureActor:K2_SetActorLocation(loc, false, {}, true)

            local ct = math.floor(CenterX/chunkSize)
            local rt = math.floor(CenterY/chunkSize)

            local FileName = string.format("Chunk_%d_%dp_%d_%d.png", chunkSize, tileSize, ct, rt)

            local fullPath = SavePath .. FileName

            if not forceOverwrite and fileExists(fullPath) then
                ExecuteInGameThread(function()
                    chunkIndex = chunkIndex + 1
                    CaptureNextChunk()
                end)
                return
            end

            -- Check if we are far enough from the last loaded center to warrant a pause
            local dist = 999999
            if lastLoc then
                dist = math.sqrt((CenterX - lastLoc.X)^2 + (CenterY - lastLoc.Y)^2)
            end

            local delayTime = 100 -- brief delay even if 0 to ensure transform update

            -- If we moved beyond our threshold, apply the streaming delay
            if streamingDelay > 0 and dist > loadDistanceThreshold then
                -- print(string.format("[MapCapture] Waiting for chunk to stream (Distance: %.0f > %.0f)...", dist, loadDistanceThreshold))
                lastLoc = loc
                delayTime = streamingDelay
            end

            _print(string.format("Saving %d/%d [%s]. Ctrl+F to stop.", chunkIndex + 1, totalChunks, FileName))

            -- hideMovableActors() -- ensure streamed-in dynamic objects are hidden right before the shot

            -- Wait for streaming, then capture
            CaptureActor:FlushNetDormancy()

            ExecuteWithDelay(delayTime, function()
                ExecuteInGameThread(function()
                    CaptureActor:SetActorHiddenInGame(false)-- force visibility update pass
                    CaptureComp:CaptureScene()
                    CaptureComp:CaptureScene()
                    KismetRenderingLibrary:ExportRenderTarget(World, RT, SavePath, FileName)
                    chunkIndex = chunkIndex + 1
                    CaptureNextChunk()
                end)
            end)
        end)
    end

    CaptureNextChunk()
end

RegisterKeyBind(Key.F, { ModifierKey.CONTROL }, function()
    captureStopped  = not captureStopped
    if captureStopped then
        return
    end

    _print("Capture started!")

    toggleEffects(true)
    ExecuteWithDelay(4000, function() -- wait 4 sec for autoexposure to settle
        ExecuteInGameThread(function()
            --forceLOD0() -- doesn't do shit as figures
            TakeOrthoByRenderTarget()
        end)
    end)
end)

local function updateWidget()
    if captureWidget and captureWidget:IsValid() then
        if not captureWidget:IsInViewport() then captureWidget:AddToViewport(99) end
    end
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    createTextWidget()
end)

updateWidget()
_print('Reloading...')
ExecuteWithDelay(250,function()
    _print(captureWidgetBanner)
end)
