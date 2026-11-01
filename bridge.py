import io
import os
import random
import re
import socket
import threading
import time
import urllib.request

from PIL import Image

CHANNEL = "YOUR_CHANNEL_NAME"  # Twitch channel name (without #)
OUTBOX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "outbox.txt")
USER_COOLDOWN = 30
POKEDEX_COOLDOWN = 120
MAX_QUEUE = 10
LEVEL_MIN = 5
LEVEL_MAX = 25
LEVEL_CAP = 50

NAMES = [
    "Bulbasaur", "Ivysaur", "Venusaur", "Charmander", "Charmeleon", "Charizard",
    "Squirtle", "Wartortle", "Blastoise", "Caterpie", "Metapod", "Butterfree",
    "Weedle", "Kakuna", "Beedrill", "Pidgey", "Pidgeotto", "Pidgeot", "Rattata",
    "Raticate", "Spearow", "Fearow", "Ekans", "Arbok", "Pikachu", "Raichu",
    "Sandshrew", "Sandslash", "Nidoran F", "Nidorina", "Nidoqueen", "Nidoran M",
    "Nidorino", "Nidoking", "Clefairy", "Clefable", "Vulpix", "Ninetales",
    "Jigglypuff", "Wigglytuff", "Zubat", "Golbat", "Oddish", "Gloom", "Vileplume",
    "Paras", "Parasect", "Venonat", "Venomoth", "Diglett", "Dugtrio", "Meowth",
    "Persian", "Psyduck", "Golduck", "Mankey", "Primeape", "Growlithe", "Arcanine",
    "Poliwag", "Poliwhirl", "Poliwrath", "Abra", "Kadabra", "Alakazam", "Machop",
    "Machoke", "Machamp", "Bellsprout", "Weepinbell", "Victreebel", "Tentacool",
    "Tentacruel", "Geodude", "Graveler", "Golem", "Ponyta", "Rapidash", "Slowpoke",
    "Slowbro", "Magnemite", "Magneton", "Farfetchd", "Doduo", "Dodrio", "Seel",
    "Dewgong", "Grimer", "Muk", "Shellder", "Cloyster", "Gastly", "Haunter",
    "Gengar", "Onix", "Drowzee", "Hypno", "Krabby", "Kingler", "Voltorb",
    "Electrode", "Exeggcute", "Exeggutor", "Cubone", "Marowak", "Hitmonlee",
    "Hitmonchan", "Lickitung", "Koffing", "Weezing", "Rhyhorn", "Rhydon", "Chansey",
    "Tangela", "Kangaskhan", "Horsea", "Seadra", "Goldeen", "Seaking", "Staryu",
    "Starmie", "Mr. Mime", "Scyther", "Jynx", "Electabuzz", "Magmar", "Pinsir",
    "Tauros", "Magikarp", "Gyarados", "Lapras", "Ditto", "Eevee", "Vaporeon",
    "Jolteon", "Flareon", "Porygon", "Omanyte", "Omastar", "Kabuto", "Kabutops",
    "Aerodactyl", "Snorlax", "Articuno", "Zapdos", "Moltres", "Dratini",
    "Dragonair", "Dragonite", "Mewtwo", "Mew",
]
assert len(NAMES) == 151

def norm(s: str) -> str:
    s = s.lower().replace("\u2642", "m").replace("\u2640", "f")
    return re.sub(r"[^a-z0-9]", "", s)

ID_BY_NAME = {}
NAME_BY_ID = {}
for i, name in enumerate(NAMES, start=1):
    NAME_BY_ID[i] = name
    ID_BY_NAME[norm(name)] = i
ID_BY_NAME["nidoran"] = 32

LOCK = threading.Lock()
spawn_queue = []
gift_queue = []
emote_out = []
last_cmd = {}

def image_to_gba(img: Image.Image):
    img = img.convert("RGBA")
    img.thumbnail((64, 64), Image.LANCZOS)
    canvas = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    canvas.paste(img, ((64 - img.width) // 2, (64 - img.height) // 2))

    alpha = canvas.getchannel("A")
    mask = [a >= 128 for a in alpha.getdata()]
    rgb = canvas.convert("RGB")

    solid = [p for p, m in zip(rgb.getdata(), mask) if m]
    if not solid:
        raise ValueError("empty emote")
    avg = tuple(sum(c[i] for c in solid) // len(solid) for i in range(3))
    filled = Image.new("RGB", (64, 64))
    filled.putdata([p if m else avg for p, m in zip(rgb.getdata(), mask)])

    quant_method = getattr(Image, "Quantize", Image).MEDIANCUT
    q = filled.quantize(colors=15, method=quant_method)
    idx = list(q.getdata())
    pal = q.getpalette()[: 15 * 3]
    pal += [0] * (45 - len(pal))

    pal_bytes = bytearray(b"\x00\x00")
    for i in range(15):
        r, g, b = pal[i * 3: i * 3 + 3]
        v = (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
        pal_bytes += bytes((v & 0xFF, v >> 8))

    pixels = [(i + 1 if m else 0) for i, m in zip(idx, mask)]

    out = bytearray()
    for tr in range(8):
        for tc in range(8):
            for y in range(8):
                for x in range(0, 8, 2):
                    lo = pixels[(tr * 8 + y) * 64 + tc * 8 + x]
                    hi = pixels[(tr * 8 + y) * 64 + tc * 8 + x + 1]
                    out.append(lo | (hi << 4))
    assert len(out) == 2048 and len(pal_bytes) == 32
    return pal_bytes.hex(), out.hex()

def emote_to_gba_hex(emote_id: str):
    url = f"https://static-cdn.jtvnw.net/emoticons/v2/{emote_id}/static/dark/3.0"
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-firered-twitch-mod"})
    data = urllib.request.urlopen(req, timeout=10).read()
    return image_to_gba(Image.open(io.BytesIO(data)))

def process_emote(user: str, emote_id: str):
    try:
        pal_hex, tiles_hex = emote_to_gba_hex(emote_id)
    except Exception as e:
        print(f"[emote] could not process emote {emote_id}: {e}")
        return
    with LOCK:
        emote_out.clear()
        emote_out.append((user, pal_hex, tiles_hex))
    print(f"[emote] {user}: emote {emote_id} ready")

def parse_emotes(tag: str):
    res = []
    if not tag:
        return res
    for part in tag.split("/"):
        eid, _, ranges = part.partition(":")
        for rg in ranges.split(","):
            a, _, b = rg.partition("-")
            if a.isdigit() and b.isdigit():
                res.append((int(a), int(b), eid))
    return sorted(res)

def on_cooldown(user, cmd, privileged, cooldown=USER_COOLDOWN):
    if privileged:
        return False
    now = time.time()
    if now - last_cmd.get((user, cmd), 0) < cooldown:
        return True
    last_cmd[(user, cmd)] = now
    return False

def handle_message(user, text, tags):
    parts = text.split()
    if not parts:
        return
    cmd = parts[0].lower()
    privileged = tags.get("mod") == "1" or "broadcaster" in tags.get("badges", "")

    if cmd in ("!pokemon", "!pokedex") and len(parts) >= 2:
        name_parts = []
        level = None
        for p in parts[1:]:
            if p.isdigit():
                level = int(p)
                break
            name_parts.append(p)
        sid = ID_BY_NAME.get(norm("".join(name_parts)))
        if sid is None:
            return
        gift = cmd == "!pokedex"
        if on_cooldown(user, cmd, privileged, POKEDEX_COOLDOWN if gift else USER_COOLDOWN):
            return
        if level is None:
            level = random.randint(LEVEL_MIN, LEVEL_MAX)
        level = max(2, min(LEVEL_CAP, level))
        queue = gift_queue if gift else spawn_queue
        with LOCK:
            if len(queue) >= MAX_QUEUE:
                return
            queue.append((sid, level, NAME_BY_ID[sid], user))
        print(f"[{'gift' if gift else 'spawn'}] {user}: {NAME_BY_ID[sid]} lvl {level}")

    elif cmd == "!pokemonemote":
        emotes = [e for e in parse_emotes(tags.get("emotes", "")) if e[0] >= len(parts[0])]
        if not emotes:
            return
        if on_cooldown(user, "pokemonemote", privileged):
            return
        threading.Thread(target=process_emote, args=(user, emotes[0][2]), daemon=True).start()

def handle_line(line, send):
    if line.startswith("PING"):
        send("PONG :tmi.twitch.tv")
        return
    tags = {}
    if line.startswith("@"):
        raw, line = line.split(" ", 1)
        for kv in raw[1:].split(";"):
            k, _, v = kv.partition("=")
            tags[k] = v
    m = re.match(r":([^!]+)![^ ]+ PRIVMSG #\S+ :(.*)", line)
    if not m:
        return
    text = m.group(2)
    if text.startswith("\x01ACTION"):
        return
    handle_message(m.group(1), text, tags)

def irc_loop():
    while True:
        try:
            s = socket.create_connection(("irc.chat.twitch.tv", 6667), timeout=330)

            def send(t):
                s.sendall((t + "\r\n").encode("utf-8"))

            send("CAP REQ :twitch.tv/tags twitch.tv/commands")
            send("PASS SCHMOOPIIE")
            send(f"NICK justinfan{random.randint(10000, 99999)}")
            send("JOIN #" + CHANNEL.lower())
            print(f"[irc] connected to #{CHANNEL.lower()}")
            buf = ""
            while True:
                data = s.recv(4096)
                if not data:
                    raise ConnectionError("verbinding verbroken")
                buf += data.decode("utf-8", "replace")
                while "\r\n" in buf:
                    line, buf = buf.split("\r\n", 1)
                    handle_line(line, send)
        except Exception as e:
            print(f"[irc] error: {e} - retrying in 5s")
            time.sleep(5)

def flusher():
    pending = []
    while True:
        time.sleep(0.2)
        if os.path.exists(OUTBOX) and os.path.getsize(OUTBOX) > 0:
            continue
        with LOCK:
            if emote_out:
                user, pal_hex, tiles_hex = emote_out.pop()
                pending.append(f"E|{user}|{pal_hex}|{tiles_hex}")
            while spawn_queue:
                sid, level, name, user = spawn_queue.pop(0)
                pending.append(f"S|{sid}|{level}|{name}|{user}")
            while gift_queue:
                sid, level, name, user = gift_queue.pop(0)
                pending.append(f"G|{sid}|{level}|{name}|{user}")
        if not pending:
            continue
        try:
            tmp = OUTBOX + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(pending) + "\n")
            os.replace(tmp, OUTBOX)
            pending = []
        except OSError:
            pass

if __name__ == "__main__":
    threading.Thread(target=irc_loop, daemon=True).start()
    print(f"[outbox] writing to: {OUTBOX}")
    flusher()
