-- ====================================================================
-- weredevs_tracer.lua
--
-- Динамический трассировщик для скриптов, обфусцированных WearDevs.
-- Запускает обфусцированный скрипт в песочнице с подменёнными глобалами,
-- логирует каждый внешний вызов (HttpGet, loadstring, GetService, SetCore,
-- setclipboard и т.д.) и восстанавливает читаемый псевдо-исходник.
--
-- Использование:
--     lua weredevs_tracer.lua obfuscated.lua > trace.log
--
-- Требования: Lua 5.1 / 5.2 / 5.3 / 5.4 или LuaJIT.
-- Roblox API в чистом Lua не запустится, поэтому мы его эмулируем
-- через прокси-объекты, которые логируют любой доступ и вызов.
-- ====================================================================

local INPUT_PATH = arg[1] or "obfuscated.lua"

-- ---------- Логирование --------------------------------------------------

local trace = {}
local indent = 0

local function log(fmt, ...)
    local args = {...}
    for i, v in ipairs(args) do
        if type(v) == "string" then
            args[i] = string.format("%q", v)
        elseif type(v) == "table" then
            args[i] = "<table>"
        else
            args[i] = tostring(v)
        end
    end
    local line = string.rep("  ", indent) .. string.format(fmt, table.unpack and table.unpack(args) or unpack(args))
    table.insert(trace, line)
end

-- ---------- Прокси для Roblox API ---------------------------------------
-- Каждый доступ к полю или вызов логируется. Возвращается новый прокси,
-- чтобы цепочки вида game:GetService("X"):FindFirstChild("Y") работали.

local proxy_mt = {}

local function make_proxy(path)
    return setmetatable({ __path = path }, proxy_mt)
end

proxy_mt.__index = function(t, key)
    local new_path = t.__path .. "." .. tostring(key)
    -- Специальные значения, которые нужны для логики скрипта
    if key == "Position" or key == "CFrame" or key == "Magnitude" or key == "p" then
        return 0
    end
    if key == "Text" then
        return "[игровое_значение]"
    end
    if key == "Character" or key == "LocalPlayer" or key == "PlayerGui" then
        return make_proxy(new_path)
    end
    return make_proxy(new_path)
end

proxy_mt.__call = function(t, ...)
    local args = {...}
    local arg_strs = {}
    for i, v in ipairs(args) do
        if type(v) == "string" then
            arg_strs[i] = string.format("%q", v)
        elseif type(v) == "table" and v.__path then
            arg_strs[i] = v.__path
        elseif type(v) == "table" then
            -- Это таблица параметров (типа { Title="...", Text="...", ... })
            local kv = {}
            for k, val in pairs(v) do
                if type(val) == "string" then
                    kv[#kv+1] = tostring(k) .. "=" .. string.format("%q", val)
                else
                    kv[#kv+1] = tostring(k) .. "=" .. tostring(val)
                end
            end
            arg_strs[i] = "{" .. table.concat(kv, ", ") .. "}"
        else
            arg_strs[i] = tostring(v)
        end
    end
    log("CALL %s(%s)", t.__path, table.concat(arg_strs, ", "))
    -- Возвращаем новый прокси, чтобы цепочка вызовов продолжалась
    return make_proxy(t.__path .. "()")
end

proxy_mt.__newindex = function(t, key, value)
    if type(value) == "string" then
        log("SET %s.%s = %q", t.__path, key, value)
    else
        log("SET %s.%s = %s", t.__path, key, tostring(value))
    end
end

proxy_mt.__eq = function() return false end
proxy_mt.__lt = function() return false end
proxy_mt.__le = function() return false end
proxy_mt.__add = function(a, b) return 0 end
proxy_mt.__sub = function(a, b) return 0 end
proxy_mt.__mul = function(a, b) return 0 end
proxy_mt.__concat = function(a, b)
    local sa = type(a) == "table" and a.__path or tostring(a)
    local sb = type(b) == "table" and b.__path or tostring(b)
    return sa .. " .. " .. sb
end

-- ---------- Песочница ----------------------------------------------------

local sandbox = {}

-- Стандартные библиотеки — даём как есть (скрипту нужны string, math, table)
sandbox.string = string
sandbox.math = math
sandbox.table = table
sandbox.tostring = tostring
sandbox.tonumber = tonumber
sandbox.type = type
sandbox.pairs = pairs
sandbox.ipairs = ipairs
sandbox.select = select
sandbox.pcall = function(f, ...)
    local ok, err = pcall(f, ...)
    return ok, err
end
sandbox.xpcall = xpcall
sandbox.error = error
sandbox.assert = assert
sandbox.setmetatable = setmetatable
sandbox.getmetatable = getmetatable
sandbox.rawget = rawget
sandbox.rawset = rawset
sandbox.rawequal = rawequal
sandbox.unpack = unpack or table.unpack
sandbox.next = next

-- newproxy — обфускатор использует его для создания userdata-маркеров
sandbox.newproxy = function(b)
    return setmetatable({}, {})
end

-- Перехватчики опасных операций
sandbox.loadstring = function(src)
    log("loadstring(<source, %d bytes>)", #(src or ""))
    if src and #src > 0 then
        log("  -- preview: %s", (src:sub(1, 100):gsub("\n", " ")))
    end
    return function() return make_proxy("loadstring_result") end
end

sandbox.load = sandbox.loadstring
sandbox.loadfile = function(p) log("loadfile(%q)", p); return function() end end
sandbox.dofile  = function(p) log("dofile(%q)", p) end

sandbox.print = function(...)
    local args = {...}
    local strs = {}
    for i, v in ipairs(args) do strs[i] = tostring(v) end
    log("print(%s)", table.concat(strs, ", "))
end

sandbox.setclipboard = function(s) log("setclipboard(%q)", s) end
sandbox.writefile    = function(n, c) log("writefile(%q, <%d bytes>)", n, #(c or "")) end
sandbox.readfile     = function(n) log("readfile(%q)", n); return "" end

-- task.* (Roblox)
sandbox.task = {
    wait  = function(t) log("task.wait(%s)", tostring(t or 0)) end,
    spawn = function(f) log("task.spawn(<function>)"); pcall(f) end,
    delay = function(t, f) log("task.delay(%s, <function>)", tostring(t)); pcall(f) end,
}
sandbox.wait = function(t) log("wait(%s)", tostring(t or 0)) end
sandbox.spawn = function(f) log("spawn(<function>)"); pcall(f) end

-- Roblox-специфичные глобалы — это прокси
sandbox.game      = make_proxy("game")
sandbox.workspace = make_proxy("workspace")
sandbox.script    = make_proxy("script")
sandbox.Instance  = {
    new = function(class, parent)
        log("Instance.new(%q, %s)", class, parent and parent.__path or "nil")
        return make_proxy("Instance(" .. class .. ")")
    end
}
sandbox.Vector3 = {
    new = function(x, y, z)
        log("Vector3.new(%s, %s, %s)", tostring(x), tostring(y), tostring(z))
        return make_proxy("Vector3")
    end
}
sandbox.CFrame = {
    new = function(...) log("CFrame.new(...)"); return make_proxy("CFrame") end
}
sandbox.Enum    = make_proxy("Enum")
sandbox.TweenInfo = { new = function(...) log("TweenInfo.new(...)"); return make_proxy("TweenInfo") end }

-- Exploit-функции, которые часто встречаются в Roblox-скриптах
sandbox.identifyexecutor = function() return "TracerSandbox", "1.0" end
sandbox.getgenv = function() return sandbox end
sandbox.getrenv = function() return _G end
sandbox.getfenv = function() return sandbox end
sandbox.setfenv = function(f, env) return f end
sandbox.hookfunction = function(f) log("hookfunction(...)"); return f end
sandbox.hookmetamethod = function() log("hookmetamethod(...)"); return function() end end

-- HttpGet alias на уровне game:HttpGet
-- (внутри прокси уже обработается, но для всякого случая)

sandbox._G   = sandbox
sandbox._ENV = sandbox

setmetatable(sandbox, {
    __index = function(t, k)
        -- Любой неизвестный глобал — прокси
        log("READ_GLOBAL %s", tostring(k))
        return make_proxy("_G." .. tostring(k))
    end
})

-- ---------- Запуск ------------------------------------------------------

local f, err = io.open(INPUT_PATH, "r")
if not f then
    io.stderr:write("Не могу открыть файл: " .. tostring(err) .. "\n")
    os.exit(1)
end
local source = f:read("*a")
f:close()

io.stderr:write(string.format("[*] Загружен файл: %s (%d байт)\n", INPUT_PATH, #source))

-- Загружаем скрипт в песочнице
local chunk, load_err
if setfenv then
    -- Lua 5.1 / LuaJIT
    chunk, load_err = loadstring(source, "obfuscated")
    if chunk then setfenv(chunk, sandbox) end
else
    -- Lua 5.2+
    chunk, load_err = load(source, "obfuscated", "t", sandbox)
end

if not chunk then
    io.stderr:write("Ошибка загрузки: " .. tostring(load_err) .. "\n")
    os.exit(1)
end

io.stderr:write("[*] Запуск в песочнице...\n")

local ok, run_err = pcall(chunk)
if not ok then
    io.stderr:write("[!] Скрипт упал с ошибкой: " .. tostring(run_err) .. "\n")
    io.stderr:write("    (Это нормально — мы получаем частичный трейс до падения)\n")
end

io.stderr:write(string.format("[*] Готово. Получено %d событий.\n", #trace))

-- ---------- Вывод -------------------------------------------------------

print("-- ====================================================================")
print("-- Trace from WearDevs-obfuscated script: " .. INPUT_PATH)
print("-- ====================================================================")
print("")
for _, line in ipairs(trace) do
    print(line)
end
