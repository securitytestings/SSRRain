local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local templates = ReplicatedStorage:WaitForChild("SSRPuddles"):GetChildren()
assert(#templates > 0, "SSRPuddles folder is empty")

local DEBUG = false

local SPAWN_DISTANCE = 12
local SCATTER = 6             -- random sideways offset so puddles don't line up
local RAY_HEIGHT = 20         -- start the ray above the target, so slopes and steps still work
local LIFT = -1.2             -- tiny gap to avoid z-fighting with the ground
local MAX_HEIGHT_VARIANCE = 1 -- studs of allowed bumpiness under the puddle
local SAMPLE_FRACTION = 0.6   -- ring sits at 60% of the footprint radius, not the very edge

local SPAWN_INTERVAL = 0.4
local MAX_PUDDLES = 40
local DESPAWN_DISTANCE = 30   -- puddles further than this from the player get destroyed

local ALLOWED = {
	[Enum.Material.Mud] = true,
	[Enum.Material.Asphalt] = true,
	[Enum.Material.Concrete] = true,
	[Enum.Material.Slate] = true
}

local puddleFolder = Instance.new("Folder")
puddleFolder.Name = "ActivePuddles"
puddleFolder.Parent = workspace

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local function debugPrint(...)
	if DEBUG then
		print("[Puddles]", ...)
	end
end


-- Axis-aligned world bounds of every part in the model,
-- ignoring PrimaryPart orientation entirely.
local function worldBounds(model: Model): (Vector3, Vector3)
	local minV = Vector3.one * math.huge
	local maxV = Vector3.one * -math.huge
	local found = false

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			found = true
			local cf, s = d.CFrame, d.Size
			local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
			-- half-extent of a rotated box along each world axis
			local half = Vector3.new(
				(math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z) / 2,
				(math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z) / 2,
				(math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z) / 2
			)
			minV = minV:Min(cf.Position - half)
			maxV = maxV:Max(cf.Position + half)
		end
	end

	if not found then return nil end
	return minV, maxV
end


local function sampleGround(center: Vector3, radius: number, params: RaycastParams)
	-- center + a ring of 6 points around it
	local points = { center }
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		table.insert(points, center + Vector3.new(math.cos(a), 0, math.sin(a)) * radius)
	end

	local highest, lowest = -math.huge, math.huge
	local centerHit
	for i, p in points do
		local hit = workspace:Raycast(
			p + Vector3.yAxis * RAY_HEIGHT,
			Vector3.yAxis * -(RAY_HEIGHT * 2),
			params
		)
		if not hit then return nil, "ground sample missed" end
		if hit.Normal.Y < 0.9 then return nil, "ground sample too steep" end -- any bad sample rejects the spot
		if i == 1 then centerHit = hit end
		highest = math.max(highest, hit.Position.Y)
		lowest = math.min(lowest, hit.Position.Y)
	end

	if highest - lowest > MAX_HEIGHT_VARIANCE then
		return nil, string.format("ground too bumpy (%.2f studs)", highest - lowest)
	end
	return centerHit, highest
end


local function spawnPuddle(): Model?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	-- Picks a point in front of the player, with some scatter
	local flat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if flat.Magnitude < 0.01 then return nil end -- looking straight up/down, no usable direction
	local flatLook = flat.Unit
	local right = flatLook:Cross(Vector3.yAxis)
	local target = root.Position
		+ flatLook * SPAWN_DISTANCE
		+ right * (math.random() * 2 - 1) * SCATTER

	-- Casts straight down to find the ground
	params.FilterDescendantsInstances = { char, puddleFolder }
	local hit = workspace:Raycast(
		target + Vector3.yAxis * RAY_HEIGHT,
		Vector3.yAxis * -(RAY_HEIGHT * 2),
		params
	)
	if not hit then
		debugPrint("rejected: no ground under target")
		return nil
	end
	if hit.Normal.Y < 0.9 then
		debugPrint("rejected: slope too steep")
		return nil
	end
	if not ALLOWED[hit.Material] then
		debugPrint("rejected material:", hit.Material)
		return nil
	end

	-- clones templates, will be reworked
	local puddle = templates[math.random(#templates)]:Clone()
	local baseRot = puddle:GetPivot().Rotation   -- authored orientation, no position

	-- Measure bottom offset with the authored orientation, pivot at origin
	puddle:PivotTo(baseRot)
	local boxCF, boxSize = puddle:GetBoundingBox()
	local bottomOffset = boxCF.Position.Y - boxSize.Y / 2   -- pivot is at Y = 0 now

	-- Ground check (on failure, the 2nd return value is the reason string)
	local radius = math.max(boxSize.X, boxSize.Z) / 2
	local groundHit, groundYOrReason = sampleGround(target, radius, params)
	if not groundHit then
		debugPrint("rejected:", groundYOrReason)
		puddle:Destroy() -- don't leak the unused clone
		return nil
	end

	-- Final placement: world-space spin first, then the authored rotation
	local yaw = math.random() * math.pi * 2
	local pos = Vector3.new(target.X, groundYOrReason + LIFT - bottomOffset, target.Z)
	puddle:PivotTo(CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * baseRot)

	puddle.Parent = puddleFolder
	return puddle
end


-- Destroys puddles the player has walked away from.
-- Uses flat (XZ) distance so height differences don't matter.
local function cleanupFarPuddles()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local origin = root.Position * Vector3.new(1, 0, 1)
	for _, puddle in puddleFolder:GetChildren() do
		local p = puddle:GetPivot().Position * Vector3.new(1, 0, 1)
		if (p - origin).Magnitude > DESPAWN_DISTANCE then
			puddle:Destroy()
		end
	end
end


task.spawn(function()
	while true do
		cleanupFarPuddles() -- free up slots first, then try to spawn
		if #puddleFolder:GetChildren() < MAX_PUDDLES then
			spawnPuddle()
		end
		task.wait(SPAWN_INTERVAL)
	end
end)
