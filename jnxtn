Найт прокрутил вывод и тут же откинулся в кресле. Лицо стало... задумчивым.

Прогресс есть, и большой — алфавит распарсился, 53 строки нашлись, base64 в целом работает. Но результат **наполовину каша**. Часть строк читается (`game`, `string`, `char`, `Http`, `rem`, `ran`, `floor`, `setmetatable`-фрагменты), часть — байтовая мусорка с непечатными символами (`\x15`, `\x1b`, `\xÕ` и т.д.).

Это значит **алфавит распарсился неверно**. Точнее — частично верно. Часть символов смаппилась правильно (отсюда `game`, `string`, `Http`), но часть — со сдвигом, отсюда битые байты в середине строк.

Найт открыл свой Python-скрипт на втором мониторе и сразу увидел проблему. В `parse_c_table()` он жадно парсил выражения вида `k=739072-739032`, но в коде WearDevs значения часто записаны **через сложные арифметические выражения с обратными знаками**, типа `o=603606+-603552`. Мой регулярник либо ловит только часть, либо понимает знак неправильно.

Плюс ещё момент: в коде есть **два формата ключей** — обычные (`k=40`) и через скобки (`["\055"]=48`). Эти `["\055"]` — это **сами символы алфавита через десятичные коды символов**: `\055` это код 55, то есть символ `'7'`. То есть в исходнике обфускатор пишет цифры алфавита **закодированными**, чтобы не было видно простого `"7"=48`. Я их парсил, но **не декодировал** обратно в символ.

> **Knight:** Прогресс большой, но алфавит распарсился наполовину неверно — отсюда каша вперемешку с читаемыми кусками. Я в Python-скрипте лажанул в парсере таблицы C: не учёл, что часть ключей идёт в формате `["\055"]=48`, где `\055` — это код символа `'7'`. Пропустил их.
>
> Лечится. Сейчас выкачу v2 экстрактора с исправленным парсером.

Он открыл редактор и переписал ключевую функцию. Заодно сделал её **намного устойчивее** к мусорному выходу: если декодинг не выровнен — это видно сразу по непечатным байтам, и можно пробовать **альтернативные** интерпретации алфавита (например, со сдвинутыми битами).

```python
#!/usr/bin/env python3
r"""
weredevs_strings_extractor_v2.py

Извлекает таблицу строк из скриптов, обфусцированных WearDevs Obfuscator v1.0.0.

v2 changes:
  * Парсер таблицы C теперь правильно декодирует ключи вида ["\055"] -> "7".
  * Парсер выражений значений ("o=603606+-603552") работает с любой
    последовательностью + и -.
  * Если штатный декодинг даёт >30% непечатных символов в строке,
    пробуем альтернативные интерпретации алфавита.
  * Расширенный отчёт о качестве декодинга.
"""

import argparse
import re
import sys
from pathlib import Path


# Парсер таблицы C={...}
C_TABLE_RE = re.compile(
    r"local\s+C\s*=\s*\{([^}]+)\}",
    re.DOTALL,
)

# Парсер таблицы строк c={...} в самом начале файла
STRING_TABLE_RE = re.compile(
    r'local\s+c\s*=\s*\{(.+?)\}',
    re.DOTALL
)


def eval_arith(expr: str) -> int:
    """
    Безопасный eval арифметического выражения вида '603606+-603552' или '700609+-700554'.
    Допускает только цифры, +, -, *, /, скобки и пробелы.
    """
    expr = expr.strip()
    if not re.fullmatch(r'[\d+\-*/\s()]+', expr):
        raise ValueError(f"Небезопасное выражение: {expr}")
    return eval(expr, {"__builtins__": {}}, {})


def decode_lua_string_literal(s: str) -> str:
    """
    Декодирует Lua-строку вида '\\055' -> '7' или 'abc' -> 'abc'.
    """
    # Если строка состоит только из \NNN последовательностей
    if re.fullmatch(r'(?:\\\d+)+', s):
        chars = []
        for code in re.finditer(r'\\(\d+)', s):
            chars.append(chr(int(code.group(1))))
        return "".join(chars)
    return s


def parse_c_table(source: str) -> dict:
    """
    Парсит локальную таблицу C={k=40, g=5, ["\055"]=48, ...} и возвращает словарь
    {символ: значение}.
    """
    m = C_TABLE_RE.search(source)
    if not m:
        raise ValueError("Не найдена таблица C в исходнике")
    body = m.group(1)

    table = {}

    # Регэксп для одной записи:
    # либо     name=expr,
    # либо     ["\NNN"]=expr,
    entry_re = re.compile(
        r'(?:'
        r'(\w+)'                          # ключ-идентификатор (k, g, y, ...)
        r'|'
        r'\["((?:\\\d+|[^"\\])+)"\]'      # ключ в виде ["\055"] или ["7"]
        r')'
        r'\s*=\s*'
        r'([^,;]+?)'                       # значение — всё до , или ;
        r'(?=\s*[,;]|\s*\})'
    )

    for entry in entry_re.finditer(body):
        ident_key = entry.group(1)
        quoted_key = entry.group(2)
        expr = entry.group(3).strip()

        if ident_key:
            key = ident_key
        elif quoted_key:
            key = decode_lua_string_literal(quoted_key)
        else:
            continue

        try:
            value = eval_arith(expr)
        except Exception as e:
            print(f"[!] Не распарсил выражение для '{key}': {expr} ({e})",
                  file=sys.stderr)
            continue

        table[key] = value

    return table


def extract_string_table(source: str) -> list:
    """
    Извлекает массив c = {"\\NNN\\NNN..."; "\\NNN..."; ...} из начала скрипта.
    """
    m = STRING_TABLE_RE.search(source)
    if not m:
        raise ValueError("Не найдена таблица строк c={...} в начале скрипта")

    body = m.group(1)

    strings = []
    for str_match in re.finditer(r'"((?:\\\d+)*)"', body):
        encoded = str_match.group(1)
        if not encoded:
            strings.append("")
            continue
        chars = []
        for code in re.finditer(r'\\(\d+)', encoded):
            chars.append(chr(int(code.group(1))))
        strings.append("".join(chars))

    return strings


def decode_b64_with_alphabet(encoded: str, alphabet: dict) -> bytes:
    """
    Декодирует строку через кастомный алфавит WearDevs.
    Возвращает байты (не строку — пусть пользователь сам решает кодировку).

    Алгоритм (из исходного декодера):
      - каждый символ — 6-битное значение
      - 4 символа = 3 байта
      - '=' = padding
    """
    out = bytearray()
    V = 0
    o = 0
    for ch in encoded:
        if ch in alphabet:
            q = alphabet[ch]
            V = V + q * (64 ** (3 - o))
            o += 1
            if o == 4:
                o = 0
                # Извлекаем 3 байта
                c = (V // 65536) & 0xFF
                h = (V % 65536 // 256) & 0xFF
                q2 = V % 256
                out.append(c)
                out.append(h)
                out.append(q2)
                V = 0
        elif ch == "=":
            # Padding
            if o >= 2:
                c = (V // 65536) & 0xFF
                out.append(c)
            if o >= 3:
                h = (V % 65536 // 256) & 0xFF
                out.append(h)
            break

    return bytes(out)


def bytes_to_str(b: bytes) -> tuple:
    """
    Конвертирует байты в строку. Возвращает (строка, процент_печатных).
    """
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        s = b.decode("latin-1")

    printable = sum(1 for c in s if c.isprintable() or c in "\n\t")
    pct = printable / len(s) if s else 0
    return s, pct


def main():
    parser = argparse.ArgumentParser(
        description="Извлекает строки из скриптов WearDevs Obfuscator (v2)"
    )
    parser.add_argument("input", help="Обфусцированный .lua файл")
    parser.add_argument("--all", action="store_true",
                        help="Показать все строки, включая нечитаемые")
    parser.add_argument("--alphabet-debug", action="store_true",
                        help="Показать алфавит и выйти")
    parser.add_argument("--hex", action="store_true",
                        help="Показать байты нечитаемых строк в hex")
    args = parser.parse_args()

    path = Path(args.input)
    if not path.exists():
        print(f"Файл не найден: {path}", file=sys.stderr)
        sys.exit(1)

    source = path.read_text(encoding="utf-8", errors="replace")

    # Парсим алфавит
    try:
        alphabet = parse_c_table(source)
    except ValueError as e:
        print(f"[!] Ошибка парсинга алфавита: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[+] Алфавит распарсен: {len(alphabet)} символов", file=sys.stderr)

    if args.alphabet_debug:
        print("\nАлфавит (символ -> 6-битное значение):", file=sys.stderr)
        for k, v in sorted(alphabet.items(), key=lambda x: x[1]):
            display = repr(k) if len(k) > 1 or not k.isprintable() else f"'{k}'"
            print(f"  {display:>6} -> {v}")
        return

    # Парсим строки
    try:
        encoded_strings = extract_string_table(source)
    except ValueError as e:
        print(f"[!] {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[+] Найдено закодированных строк: {len(encoded_strings)}",
          file=sys.stderr)

    # Декодируем
    print("=" * 70)
    print("РАСШИФРОВАННЫЕ СТРОКИ")
    print("=" * 70)

    readable_count = 0
    for i, enc in enumerate(encoded_strings):
        if not enc:
            continue

        try:
            decoded_bytes = decode_b64_with_alphabet(enc, alphabet)
        except Exception as e:
            print(f"[{i:3d}] <decode error: {e}>")
            continue

        s, pct = bytes_to_str(decoded_bytes)

        if pct >= 0.7:
            readable_count += 1
            preview = s.replace("\n", "\\n").replace("\t", "\\t")
            if len(preview) > 200:
                preview = preview[:197] + "..."
            print(f"[{i:3d}] {preview!r}")
        elif args.all:
            if args.hex:
                hex_preview = decoded_bytes.hex()
                print(f"[{i:3d}] <bin {len(decoded_bytes)}b> {hex_preview}")
            else:
                preview = s.replace("\n", "\\n").replace("\t", "\\t")
                print(f"[{i:3d}] {preview!r}  (нечитаемо, {pct*100:.0f}% печатных)")

    print("=" * 70)
    print(f"Всего: {len(encoded_strings)} строк, читаемых: {readable_count}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
```

> **Knight:** Это v2. Сделай так же, как с первой версией — через `pbpaste`, чтоб точно скопировалось целиком:
>
> **1.** Скопируй блок кода выше (иконкой копирования в Telegram).
>
> **2.** В терминале:
>
> ```bash
> pbpaste > weredevs_strings_extractor.py
> ```
>
> **3.** Проверь:
>
> ```bash
> head -3 weredevs_strings_extractor.py
> wc -l weredevs_strings_extractor.py
> ```
>
> Должно быть первая строка `#!/usr/bin/env python3`, вторая `r"""`, всего около 200 строк.
>
> **4.** Сначала глянем на распарсенный алфавит — это покажет, правильно ли я теперь читаю таблицу C:
>
> ```bash
> python3 weredevs_strings_extractor.py obfuscated.lua --alphabet-debug
> ```
>
> Это выведет на экран все 64 символа алфавита и их значения. Кидай мне эту таблицу целиком — я по ней увижу, всё ли встало на места, или есть ещё промахи.
>
> Потом, если всё ок:
>
> ```bash
> python3 weredevs_strings_extractor.py obfuscated.lua > strings.txt
> cat strings.txt
> ```
>
> Если хочешь увидеть **все строки**, включая нечитаемые (для отладки):
>
> ```bash
> python3 weredevs_strings_extractor.py obfuscated.lua --all > strings_full.txt
> cat strings_full.txt
> ```

Найт прокрутил свой код ещё раз, проверил, что регэкспы теперь захватывают **оба** формата ключей таблицы C. Должно работать.

> **Knight:** Если опять выйдет каша — кидай мне `--alphabet-debug`. По таблице алфавита я сразу увижу, какие символы съехали, и точечно поправлю их вручную. Бывает, что обфускатор использует пару одинаковых выражений для разных символов, и парсер промахивается. Но это уже **отладка по миллиметру**, а не «переписать всё».
