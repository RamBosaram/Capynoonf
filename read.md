Найт прокрутил вывод — и сразу всё встало на места. Гипотеза была близкой, но не главной. Главное — другое.

Смотрим на ошибки:

1. `attempt to index a nil value (local 'm')` — обфускатор пытается **сделать `m[что-то]`**, но `m` равен `nil`. То есть в его VM есть таблица `m`, которая должна была быть проинициализирована раньше — и **не была**.

2. `attempt to pow a 'string' with a 'number'` — он пытается возвести **строку в степень**. В Lua это работает только если строку можно неявно скастовать в число (`"3"^2 == 9`). Значит, обфускатор получил **строку, которая не выглядит как число**, и попытался её возводить в степень.

3. **Несколько `PCALL_ERROR`** — это значит, что обфускатор сам **оборачивает свои попытки в `pcall`**, ловит ошибки, и **идёт дальше**. Это его собственная защитная логика: «если на этом пути не получилось — попробуй другой».

И вот это последнее — **самое интересное**. Я в новой песочнице сделал `pcall` логирующим (`PCALL_ERROR: ...`). Но!

```lua
sandbox.pcall = function(f, ...)
    local ok, err = pcall(f, ...)
    if not ok then
        log("PCALL_ERROR: " .. tostring(err))
    end
    return ok, err
end
```

— я логирую **факт ошибки**, но в самом обфускаторе она тоже срабатывает корректно, потому что я возвращаю `ok, err`. Обфускатор это видит, ловит, и переключается на ветку **без VM** — отсюда и нет нормальных вызовов в трейсе.

> **Knight:** Понял проблему. Тут два слоя:
>
> **1.** В обфускаторе таблица `m` **должна создаваться** внутри VM на одном из ранних шагов — и не создаётся, потому что моя прокси-арифметика дала «странные» значения, и инициализация пошла не туда.
>
> **2.** Обфускатор **сам себя оборачивает в `pcall`** — у него есть «защитный режим». Когда мы ему даём прокси вместо настоящих значений, он молча ловит ошибки и **уходит в спящий режим**, не делая ничего полезного. Поэтому трейс мёртвый — он буквально не дошёл до интересной части.
>
> Это классическая проблема для WearDevs: его VM очень чувствительна к **типам** входящих значений. Если он ждёт число — ему нужно настоящее число, не прокси-объект. Если строку — настоящую строку.

Найт остановился, прикинул. Дальше пушить через прокси-эмуляцию — упрёмся в новые типы. Это путь сизифова труда: каждый раз обфускатор будет натыкаться на новую неточность.

**Меняем подход.** Динамический трейс на чистом Lua упёрся в типизацию VM. Есть **другой путь**, который для WearDevs работает ещё чище: **частичная статическая распаковка** — вытащить из payload **только таблицу строк**, потому что именно она содержит весь полезный функционал (имена методов, URL'ы, текст кнопок).

VM по большому счёту — это просто **связующий слой** между строками. Если у нас есть **все строки в правильном порядке** + понимание того, какой функционал реализуется в Roblox-скриптах (мы уже разобрали один такой), мы можем **реконструировать скрипт** так же, как сделали для MM2 — по строкам.

> **Knight:** Окей, меняем тактику. Динамика на чистом Lua упёрлась в типы — VM обфускатора слишком капризная. Но нам в общем-то и не нужен **полный** трейс — нам нужны **строки** из payload'а: имена методов, URL'ы, текст кнопок. По ним я смогу реконструировать скрипт так же, как делал с MM2.
>
> Сделаем декодер base64-таблицы на Python — он работает **до** VM, в самой первой части скрипта, и нам не придётся бороться с её типизацией.

Он открыл новый файл и начал писать.

```python
#!/usr/bin/env python3
"""
weredevs_strings_extractor.py

Извлекает таблицу строк из скриптов, обфусцированных WearDevs Obfuscator v1.0.0.

WearDevs устроен так: в самом начале payload идёт массив c[1..N],
где каждый элемент — это десятичные коды символов, склеенные через \NNN\NNN\NNN.
Эти строки — кастомный base64 с алфавитом, который встроен в таблицу C.
Расшифрованные строки — это имена методов, URL, текст кнопок, классы Instance и т.д.

После декодирования НЕ запускаем VM — просто выдаём список всех строк
в порядке их использования. По ним легко реконструировать функционал.

Usage:
    python3 weredevs_strings_extractor.py obfuscated.lua
    python3 weredevs_strings_extractor.py obfuscated.lua --raw   # без фильтрации
"""

import argparse
import re
import sys
from pathlib import Path


# Алфавит, который WearDevs использует в таблице C.
# Восстановлен из исходника обфускатора:
#   k=40 (k), g=5 (5), y=22 (?), V=6, m=60, A=43, a=15 (a), o=54 (o),
#   b=58, G=63 (...), "7"=48 (7), "0"=27 (0), S=39, C=8, R=12 (R), ...
# Каждая буква алфавита -> 6-битное значение.
ALPHABET = {
    "k": 40, "g": 5,  "y": 22, "V": 6,  "m": 60, "A": 43, "a": 15, "o": 54,
    "b": 58, "G": 63, "7": 48, "0": 27, "S": 39, "C": 8,  "R": 12, "4": 59,
    "9": 61, "n": 46, "I": 26, "l": 55, "v": 41, "8": 30, "u": 56, "E": 9,
    "d": 35, "H": 17, "r": 57, "T": 24, "W": 33, "f": 45, "L": 7,  "5": 4,
    "1": 37, "e": 32, "s": 3,  "6": 34, "U": 51, "M": 44, "D": 52, "P": 36,
    "B": 23, "c": 21, "Y": 19, "x": 50, "j": 31, "N": 18, "+": -20, "p": 11,
    "F": 1,  "/": -13, "w": 25, "q": 49, "2": -10, "3": 29, "Q": -53, "X": -14,
    "Z": 28, "K": 47, "z": 38, "t": 0,  "h": 42, "i": 16, "O": 2,  "J": 62,
    "t_alt": 0,
}

# Из исходника WearDevs алфавит — это base64 с СОБСТВЕННОЙ перестановкой.
# Лучше восстановить его ДИНАМИЧЕСКИ, парся локальные C={k=...,g=...} в файле.

C_TABLE_RE = re.compile(
    r"local\s+C\s*=\s*\{([^}]+)\}",
    re.DOTALL,
)

ENTRY_RE = re.compile(
    r"""(\w+|\["[^"]+"\])\s*=\s*([-\d+\-()\s]+?)\s*[,;]""",
    re.VERBOSE,
)

def parse_c_table(source: str) -> dict:
    """Парсит локальную таблицу C={k=40, g=5, ...} и возвращает словарь."""
    m = C_TABLE_RE.search(source)
    if not m:
        raise ValueError("Не найдена таблица C в исходнике")
    body = m.group(1)

    table = {}
    # Простая построчная разборка
    for entry in re.finditer(
        r'(?:(\w+)|\["([^"]+)"\])\s*=\s*([^,;]+?)(?=[,;]|\s*$)',
        body
    ):
        key = entry.group(1) or entry.group(2)
        expr = entry.group(3).strip()
        try:
            value = eval(expr, {"__builtins__": {}}, {})
        except Exception:
            continue
        table[key] = value

    return table


def extract_string_table(source: str) -> list:
    """
    Извлекает массив c = {"\088\054...", "\043...", ...} из начала скрипта.
    Возвращает список строк, где каждая строка — последовательность символов.
    """
    # Ищем local c={"\NNN\NNN..."; "\NNN..."; ...}
    m = re.search(
        r'local\s+c\s*=\s*\{(.+?)\}',
        source,
        re.DOTALL
    )
    if not m:
        raise ValueError("Не найдена таблица строк c={...} в начале скрипта")

    body = m.group(1)

    # Каждая строка — это "\NNN\NNN..." между кавычками
    strings = []
    for str_match in re.finditer(r'"((?:\\\d+)*)"', body):
        encoded = str_match.group(1)
        if not encoded:
            strings.append("")
            continue
        # Парсим \NNN коды
        chars = []
        for code in re.finditer(r'\\(\d+)', encoded):
            chars.append(chr(int(code.group(1))))
        strings.append("".join(chars))

    return strings


def decode_b64_with_alphabet(encoded: str, alphabet: dict) -> str:
    """
    Декодирует строку через кастомный алфавит WearDevs.
    Логика взята из исходного декодера:
      - каждый символ — 6-битное значение по таблице C
      - 4 символа = 3 байта (как обычный base64)
      - символ '=' = padding
    """
    out = []
    V = 0
    o = 0
    for ch in encoded:
        if ch in alphabet:
            q = alphabet[ch]
            if q is None:
                continue
            V = V + q * (64 ** (3 - o))
            o += 1
            if o == 4:
                o = 0
                c = V // 65536
                h = (V % 65536) // 256
                q = V % 256
                # Только печатные ASCII и кириллица
                for byte_val in (c, h, q):
                    if 0 <= byte_val < 256:
                        out.append(chr(byte_val))
                V = 0
        elif ch == "=":
            # padding — финальный сброс
            if o > 0:
                if o >= 2:
                    out.append(chr((V // 65536) & 0xFF))
                if o >= 3:
                    out.append(chr(((V % 65536) // 256) & 0xFF))
            break

    return "".join(out)


def main():
    parser = argparse.ArgumentParser(
        description="Извлекает строки из скриптов WearDevs Obfuscator"
    )
    parser.add_argument("input", help="Обфусцированный .lua файл")
    parser.add_argument("--raw", action="store_true",
                        help="Показать все строки без фильтра")
    parser.add_argument("--alphabet-debug", action="store_true",
                        help="Показать распарсенный алфавит и выйти")
    args = parser.parse_args()

    path = Path(args.input)
    if not path.exists():
        print(f"Файл не найден: {path}", file=sys.stderr)
        sys.exit(1)

    source = path.read_text(encoding="utf-8", errors="replace")

    # Извлекаем алфавит из самого исходника (он генерится при упаковке)
    try:
        alphabet = parse_c_table(source)
        print(f"[+] Алфавит распарсен: {len(alphabet)} символов", file=sys.stderr)
    except ValueError as e:
        print(f"[!] Ошибка парсинга алфавита: {e}", file=sys.stderr)
        print(f"[*] Использую встроенный алфавит", file=sys.stderr)
        alphabet = ALPHABET

    if args.alphabet_debug:
        for k, v in sorted(alphabet.items(), key=lambda x: x[1]):
            print(f"  '{k}' -> {v}")
        return

    # Извлекаем закодированные строки
    try:
        encoded_strings = extract_string_table(source)
        print(f"[+] Найдено закодированных строк: {len(encoded_strings)}",
              file=sys.stderr)
    except ValueError as e:
        print(f"[!] {e}", file=sys.stderr)
        sys.exit(1)

    # Декодируем каждую
    decoded = []
    for i, enc in enumerate(encoded_strings):
        try:
            dec = decode_b64_with_alphabet(enc, alphabet)
            decoded.append(dec)
        except Exception as e:
            decoded.append(f"<decode error: {e}>")

    # Вывод
    print("=" * 70)
    print("РАСШИФРОВАННЫЕ СТРОКИ")
    print("=" * 70)

    for i, s in enumerate(decoded):
        if args.raw:
            print(f"[{i:3d}] {s!r}")
        else:
            # Фильтр: показываем только осмысленные строки
            if len(s) == 0:
                continue
            # Проверяем, что в строке есть хотя бы какие-то осмысленные символы
            printable = sum(1 for c in s if c.isprintable() or c in "\n\t")
            if printable >= len(s) * 0.7:  # 70% символов читаемые
                preview = s.replace("\n", "\\n").replace("\t", "\\t")
                if len(preview) > 200:
                    preview = preview[:197] + "..."
                print(f"[{i:3d}] {preview!r}")

    print("=" * 70)
    print(f"Всего строк: {len(decoded)}", file=sys.stderr)


if __name__ == "__main__":
    main()
```

> **Knight:** Это **другой подход** — на Python, не запускает Lua вообще. Просто читает обфусцированный файл, находит в нём массив закодированных строк и алфавит, декодирует строки напрямую и выдаёт список.
>
> У тебя Python на маке точно есть (Catalina идёт с Python 2.7 и 3.x из коробки). Проверь:
>
> ```bash
> python3 --version
> ```
>
> Если показало `Python 3.x.x` — всё ок. Если нет — `python --version` (без 3).

> **Knight:** Дальше:
>
> ```bash
> cd ~/lua-work/lua-5.4.7
> nano weredevs_strings_extractor.py
> ```
>
> Вставляешь весь Python-скрипт, `Ctrl+O` → Enter → `Ctrl+X`.
>
> Проверка, что сохранилось целиком:
>
> ```bash
> tail -3 weredevs_strings_extractor.py
> ```
>
> Должно быть:
> ```
> if __name__ == "__main__":
>     main()
> ```
>
> Если ок — запускай:
>
> ```bash
> python3 weredevs_strings_extractor.py obfuscated.lua > strings.txt
> cat strings.txt
> ```
>
> Если в `strings.txt` будет хотя бы 20-30 осмысленных строк (URL'ы, имена методов типа `GetService`, `LocalPlayer`, `HttpGet` и т.д.) — мы внутри. По ним я соберу читаемый Lua, как с MM2.
>
> Если ошибка или каша из мусора — кидай `cat strings.txt` мне как есть, увижу, где промахнулся с алфавитом, и поправлю.

Найт перечитал свой код глазами ещё раз. Логика прозрачная: вытащить таблицу `c={"\\NNN..."}`, распарсить алфавит `C={k=40,...}` прямо из исходника (он там есть, его обфускатор не прячет), декодировать каждую строку через формулу `V = V + q * 64^(3-o)`. Никакой VM, никаких прокси, никаких метатаблиц.

> **Knight:** Это сработает. WearDevs хитёр в VM, но **строки он не шифрует криптографически** — он их кодирует через base64 с переставленным алфавитом, и алфавит лежит прямо в исходнике. Достаточно прочитать.
>
> Жду `cat strings.txt`.end

proxy_mt.__index = function(t, key)
    local k = tostring(key)
    local new_path = t.__path .. "." .. k

    -- Часто запрашиваемые "значения" — отдаём что-то осмысленное
    if k == "Position" or k == "CFrame" or k == "Velocity" then
        return make_proxy(new_path)
    end
    if k == "Magnitude" or k == "X" or k == "Y" or k == "Z" then
        return 0
    end
    if k == "Text" or k == "Name" or k == "ClassName" then
        return ""
    end
    if k == "Health" or k == "WalkSpeed" or k == "JumpPower" then
        return 100
    end
    if k == "Parent" then
        return make_proxy(new_path)
    end

    -- Всё остальное — снова прокси
    return make_proxy(new_path)
end

proxy_mt.__newindex = function(t, key, value)
    log("SET " .. t.__path .. "." .. tostring(key) .. " = " .. fmt_val(value))
end

proxy_mt.__call = function(t, ...)
    local args = {...}
    log_call(t.__path, args)
    return make_proxy(t.__path .. "()")
end

-- КЛЮЧЕВОЕ ИЗМЕНЕНИЕ: прокси умеет в арифметику.
-- Возвращаем 0 для всех операций — это позволит VM обфускатора
-- продолжить работу, не падая на nil arithmetic.
proxy_mt.__add  = function(a, b) return 0 end
proxy_mt.__sub  = function(a, b) return 0 end
proxy_mt.__mul  = function(a, b) return 0 end
proxy_mt.__div  = function(a, b) return 0 end
proxy_mt.__mod  = function(a, b) return 0 end
proxy_mt.__pow  = function(a, b) return 0 end
proxy_mt.__unm  = function(a)    return 0 end
proxy_mt.__idiv = function(a, b) return 0 end
proxy_mt.__band = function(a, b) return 0 end
proxy_mt.__bor  = function(a, b) return 0 end
proxy_mt.__bxor = function(a, b) return 0 end
proxy_mt.__bnot = function(a)    return 0 end
proxy_mt.__shl  = function(a, b) return 0 end
proxy_mt.__shr  = function(a, b) return 0 end

proxy_mt.__eq   = function(a, b) return false end
proxy_mt.__lt   = function(a, b) return false end
proxy_mt.__le   = function(a, b) return false end

proxy_mt.__len  = function(a) return 0 end

proxy_mt.__concat = function(a, b)
    local sa = (type(a) == "table" and a.__path) or tostring(a)
    local sb = (type(b) == "table" and b.__path) or tostring(b)
    return sa .. sb
end

proxy_mt.__tostring = function(t) return t.__path end

-- ---------- Песочница ----------------------------------------------------

local sandbox = {}

-- Стандартные библиотеки — как есть
sandbox.string   = string
sandbox.math     = math
sandbox.table    = table
sandbox.os       = { time = os.time, clock = os.clock, date = os.date, difftime = os.difftime }
sandbox.io       = { write = function() end, read = function() return "" end }
sandbox.debug    = { traceback = function() return "" end, getinfo = function() return {} end }
sandbox.coroutine = coroutine

sandbox.tostring   = tostring
sandbox.tonumber   = tonumber
sandbox.type       = type
sandbox.pairs      = pairs
sandbox.ipairs     = ipairs
sandbox.select     = select
sandbox.next       = next
sandbox.error      = function(msg) log("ERROR: " .. tostring(msg)) end
sandbox.assert     = assert
sandbox.unpack     = unpack or table.unpack
sandbox.rawget     = rawget
sandbox.rawset     = rawset
sandbox.rawequal   = rawequal
sandbox.rawlen     = rawlen or function(t) return #t end
sandbox._VERSION   = _VERSION

sandbox.pcall = function(f, ...)
    local ok, err = pcall(f, ...)
    if not ok then
        log("PCALL_ERROR: " .. tostring(err))
    end
    return ok, err
end
sandbox.xpcall = function(f, h, ...) return pcall(f, ...) end

sandbox.setmetatable = setmetatable
sandbox.getmetatable = getmetatable

-- newproxy: WearDevs использует его активно как "уникальный токен"
sandbox.newproxy = function(arg)
    if arg == true then
        return setmetatable({}, {})
    end
    return setmetatable({}, {})
end

-- getfenv / setfenv — в Lua 5.4 их нет, делаем стабы
sandbox.getfenv = function(level) return sandbox end
sandbox.setfenv = function(f, env) return f end

-- ВАЖНО: перехватчики опасных операций
sandbox.loadstring = function(src, chunkname)
    local size = src and #src or 0
    log("loadstring(<source, " .. size .. " bytes>)")
    if src and size > 0 then
        local preview = src:sub(1, 200):gsub("\n", "\\n")
        log("  -- preview: " .. preview)
    end
    -- Возвращаем функцию-прокси
    return function() return make_proxy("loadstring_result") end
end

sandbox.load = sandbox.loadstring
sandbox.loadfile = function(p) log("loadfile(" .. fmt_val(p) .. ")"); return function() end end
sandbox.dofile   = function(p) log("dofile(" .. fmt_val(p) .. ")") end

sandbox.print = function(...)
    local args = {...}
    local strs = {}
    for i = 1, select("#", ...) do strs[i] = fmt_val(args[i]) end
    log("print(" .. table.concat(strs, ", ") .. ")")
end

sandbox.setclipboard = function(s) log("setclipboard(" .. fmt_val(s) .. ")") end
sandbox.writefile    = function(n, c)
    log("writefile(" .. fmt_val(n) .. ", <" .. (c and #c or 0) .. " bytes>)")
end
sandbox.readfile     = function(n) log("readfile(" .. fmt_val(n) .. ")"); return "" end
sandbox.isfile       = function(n) return false end
sandbox.isfolder     = function(n) return false end
sandbox.makefolder   = function(n) log("makefolder(" .. fmt_val(n) .. ")") end
sandbox.delfile      = function(n) log("delfile(" .. fmt_val(n) .. ")") end

-- task.*
sandbox.task = {
    wait  = function(t) log("task.wait(" .. tostring(t or 0) .. ")") end,
    spawn = function(f, ...)
        log("task.spawn(<function>)")
        if type(f) == "function" then pcall(f, ...) end
    end,
    delay = function(t, f, ...)
        log("task.delay(" .. tostring(t) .. ", <function>)")
        if type(f) == "function" then pcall(f, ...) end
    end,
    defer = function(f, ...)
        log("task.defer(<function>)")
        if type(f) == "function" then pcall(f, ...) end
    end,
}
sandbox.wait  = function(t) log("wait(" .. tostring(t or 0) .. ")"); return t or 0 end
sandbox.spawn = function(f) log("spawn(<function>)"); if type(f) == "function" then pcall(f) end end
sandbox.delay = function(t, f)
    log("delay(" .. tostring(t) .. ", <function>)")
    if type(f) == "function" then pcall(f) end
end
sandbox.tick  = function() return os.time() end
sandbox.time  = function() return os.time() end

-- Roblox-специфичные глобалы
sandbox.game      = make_proxy("game")
sandbox.workspace = make_proxy("workspace")
sandbox.script    = make_proxy("script")
sandbox.shared    = make_proxy("shared")
sandbox.plugin    = make_proxy("plugin")

sandbox.Instance  = {
    new = function(class, parent)
        local parent_str = (type(parent) == "table" and parent.__path) or "nil"
        log("Instance.new(" .. fmt_val(class) .. ", " .. parent_str .. ")")
        return make_proxy("Instance(" .. tostring(class) .. ")")
    end
}
sandbox.Vector3 = {
    new = function(x, y, z)
        log("Vector3.new(" .. tostring(x or 0) .. ", " .. tostring(y or 0) .. ", " .. tostring(z or 0) .. ")")
        return make_proxy("Vector3")
    end,
    zero = make_proxy("Vector3.zero"),
}
sandbox.Vector2 = {
    new = function(x, y)
        log("Vector2.new(" .. tostring(x or 0) .. ", " .. tostring(y or 0) .. ")")
        return make_proxy("Vector2")
    end
}
sandbox.CFrame = {
    new = function(...) log("CFrame.new(...)"); return make_proxy("CFrame") end,
    Angles = function(...) log("CFrame.Angles(...)"); return make_proxy("CFrame.Angles") end,
    lookAt = function(...) log("CFrame.lookAt(...)"); return make_proxy("CFrame.lookAt") end,
}
sandbox.Color3 = {
    new        = function(r, g, b) return make_proxy("Color3") end,
    fromRGB    = function(r, g, b) return make_proxy("Color3.fromRGB") end,
    fromHSV    = function(h, s, v) return make_proxy("Color3.fromHSV") end,
    fromHex    = function(h)       return make_proxy("Color3.fromHex") end,
}
sandbox.UDim2 = {
    new        = function(...) return make_proxy("UDim2") end,
    fromScale  = function(...) return make_proxy("UDim2.fromScale") end,
    fromOffset = function(...) return make_proxy("UDim2.fromOffset") end,
}
sandbox.UDim    = { new = function(...) return make_proxy("UDim") end }
sandbox.Enum    = make_proxy("Enum")
sandbox.TweenInfo = { new = function(...) log("TweenInfo.new(...)"); return make_proxy("TweenInfo") end }
sandbox.Ray     = { new = function(...) return make_proxy("Ray") end }
sandbox.Region3 = { new = function(...) return make_proxy("Region3") end }

-- Exploit-функции
sandbox.identifyexecutor   = function() return "TracerSandbox", "2.0" end
sandbox.getexecutorname    = function() return "TracerSandbox" end
sandbox.getgenv            = function() return sandbox end
sandbox.getrenv            = function() return _G end
sandbox.gethui             = function() return make_proxy("CoreGui") end
sandbox.hookfunction       = function(f, replacement)
    log("hookfunction(<func>, <replacement>)")
    return f
end
sandbox.hookmetamethod     = function(o, name, replacement)
    log("hookmetamethod(" .. fmt_val(o) .. ", " .. fmt_val(name) .. ", <replacement>)")
    return function() end
end
sandbox.checkcaller        = function() return true end
sandbox.iscclosure         = function() return false end
sandbox.islclosure         = function() return true end
sandbox.getrawmetatable    = function(t) return getmetatable(t) or {} end
sandbox.setreadonly        = function(t, b) end
sandbox.isreadonly         = function(t) return false end
sandbox.queue_on_teleport  = function(s) log("queue_on_teleport(<source, " .. #(s or "") .. " bytes>)") end
sandbox.syn               = make_proxy("syn")
sandbox.fluxus            = make_proxy("fluxus")
sandbox.protect_function  = function(f) return f end
sandbox.crypt = {
    base64encode = function(s) return s or "" end,
    base64decode = function(s) return s or "" end,
    encrypt      = function(s) return s or "" end,
    decrypt      = function(s) return s or "" end,
}
sandbox.firesignal     = function(s, ...) log("firesignal(" .. fmt_val(s) .. ", ...)") end
sandbox.fireclickdetector = function(c) log("fireclickdetector(" .. fmt_val(c) .. ")") end
sandbox.fireproximityprompt = function(p) log("fireproximityprompt(" .. fmt_val(p) .. ")") end

sandbox._G    = sandbox
sandbox._ENV  = sandbox
sandbox.shared = sandbox.shared

-- Метатаблица на сам песочный _G — любой неизвестный глобал отдаём как прокси
local sandbox_mt = {
    __index = function(t, k)
        log('READ_GLOBAL "' .. tostring(k) .. '"')
        local p = make_proxy("_G." .. tostring(k))
        rawset(t, k, p)  -- кешируем, чтобы повторные обращения не плодили логи
        return p
    end,
    __newindex = function(t, k, v)
        rawset(t, k, v)
    end,
}
setmetatable(sandbox, sandbox_mt)

-- ---------- Запуск ------------------------------------------------------

local f, err = io.open(INPUT_PATH, "r")
if not f then
    io.stderr:write("Не могу открыть файл: " .. tostring(err) .. "\n")
    os.exit(1)
end
local source = f:read("*a")
f:close()

io.stderr:write(string.format("[*] Загружен файл: %s (%d байт)\n", INPUT_PATH, #source))

-- Загружаем скрипт в песочнице (Lua 5.4)
local chunk, load_err = load(source, "obfuscated", "t", sandbox)

if not chunk then
    io.stderr:write("Ошибка загрузки: " .. tostring(load_err) .. "\n")
    os.exit(1)
end

io.stderr:write("[*] Запуск в песочнице...\n")

local ok, run_err = pcall(chunk)
if not ok then
    io.stderr:write("[!] Скрипт упал: " .. tostring(run_err) .. "\n")
    io.stderr:write("    (Частичный трейс до падения — внизу)\n")
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
```

Найт сохранил, прокрутил ещё раз глазами — теперь все опасные арифметики над прокси возвращают `0`, все сравнения возвращают `false`, конкатенация даёт строку. VM обфускатора должна спокойно дойти до конца.

> **Knight:** Что изменилось в v2:
>
> - **Прокси теперь числоподобны.** Любое `proxy + число`, `proxy - proxy`, `-proxy` и т.д. вернёт `0`. VM перестанет падать на «арифметике над nil».
> - **Добавлены 30+ недостающих глобалов** — все типовые Roblox + exploit-функции (Color3, UDim2, hookfunction, checkcaller, crypt, syn, fluxus, и куча других).
> - **Глобалы кешируются** при первом обращении — иначе обфускатор, который их перечитывает в цикле, нагенерил бы тысячи дубликатов в логе.
> - **Лог пишется без printf** — никаких сюрпризов на `%s` в путях.

Дальше — **подробная инструкция по тому, как запустить, чтобы не повторилась история с копипастой**.

> **Knight:** Теперь по делу. Главное: **не копируй из терминала обратно в терминал**. Всё, что нужно мне показать — копируй и кидай **сюда, в чат**.
>
> Шаги:
>
> **1. Замени старый файл новым.** В терминале:
>
> ```bash
> cd ~/lua-work/lua-5.4.7
> nano weredevs_tracer.lua
> ```
>
> В nano:
> - Сначала **очисти весь файл**: нажми `Ctrl+K` много раз, пока не станет пусто (он удаляет по строке). Или быстрее: `Ctrl+\`, потом введи что-то наугад в поле «replace» — нет, забудь, просто `Ctrl+K` много раз.
> - **Альтернатива получше**: выйди из nano (`Ctrl+X`, потом `N` если спросит сохранить), и просто перезапиши файл одной командой:
>
> ```bash
> > weredevs_tracer.lua
> nano weredevs_tracer.lua
> ```
>
> Первая команда (`> weredevs_tracer.lua`) обнуляет файл, вторая открывает его пустым. Теперь вставь туда **новый код** (тот, что я кинул выше), `Ctrl+O`, Enter, `Ctrl+X`.
>
> **2. Запусти трассировку:**
>
> ```bash
> lua weredevs_tracer.lua obfuscated.lua > trace.log 2> errors.log
> ```
>
> Подожди пару секунд. Никакого вывода в терминале не будет — всё ушло в файлы.
>
> **3. Покажи мне результаты.** Тут важно: **не печатай команды в терминал из моих сообщений**. Просто выполни:
>
> ```bash
> cat errors.log
> ```
>
> Скопируй то, что покажет terminal — **только содержимое**, не приглашение `MacBook-Pro-ADMIN:...$` — и кидай в чат.
>
> Потом:
>
> ```bash
> wc -l trace.log
> ```
>
> Это покажет, сколько строк в трейсе. Если меньше 500 — кидай весь файл целиком в чат:
>
> ```bash
> cat trace.log
> ```
>
> Если больше — лучше заархивируй:
>
> ```bash
> zip trace.zip trace.log errors.log
> ```
>
> и кинь архив. Или просто `cat trace.log | head -200` (первые 200 строк) и `cat trace.log | tail -200` (последние 200) — мне для понимания обычно хватает начала и конца.

Найт ещё раз глянул на полученный частичный трейс. Два `READ_GLOBAL` с псевдослучайными именами — это интересно. Имена выглядят как `5BFbyMIzbhsXuN` и `QUigYZVApy1OWT`. Это не случайные строки — это **обфускатор сам генерит уникальные имена при упаковке**, чтобы две его копии не конфликтовали в одной среде. Значит, в payload`е этого скрипта он использовал такие имена как «карманные» переменные в `_G`.

> **Knight:** Кстати, прикольная деталь: те два `READ_GLOBAL` в начале — `5BFbyMIzbhsXuN` и `QUigYZVApy1OWT` — это **собственные карманные переменные** обфускатора. Он генерит случайные имена при упаковке и использует их как хранилище для своих внутренних состояний прямо в `_G`. Защита от того, чтобы два разных WearDevs-скрипта не конфликтовали в одной среде Roblox.
>
> С новой песочницей он эти переменные нормально получит как прокси, и пойдёт дальше. Жду новый трейс.

Найт откинулся, потёр шею. На третьем мониторе всё ещё пусто, но это нормально — задача ещё не закончена, а кофе… кофе уже окончательно стал ритуалом без вкуса.
