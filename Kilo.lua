
-- Velocity based tail physics (reanimated tail UGC).
-- Tail asset 6472198409: the tail already equipped on the player is used (no -gh).

local TAIL_ID = 6472198409

-- Swing: how far (radians) the tail swings per stud/second of movement
local YAW_PER_SPEED = 0.04 -- moving sideways -> tail swings to the opposite side
local PITCH_PER_SPEED = 0.025 -- moving forward/back -> tail lifts/drops
local LIFT_PER_SPEED = 0.02 -- moving up/down -> tail drops/lifts
local TURN_GAIN = 0.06 -- turning drags the tail the other way
local MAX_YAW = 1.0
local MAX_PITCH = 0.8

-- Spring (lower damping = more bounce)
local STIFFNESS = 30
local DAMPING = 5

-- Idle wag (slight)
local IDLE_SPEED = 3 -- studs/second under which the tail counts as idle
local WAG_ANGLE = math.rad(8)
local WAG_SPEED = 3.5 -- radians/second

local Players = game:GetService("Players")
local rs = game:GetService("RunService")
local heartbeat = rs.Heartbeat
local stepped = rs.RenderStepped
local ti = table.insert
local netless_Y = Vector3.new(0, -30, 0)
local v3_101 = Vector3.new(1, 0, 1)
local inf = math.huge

local lp = Players.LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()

-- Remember where the reset happened so we can teleport back there after respawning.
local resetCFrame = char:GetPivot()

----------------------------------------------------------------------
-- Command sending (chat)
----------------------------------------------------------------------

local function sendCmd(text)
    game:GetService("TextChatService").TextChannels.RBXGeneral:SendAsync(text)
end

----------------------------------------------------------------------
-- Break joints, wait for the respawn, then -net
----------------------------------------------------------------------

char:BreakJoints()

char = lp.CharacterAdded:Wait()

local root = char:WaitForChild("HumanoidRootPart")
local hum = char:WaitForChild("Humanoid")

task.wait(1) -- let the accessories load in

local function tpBack()
    char:PivotTo(resetCFrame)
end

tpBack()

for _, part in pairs(char:GetDescendants()) do
    if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
        part.Massless = false
    end
end

sendCmd("-net")

task.wait(1)

----------------------------------------------------------------------
-- Netless alignment
----------------------------------------------------------------------

local function getNetlessVelocity(realPartVelocity)
    if not realPartVelocity then
        return Vector3.zero
    end

    if math.abs(realPartVelocity.Y) > 1 then
        return realPartVelocity * (25.1 / realPartVelocity.Y)
    end

    realPartVelocity = realPartVelocity * v3_101
    local mag = realPartVelocity.Magnitude

    if mag > 1 then
        realPartVelocity = realPartVelocity * (100 / mag)
    end

    return realPartVelocity + netless_Y
end

local function align(Part0, Part1)
    Part0.CustomPhysicalProperties =
        PhysicalProperties.new(0.0001, 0.0001, 0.0001, 0.0001, 0.0001)

    Part0.CFrame = Part1.CFrame

    local att0 = Instance.new("Attachment", Part0)
    att0.Name = "att0_" .. Part0.Name

    local att1 = Instance.new("Attachment", Part1)
    att1.Name = "att1_" .. Part1.Name

    local ape = Instance.new("AlignPosition", att0)
    ape.Name = "AlignPositionRtrue"
    ape.ApplyAtCenterOfMass = false
    ape.MaxForce = inf
    ape.MaxVelocity = inf
    ape.ReactionForceEnabled = false
    ape.Responsiveness = 200
    ape.Attachment0 = att0
    ape.Attachment1 = att1
    ape.RigidityEnabled = true

    local ao = Instance.new("AlignOrientation", att0)
    ao.Name = "AlignOrientation"
    ao.MaxAngularVelocity = inf
    ao.MaxTorque = inf
    ao.PrimaryAxisOnly = false
    ao.ReactionTorqueEnabled = false
    ao.Responsiveness = 200
    ao.Attachment0 = att0
    ao.Attachment1 = att1
    ao.RigidityEnabled = true

    local realVelocity = Vector3.new(0, 30, 0)

    local steppedcon = stepped:Connect(function()
        if Part0 and Part0.Parent then
            Part0.Velocity = realVelocity
        end
    end)

    local heartbeatcon = heartbeat:Connect(function()
        if Part0 and Part0.Parent then
            realVelocity = Part0.Velocity
            Part0.Velocity = getNetlessVelocity(realVelocity)
        end
    end)

    Part0.Destroying:Connect(function()
        steppedcon:Disconnect()
        heartbeatcon:Disconnect()
    end)
end

----------------------------------------------------------------------
-- Find the tail (equipped -> use it, otherwise load it with -gh)
----------------------------------------------------------------------

local function isTailEquipped()
    local ok, desc = pcall(function()
        return hum:GetAppliedDescription()
    end)

    if ok and desc then
        for _, info in ipairs(desc:GetAccessories(true)) do
            if info.AssetId == TAIL_ID then
                return true
            end
        end
    end

    return false
end

-- Accessory instances don't expose their asset id, so match by the catalog name first and
-- fall back to the accessories sitting on the back/waist.
local function findEquippedTail()
    local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(TAIL_ID, Enum.InfoType.Asset)
    end)

    local accessories = {}

    for _, v in ipairs(char:GetChildren()) do
        if v:IsA("Accessory") and v:FindFirstChild("Handle") then
            ti(accessories, v)
        end
    end

    if ok and info and info.Name then
        local want = info.Name:lower()

        for _, acc in ipairs(accessories) do
            if acc.Name:lower() == want then
                return acc
            end
        end

        for _, acc in ipairs(accessories) do
            local name = acc.Name:lower()

            if name:find(want, 1, true) or want:find(name, 1, true) then
                return acc
            end
        end
    end

    for _, acc in ipairs(accessories) do
        local att = acc.Handle:FindFirstChildOfClass("Attachment")

        if att and (att.Name:find("Back") or att.Name:find("Waist")) then
            return acc
        end
    end

    return accessories[#accessories]
end

-- Always uses the tail that's already on the player (never -gh).
local tail = findEquippedTail()

if not isTailEquipped() then
    warn("Tail " .. TAIL_ID .. " doesn't look equipped; using the closest matching accessory.")
end

tpBack()

local handle = tail and tail:FindFirstChild("Handle")

if not handle then
    warn("Tail accessory not found.")
    return
end

----------------------------------------------------------------------
-- Rest position (where the tail normally sits on the body)
----------------------------------------------------------------------

local bodyPart, restRel, pivotRel

for _, att in ipairs(handle:GetChildren()) do
    if att:IsA("Attachment") then
        for _, part in ipairs(char:GetChildren()) do
            local bodyAtt = part:IsA("BasePart") and part:FindFirstChild(att.Name)

            if bodyAtt and bodyAtt:IsA("Attachment") then
                bodyPart = part
                -- handle CFrame relative to the body part when the attachments are matched up
                restRel = bodyAtt.CFrame * att.CFrame:Inverse()
                pivotRel = bodyAtt.CFrame.Position
                break
            end
        end
    end

    if bodyPart then
        break
    end
end

if not bodyPart then
    -- No matching attachment: just keep it where it currently is relative to the root.
    bodyPart = root
    restRel = root.CFrame:ToObjectSpace(handle.CFrame)
    pivotRel = restRel.Position
end

-- Detach the current weld(s) so the handle is free to be driven by the physics below.
for _, v in ipairs(tail:GetDescendants()) do
    if v:IsA("Weld") or v:IsA("WeldConstraint") or v:IsA("Constraint") then
        v:Destroy()
    end
end

handle.Massless = true
handle.CanCollide = false
handle.CanTouch = false
handle.CanQuery = false

local anchor = Instance.new("Part")
anchor.Name = "TailAnchor"
anchor.Size = Vector3.new(0.2, 0.2, 0.2)
anchor.Transparency = 1
anchor.Anchored = true
anchor.CanCollide = false
anchor.CanTouch = false
anchor.CanQuery = false
anchor.CFrame = bodyPart.CFrame * restRel
anchor.Parent = workspace

align(handle, anchor)

----------------------------------------------------------------------
-- Tail physics
----------------------------------------------------------------------

local yaw = { pos = 0, vel = 0 }
local pitch = { pos = 0, vel = 0 }
local idle = 1
local t = 0

local function spring(s, target, dt)
    local acc = (target - s.pos) * STIFFNESS - s.vel * DAMPING
    s.vel += acc * dt
    s.pos += s.vel * dt
end

local con
con = rs.PreSimulation:Connect(function(dt)
    if not handle.Parent or not bodyPart.Parent or not root.Parent then
        con:Disconnect()
        anchor:Destroy()
        return
    end

    -- A lag spike would otherwise turn into one huge step.
    dt = math.min(dt, 1 / 20)
    t += dt

    local rootCF = root.CFrame
    local rootRot = rootCF.Rotation

    -- Velocity in the root's own space: X = right, Y = up, Z = back.
    local vel = root.AssemblyLinearVelocity
    local localVel = rootCF:VectorToObjectSpace(vel)
    local turn = root.AssemblyAngularVelocity.Y

    -- Moving left (-X) swings the tail right (+X), and so on for every direction.
    local yawTarget = math.clamp(-localVel.X * YAW_PER_SPEED - turn * TURN_GAIN, -MAX_YAW, MAX_YAW)
    local pitchTarget = math.clamp(
        localVel.Z * PITCH_PER_SPEED + localVel.Y * LIFT_PER_SPEED,
        -MAX_PITCH,
        MAX_PITCH
    )

    spring(yaw, yawTarget, dt)
    spring(pitch, pitchTarget, dt)

    -- Slight wag, fading in when standing still and out when moving.
    local idleTarget = 1 - math.clamp(vel.Magnitude / IDLE_SPEED, 0, 1)
    idle += (idleTarget - idle) * math.min(1, dt * 4)

    local wag = math.sin(t * WAG_SPEED) * WAG_ANGLE * idle

    local swing = rootRot
        * CFrame.Angles(pitch.pos, yaw.pos + wag, 0)
        * rootRot:Inverse()

    local base = bodyPart.CFrame
    local pivot = base:PointToWorldSpace(pivotRel)
    local rotated = CFrame.new(pivot) * swing * CFrame.new(-pivot) * (base * restRel)

    anchor.CFrame = rotated
    handle.CFrame = rotated
    handle.AssemblyAngularVelocity = Vector3.zero
end)
