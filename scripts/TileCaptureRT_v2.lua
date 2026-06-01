local UEHelpers = require("UEHelpers")

-- local chunkSize = 6400

local chunkSize = 9375 -- 300k bounds / 32

local savePath = "C:\\Temp\\Capture\\"

local locations = {
    lifepod = { left = -337193, top = 433406, alt = 1000, size = chunkSize },
    turbine = { left = -160717, top = 436872, alt = 500, size = chunkSize * 2 },
    bigpit = { left = -344231.96875, top = 449815.84375, alt = 0, size = chunkSize },
    glyph = { left = -232185.984375, top = 431499.40625, alt = 5000, size = chunkSize },
    clam = { left = -345403, top = 465912, alt = 5000, size = chunkSize},
    all = { left = -222771, top = 432320, alt = 5000, size = 25600*11 },


    patch = {left=-281250, top=384375, alt=5000, size=1},
}

local cc = locations.all


local tileSize = 4096

local startDelay = 2500

local streamingDelay = 1000

local forceOverwrite = true

local bb = {left=cc.left-cc.size/2, top=cc.top-cc.size/2, right=cc.left+cc.size/2, bottom=cc.top+cc.size/2}
if cc==locations.all then
--  bb = { left = -388342, bottom = 511341, top = 363219, right = -73747 } -- wider
    bb = { left = -378513, bottom = 501704, top = 370297, right = -89602 } -- with chunks 12800 it's about 23x12, 276 chunks
end

local function fileExists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
end

local function setScene(bHide)
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
    end
    
    local sky = FindFirstOf("BP_UWESky_C")
    if sky and sky:IsValid() and sky.SunDirectionalLight then
        local light = sky.SunDirectionalLight
        light:SetIntensity(bHide and 100.0 or 10.0)
        if sky.SkyLight then
            sky.SkyLight:SetIntensity(bHide and 50.0 or 1.0) -- value 100 `gives blue-ish tint
        end
    end

    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local world = pc:GetWorld()
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")

        if world and world:IsValid() and ksl and ksl:IsValid() then

            local cmds = {
                "r.Streaming.FullyLoadUsedTextures 1",
                "r.Streaming.UseAllMips 1",

                "r.AmbientOcclusionLevels 1",
                "r.AmbientOcclusionRadiusScale 2",

                "r.ViewDistanceScale 5",
                "r.ScreenPercentage 200",
                "r.Nanite.ProjectEnabled 1",
                "r.Nanite.Tessellation 1",
                "r.Nanite.MaxPixelsPerEdge 0.1",
                "r.Nanite.ViewMeshLODBias.Offset -5",

                "r.Tonemapper.Quality 0",
                "r.TonemapperGamma 3.2",

                "r.Shadow.Virtual.Enable 0",    -- disable vt shadows
                "r.Shadow.DistanceScale 0.001", -- completely disable fucking csm shadows
            }

            for _, cmd in ipairs(cmds) do
                ksl:ExecuteConsoleCommand(world, cmd, nil)
            end

            ksl:ExecuteConsoleCommand(world, "slomo " .. (bHide and "0.00000001" or "1"), nil)
        end
    end
end

local function startCapture()
    local pc = FindFirstOf("PlayerController")
    local world = pc:GetWorld()

    local actors = FindAllOf("SceneCapture2D")
    if actors then
        for _, actor in ipairs(actors) do
            if actor and actor:IsValid() then
                actor:K2_DestroyActor()
            end
        end
    end

    local capClass = StaticFindObject("/Script/Engine.SceneCapture2D")
    local capActor = world:SpawnActor(capClass, { X = 0, Y = 0, Z = cc.alt }, { Pitch = 90, Yaw = 0, Roll = 0 })

    local cap = capActor.CaptureComponent2D
    cap:K2_SetWorldRotation({ Pitch = -90.0, Yaw = -90.0, Roll = 0.0 }, false, {}, true)

    cap.ProjectionType = 1
    cap.OrthoWidth = chunkSize
    cap.CaptureSource = 2 -- 2 -- postprocessed, 3 - rawHDR (need to remove vignetting)
    cap.bCaptureEveryFrame = false

    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local rt = krl:CreateRenderTarget2D(world, tileSize, tileSize, 2, { R = 0, G = 0, B = 0, A = 1 }, false, false)
    cap.TextureTarget = rt

    local scClass = StaticFindObject("/Script/Engine.WorldPartitionStreamingSourceComponent")
    if scClass then
        local sc = capActor:AddComponentByClass(scClass, false, {}, false)
        if sc then
            sc.DefaultLoadingRange = chunkSize*2
            sc.Priority = 256
            sc.bEnableStreaming = true
            sc:EnableStreamingSource()
        end
    end


    -- Add PostProcessComponent with default settings (NO vignette by default)
    local ppClass = StaticFindObject("/Script/Engine.PostProcessComponent")
    local postProcComp = capActor:AddComponentByClass(ppClass, false, {}, false)
    postProcComp.bEnabled = true
    postProcComp.bUnbound = true
    local postProcSettings = postProcComp.Settings
    postProcSettings.bOverride_VignetteIntensity = true
    postProcSettings.VignetteIntensity = 0.0

    -- Optional: Set blend weight to ensure it overrides global post process
    cap.PostProcessBlendWeight = 1.0


    local minGX = math.floor(bb.left / chunkSize)
    local maxGX = math.floor((bb.right - 1) / chunkSize)

    local minGY = math.floor(bb.top / chunkSize)
    local maxGY = math.floor((bb.bottom - 1) / chunkSize)

    local chunks = {}

    for gy = minGY, maxGY do
        for gx = minGX, maxGX do
            chunks[#chunks + 1] = {
                px = (gx + 0.5) * chunkSize,
                py = (gy + 0.5) * chunkSize,
                gx = gx,
                gy = gy
            }
        end
    end

    print("[CAPTURE] Capturing grid", maxGX-minGX+1, maxGY-minGY+1)


    local total = #chunks
    local i = 1

    local function step()
        if i > total then
            setScene(false)
            print("[CAPTURE] DONE")
            return
        end

        local c = chunks[i]

        local px = c.px
        local py = c.py
        local gx = c.gx
        local gy = c.gy

        local file = string.format("Chunk_%d_%dp_%d_%d.png", chunkSize, tileSize, gx, gy)

        if not forceOverwrite and fileExists(savePath .. file) then
            print(string.format("[CAPTURE] %d/%d SKIP %s", i, total, file))
            i = i + 1
            step()
            return
        end

        print(string.format("[CAPTURE] %d/%d %s", i, total, file))

        ExecuteInGameThread(function()
            capActor:K2_SetActorLocation({ X = px, Y = py, Z = cc.alt }, false, {}, true)
            ExecuteWithDelay(streamingDelay, function()
                ExecuteInGameThread(function()
                    cap:CaptureScene()
                    cap:CaptureScene()
                    krl:ExportRenderTarget(world, rt, savePath, file)
                    i = i + 1
                    step()
                end)
            end)
        end)
    end

    step()
end

RegisterKeyBind(Key.F, { ModifierKey.CONTROL }, function()
    setScene(true)
    ExecuteWithDelay(startDelay, function()
        ExecuteInGameThread(function()
            startCapture()
        end)
    end)
end)

