--[=[
RBXM IMPORTER - OPEN SOURCE RECONSTRUCTION
Version: 1.0.0
Purpose: Browse local executor files and import RBXM/RBXMX/RBXL/RBXLX when
         the current executor exposes a compatible local model-loading API.

No token, Firebase, login, license check, or remote authentication.

Compatibility note:
Executor APIs differ. This script detects common functions and tries known
call signatures. If your executor does not expose a compatible importer,
the UI still works but import will report the missing API. This is not the
original protected source and does not bypass Roblox/server permissions.
]=]

local ENV = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local function getAPI(name)
    local fn = ENV[name]
    if type(fn) == "function" then return fn end
    local ok, value = pcall(function() return _G[name] end)
    if ok and type(value) == "function" then return value end
    return nil
end

local function notify(title, message, duration)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = tostring(message),
            Duration = duration or 4
        })
    end)
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return false, "API tidak tersedia" end
    local args = table.pack(...)
    local ok, result = pcall(function()
        return fn(table.unpack(args, 1, args.n))
    end)
    if ok then return true, result end
    return false, tostring(result)
end

local function normalizePath(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("/+$", "")
    return path
end

local function basename(path)
    return tostring(path):match("([^/]+)$") or tostring(path)
end

local function extension(path)
    return (basename(path):match("%.([^%.]+)$") or ""):lower()
end

local function isModelFile(path)
    local ext = extension(path)
    return ext == "rbxm" or ext == "rbxmx" or ext == "rbxl" or ext == "rbxlx"
end

local function fileAPI()
    return {
        list = getAPI("listfiles"),
        read = getAPI("readfile"),
        isfile = getAPI("isfile"),
        isfolder = getAPI("isfolder"),
        makefolder = getAPI("makefolder"),
        write = getAPI("writefile"),
    }
end

local function listDirectory(path)
    local api = fileAPI()
    if not api.list then return nil, "Executor tidak menyediakan listfiles()." end
    local ok, result = safeCall(api.list, path)
    if not ok then return nil, result end
    if type(result) ~= "table" then return nil, "listfiles() tidak mengembalikan daftar file." end
    local entries = {}
    for _, item in ipairs(result) do
        if type(item) == "string" then
            local clean = normalizePath(item)
            local isDir = false
            if api.isfile then
                local fOk, fValue = safeCall(api.isfile, item)
                if fOk and fValue == true then isDir = false end
            end
            if api.isfolder then
                local dOk, dValue = safeCall(api.isfolder, item)
                if dOk and dValue == true then isDir = true end
            end
            table.insert(entries, {path = clean, name = basename(clean), isFolder = isDir})
        end
    end
    table.sort(entries, function(a, b)
        if a.isFolder ~= b.isFolder then return a.isFolder end
        return a.name:lower() < b.name:lower()
    end)
    return entries
end

local function importLocalFile(path)
    local ext = extension(path)
    local api = fileAPI()
    if not api.read then
        return false, "readfile() tidak tersedia di executor ini."
    end
    local readOK, content = safeCall(api.read, path)
    if not readOK then return false, "Gagal membaca file: " .. tostring(content) end
    if type(content) ~= "string" or #content == 0 then
        return false, "File kosong atau gagal dibaca."
    end

    local candidates = {}
    if ext == "rbxm" then
        table.insert(candidates, {"loadrbxm", path})
        table.insert(candidates, {"loadrbxm", content})
        table.insert(candidates, {"readrbxm", content})
        table.insert(candidates, {"loadasset", path})
    elseif ext == "rbxmx" or ext == "rbxlx" then
        table.insert(candidates, {"loadrbxmx", content})
        table.insert(candidates, {"loadrbxmx", path})
        table.insert(candidates, {"readrbxmx", content})
    elseif ext == "rbxl" then
        table.insert(candidates, {"loadrbxl", path})
        table.insert(candidates, {"loadrbxl", content})
        table.insert(candidates, {"loadrbxm", content})
    else
        return false, "Format tidak didukung: ." .. ext
    end

    local errors = {}
    for _, candidate in ipairs(candidates) do
        local apiName, argument = candidate[1], candidate[2]
        local fn = getAPI(apiName)
        if fn then
            local ok, result = safeCall(fn, argument)
            if ok and result ~= nil then
                if typeof(result) == "Instance" then
                    local parented = false
                    local parentTargets = {workspace}
                    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
                    if okCore and core then table.insert(parentTargets, core) end
                    for _, target in ipairs(parentTargets) do
                        local pOk = pcall(function() result.Parent = target end)
                        if pOk then parented = true break end
                    end
                    if not parented then
                        return false, "Model berhasil dimuat, tetapi tidak dapat dipasang ke Workspace/CoreGui."
                    end
                    return true, "Berhasil mengimpor " .. basename(path)
                elseif type(result) == "table" then
                    local inserted = 0
                    for _, object in pairs(result) do
                        if typeof(object) == "Instance" then
                            local pOk = pcall(function() object.Parent = workspace end)
                            if pOk then inserted += 1 end
                        end
                    end
                    if inserted > 0 then return true, "Berhasil memasang " .. inserted .. " object." end
                else
                    return true, "Fungsi " .. apiName .. " selesai dijalankan. Periksa Workspace."
                end
            else
                table.insert(errors, apiName .. ": " .. tostring(result))
            end
        end
    end

    local available = {}
    for _, name in ipairs({"loadrbxm", "readrbxm", "loadrbxmx", "readrbxmx", "loadrbxl", "loadasset"}) do
        if getAPI(name) then table.insert(available, name) end
    end
    if #available == 0 then
        return false, "Tidak ditemukan API import model pada executor. File terbaca, tetapi executor tidak menyediakan loadrbxm/loadrbxmx/loadasset yang kompatibel."
    end
    return false, "Semua metode import gagal:\n" .. table.concat(errors, "\n")
end

-- GUI ----------------------------------------------------------------------
local old = ENV.__RBXM_OPEN_SOURCE_GUI
if old then pcall(function() old:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = "RBXMImporterOpenSource"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local parent
local gethuiFn = getAPI("gethui")
if gethuiFn then
    local ok, value = safeCall(gethuiFn)
    if ok then parent = value end
end
if not parent then
    pcall(function() parent = game:GetService("CoreGui") end)
end
if not parent then parent = LocalPlayer:WaitForChild("PlayerGui") end
gui.Parent = parent
ENV.__RBXM_OPEN_SOURCE_GUI = gui

local C = {
    bg = Color3.fromRGB(15, 17, 23),
    panel = Color3.fromRGB(23, 26, 34),
    panel2 = Color3.fromRGB(31, 35, 45),
    line = Color3.fromRGB(52, 58, 72),
    text = Color3.fromRGB(238, 241, 248),
    muted = Color3.fromRGB(151, 160, 178),
    accent = Color3.fromRGB(125, 92, 255),
    green = Color3.fromRGB(65, 190, 130),
    red = Color3.fromRGB(230, 85, 95),
}

local function create(class, props, parentObject)
    local obj = Instance.new(class)
    for key, value in pairs(props or {}) do obj[key] = value end
    obj.Parent = parentObject
    return obj
end

local main = create("Frame", {
    Name = "Main", Size = UDim2.fromOffset(560, 430),
    Position = UDim2.new(0.5, -280, 0.5, -215),
    BackgroundColor3 = C.bg, BorderSizePixel = 0,
}, gui)
create("UICorner", {CornerRadius = UDim.new(0, 12)}, main)
create("UIStroke", {Color = C.line, Thickness = 1}, main)

local top = create("Frame", {Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = C.panel, BorderSizePixel = 0}, main)
create("UICorner", {CornerRadius = UDim.new(0, 12)}, top)
create("Frame", {Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -12), BackgroundColor3 = C.panel, BorderSizePixel = 0}, top)
create("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -90, 1, 0),
    Font = Enum.Font.GothamBold, Text = "RBXM IMPORTER  /  OPEN SOURCE", TextColor3 = C.text,
    TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
}, top)
local close = create("TextButton", {
    Size = UDim2.fromOffset(32, 30), Position = UDim2.new(1, -42, 0, 9),
    BackgroundColor3 = C.panel2, Text = "×", TextColor3 = C.text, TextSize = 20,
    Font = Enum.Font.GothamBold, AutoButtonColor = true,
}, top)
create("UICorner", {CornerRadius = UDim.new(0, 8)}, close)

local pathBox = create("TextBox", {
    Position = UDim2.fromOffset(14, 60), Size = UDim2.new(1, -116, 0, 34),
    BackgroundColor3 = C.panel2, TextColor3 = C.text, PlaceholderColor3 = C.muted,
    PlaceholderText = "Folder path, contoh: workspace atau /storage/emulated/0/Download",
    Text = "", ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)
create("UICorner", {CornerRadius = UDim.new(0, 7)}, pathBox)
create("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 8)}, pathBox)
local goBtn = create("TextButton", {
    Position = UDim2.new(1, -92, 0, 60), Size = UDim2.fromOffset(78, 34),
    BackgroundColor3 = C.accent, Text = "BUKA", TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.GothamBold, TextSize = 11,
}, main)
create("UICorner", {CornerRadius = UDim.new(0, 7)}, goBtn)

local search = create("TextBox", {
    Position = UDim2.fromOffset(14, 103), Size = UDim2.new(1, -28, 0, 32),
    BackgroundColor3 = C.panel, TextColor3 = C.text, PlaceholderColor3 = C.muted,
    PlaceholderText = "Cari file atau folder...", Text = "", ClearTextOnFocus = false,
    Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
}, main)
create("UICorner", {CornerRadius = UDim.new(0, 7)}, search)
create("UIPadding", {PaddingLeft = UDim.new(0, 10)}, search)

local list = create("ScrollingFrame", {
    Position = UDim2.fromOffset(14, 145), Size = UDim2.new(1, -28, 1, -207),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, ScrollBarThickness = 4,
    ScrollBarImageColor3 = C.accent, CanvasSize = UDim2.new(),
}, main)
create("UICorner", {CornerRadius = UDim.new(0, 8)}, list)
local layout = create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, list)
create("UIPadding", {PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7), PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7)}, list)

local status = create("TextLabel", {
    Position = UDim2.new(0, 14, 1, -51), Size = UDim2.new(1, -150, 0, 38),
    BackgroundTransparency = 1, Text = "Siap. Masukkan path folder lalu tekan BUKA.",
    TextColor3 = C.muted, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
    TextWrapped = true,
}, main)
local refresh = create("TextButton", {
    Position = UDim2.new(1, -124, 1, -48), Size = UDim2.fromOffset(110, 34),
    BackgroundColor3 = C.panel2, Text = "REFRESH", TextColor3 = C.text,
    Font = Enum.Font.GothamBold, TextSize = 10,
}, main)
create("UICorner", {CornerRadius = UDim.new(0, 7)}, refresh)

local currentPath = ""
local allEntries = {}
local selectedPath = nil

local function setStatus(message, isError)
    status.Text = tostring(message)
    status.TextColor3 = isError and C.red or C.muted
end

local function clearRows()
    for _, child in ipairs(list:GetChildren()) do
        if child:IsA("TextButton") or child:IsA("TextLabel") then child:Destroy() end
    end
end

local function drawEntries()
    clearRows()
    local query = search.Text:lower()
    local shown = 0
    for _, entry in ipairs(allEntries) do
        if query == "" or entry.name:lower():find(query, 1, true) then
            shown += 1
            local isModel = isModelFile(entry.path)
            local row = create("TextButton", {
                Size = UDim2.new(1, -2, 0, 34), BackgroundColor3 = C.panel2,
                Text = (entry.isFolder and "▸  " or (isModel and "◇  " or "   ")) .. entry.name,
                TextColor3 = isModel and C.text or (entry.isFolder and C.green or C.muted),
                Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
                AutoButtonColor = true,
            }, list)
            create("UICorner", {CornerRadius = UDim.new(0, 6)}, row)
            create("UIPadding", {PaddingLeft = UDim.new(0, 10)}, row)
            row.MouseButton1Click:Connect(function()
                selectedPath = entry.path
                if entry.isFolder then
                    pathBox.Text = entry.path
                    currentPath = entry.path
                    local entries, err = listDirectory(currentPath)
                    if entries then allEntries = entries; drawEntries(); setStatus(#entries .. " item ditemukan.")
                    else setStatus(err, true) end
                elseif isModel then
                    setStatus("Dipilih: " .. entry.name .. " — klik lagi untuk import.")
                    row.MouseButton1Click:Once(function()
                        local ok, message = importLocalFile(entry.path)
                        setStatus(message, not ok)
                        notify(ok and "Import berhasil" or "Import gagal", message, 5)
                    end)
                else
                    setStatus("File bukan model RBXM/RBXMX/RBXL/RBXLX.")
                end
            end)
        end
    end
    if shown == 0 then
        create("TextLabel", {
            Size = UDim2.new(1, -2, 0, 38), BackgroundTransparency = 1,
            Text = "Tidak ada file yang cocok.", TextColor3 = C.muted,
            Font = Enum.Font.Gotham, TextSize = 11,
        }, list)
    end
    task.defer(function()
        list.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 16)
    end)
end

local function openFolder(path)
    path = normalizePath(path)
    if path == "" then setStatus("Path folder belum diisi.", true) return end
    local entries, err = listDirectory(path)
    if not entries then setStatus(err, true) return end
    currentPath = path
    pathBox.Text = path
    allEntries = entries
    selectedPath = nil
    drawEntries()
    setStatus(#entries .. " item ditemukan di " .. path)
end

goBtn.MouseButton1Click:Connect(function() openFolder(pathBox.Text) end)
refresh.MouseButton1Click:Connect(function()
    if currentPath ~= "" then openFolder(currentPath) else setStatus("Masukkan path folder terlebih dahulu.", true) end
end)
search:GetPropertyChangedSignal("Text"):Connect(drawEntries)
close.MouseButton1Click:Connect(function() gui:Destroy() end)

-- Drag window on touch/mouse.
do
    local dragging, dragStart, startPos = false, nil, nil
    top.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Optional quick open when a common download folder exists.
local api = fileAPI()
if api.isfolder then
    for _, candidate in ipairs({"/storage/emulated/0/Download", "Download", "workspace"}) do
        local ok, exists = safeCall(api.isfolder, candidate)
        if ok and exists then openFolder(candidate) break end
    end
end

notify("RBXM Importer", "Open Source aktif. Tidak memakai token/login.", 4)
