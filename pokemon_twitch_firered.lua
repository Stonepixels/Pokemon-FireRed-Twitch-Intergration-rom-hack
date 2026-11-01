-- Enter the path that bridge.py prints on startup (use / as the separator)
local OUTBOX = "PATH/TO/outbox.txt"

local POLL_FRAMES   = 20
local EMOTE_FRAMES  = 1
local SETTLE_FRAMES = 8
local MAX_QUEUE     = 10
local CHECK_TRAINER = true

local STABLE_FRAMES = 3
local ENEMY_X_MIN   = 130
local ENEMY_X_MAX   = 200
local EMOTE_TIMEOUT = 1800

local GIFT_ONLY_VERIFIED = true
local GIFT_SETTLE        = 240
local REMOVE_FIRST_WHEN_FULL = true

local ADDR = {
  ENEMY_PARTY  = 0x0202402C,
  PLAYER_PARTY = 0x02024284,
  PARTY_COUNT  = 0x02024029,
  BATTLE_FLAGS = 0x02022B4C,
  IN_BATTLE    = 0x03003529,
}

math.randomseed(os.time())
local floor = math.floor
local rb = memory.readbyte
local function wb(a, v) memory.writebyte(a, v) end

local msg, msgFrames = "", 0
local function say(t) msg, msgFrames = t, 240; print(t) end

do
  local code = {}
  for i = 0, 3 do code[#code + 1] = string.char(rb(0x080000AC + i)) end
  code = table.concat(code)
  print("ROM game code: " .. code .. "  version: " .. rb(0x080000BC))
  if code ~= "BPRE" then
    print("WARNING: this is not the English FireRed (BPRE). The memory addresses are probably wrong.")
  end
end

local function bxor8(a, b)
  local r, p = 0, 1
  for _ = 1, 8 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a = (a - x) / 2; b = (b - y) / 2; p = p * 2
  end
  return r
end

local function split(line)
  local p = {}
  for s in line:gmatch("[^|]+") do p[#p + 1] = s end
  return p
end

local function hexToBytes(hex)
  local t = {}
  for i = 1, #hex, 2 do t[#t + 1] = tonumber(hex:sub(i, i + 1), 16) end
  return t
end

local ORDERS = {"GAEM","GAME","GEAM","GEMA","GMAE","GMEA","AGEM","AGME","AEGM","AEMG","AMGE","AMEG",
                "EGAM","EGMA","EAGM","EAMG","EMGA","EMAG","MGAE","MGEA","MAGE","MAEG","MEGA","MEAG"}

local function loadMon(base)
  local key, p = {}, 0
  for i = 0, 3 do
    key[i] = bxor8(rb(base + i), rb(base + 4 + i))
  end
  for i = 3, 0, -1 do p = p * 256 + rb(base + i) end
  local dec = {}
  for i = 0, 47 do dec[i] = bxor8(rb(base + 0x20 + i), key[i % 4]) end
  return { base = base, key = key, dec = dec, order = ORDERS[p % 24 + 1] }
end

local function subOff(m, ch) return (m.order:find(ch, 1, true) - 1) * 12 end

local function saveMon(m)
  local sum = 0
  for i = 0, 46, 2 do sum = sum + m.dec[i] + m.dec[i + 1] * 256 end
  sum = sum % 65536
  wb(m.base + 0x1C, sum % 256)
  wb(m.base + 0x1D, floor(sum / 256))
  for i = 0, 47 do wb(m.base + 0x20 + i, bxor8(m.dec[i], m.key[i % 4])) end
end

local function monSpecies(m)
  local g = subOff(m, "G")
  return m.dec[g] + m.dec[g + 1] * 256
end

local baseAddr = nil
do
  local sig = {45, 49, 49, 45, 65, 65, 12, 3, 45, 64}
  local a = 0x08200000
  while a < 0x08300000 do
    if a % 0x8000 == 0 then emu.frameadvance() end
    if rb(a) == 45 then
      local ok = true
      for i = 2, #sig do
        if rb(a + i - 1) ~= sig[i] then ok = false; break end
      end
      if ok and rb(a + 28) == 60 and rb(a + 29) == 62 then baseAddr = a; break end
    end
    a = a + 1
  end
  if baseAddr then
    print(string.format("Base stats found at 0x%08X", baseAddr))
  else
    print("ERROR: base stats not found in the ROM - spawns and gifts will not work")
  end
end

local TYPE_MOVE = { [0]=98, [1]=2, [2]=17, [3]=40, [4]=189, [5]=88, [6]=141, [7]=122,
                    [10]=52, [11]=55, [12]=22, [13]=84, [14]=93, [15]=181, [16]=82 }
local PP = { [33]=35, [98]=30, [2]=25, [17]=35, [40]=35, [189]=10, [88]=15, [141]=15, [122]=30,
             [52]=25, [55]=25, [22]=25, [84]=30, [93]=25, [181]=25, [82]=10, [34]=15, [38]=15 }

local function encodeName(name)
  local out = {}
  for ch in name:upper():gmatch(".") do
    local c, v = ch:byte(), nil
    if c >= 65 and c <= 90 then v = 0xBB + (c - 65)
    elseif c >= 48 and c <= 57 then v = 0xA1 + (c - 48)
    elseif ch == "." then v = 0xAD
    elseif ch == "-" then v = 0xAE
    elseif ch == "'" then v = 0xB4
    elseif ch == " " then v = 0x00 end
    if v and #out < 10 then out[#out + 1] = v end
  end
  while #out < 10 do out[#out + 1] = 0xFF end
  return out
end

local function expForLevel(rate, n)
  local n2, n3 = n * n, n * n * n
  local e
  if rate == 0 then e = n3
  elseif rate == 4 then e = floor(4 * n3 / 5)
  elseif rate == 5 then e = floor(5 * n3 / 4)
  elseif rate == 3 then e = floor(6 * n3 / 5) - 15 * n2 + 100 * n - 140
  elseif rate == 1 then
    if n <= 50 then e = floor(n3 * (100 - n) / 50)
    elseif n <= 68 then e = floor(n3 * (150 - n) / 100)
    elseif n <= 98 then e = floor(n3 * floor((1911 - 10 * n) / 3) / 500)
    else e = floor(n3 * (160 - n) / 100) end
  else
    if n <= 15 then e = floor(n3 * (floor((n + 1) / 3) + 24) / 50)
    elseif n <= 36 then e = floor(n3 * (n + 14) / 50)
    else e = floor(n3 * (floor(n / 2) + 32) / 50) end
  end
  if e < 0 then e = 0 end
  return e
end

local function fillMon(m, id, lvl, name, friendship)
  local base = m.base
  local g, a, e, mi = subOff(m, "G"), subOff(m, "A"), subOff(m, "E"), subOff(m, "M")
  local d = m.dec

  d[g] = id % 256; d[g + 1] = floor(id / 256)
  d[g + 2] = 0; d[g + 3] = 0
  local bs = baseAddr + (id - 1) * 28
  local exp = expForLevel(rb(bs + 19), lvl)
  d[g + 4] = exp % 256; d[g + 5] = floor(exp / 256) % 256
  d[g + 6] = floor(exp / 65536) % 256; d[g + 7] = 0
  d[g + 8] = 0
  if friendship then d[g + 9] = friendship end

  local B = { rb(bs), rb(bs + 1), rb(bs + 2), rb(bs + 3), rb(bs + 4), rb(bs + 5) }
  local type1 = rb(bs + 6)

  local moves = { 33, TYPE_MOVE[type1] or 98 }
  if lvl >= 20 then moves[#moves + 1] = 34 end
  if lvl >= 35 then moves[#moves + 1] = 38 end
  for i = 0, 3 do
    local mv = moves[i + 1] or 0
    d[a + i * 2] = mv % 256; d[a + i * 2 + 1] = floor(mv / 256)
    d[a + 8 + i] = (mv ~= 0) and (PP[mv] or 25) or 0
  end

  for i = 0, 11 do d[e + i] = 0 end

  local ivw = d[mi + 4] + d[mi + 5] * 256 + d[mi + 6] * 65536 + d[mi + 7] * 16777216
  local iv = {}
  for i = 0, 5 do iv[i + 1] = floor(ivw / 2 ^ (5 * i)) % 32 end

  saveMon(m)

  local function w16(off, v) wb(base + off, v % 256); wb(base + off + 1, floor(v / 256)) end
  for i = 0, 3 do wb(base + 0x50 + i, 0) end
  wb(base + 0x54, lvl)
  local hp = floor((2 * B[1] + iv[1]) * lvl / 100) + lvl + 10
  w16(0x56, hp); w16(0x58, hp)
  for i = 2, 6 do
    w16(0x5A + (i - 2) * 2, floor((2 * B[i] + iv[i]) * lvl / 100) + 5)
  end

  local nick = encodeName(name)
  for i = 0, 9 do wb(base + 8 + i, nick[i + 1]) end
end

local function rewriteEnemy(id, lvl, name)
  if not baseAddr then return false end
  fillMon(loadMon(ADDR.ENEMY_PARTY), id, lvl, name, nil)
  return true
end

local function partyCheck()
  local count = rb(ADDR.PARTY_COUNT)
  if count == 0 then return "empty" end
  if count > 6 then return "bad" end
  local n = 0
  for s = 0, 5 do
    local sp = monSpecies(loadMon(ADDR.PLAYER_PARTY + s * 100))
    if sp ~= 0 and sp < 500 then n = n + 1 end
  end
  if n ~= count then return "bad" end
  return "ok"
end

local function giveMon(id, lvl, name)
  if not baseAddr then return false, "base stats missing" end
  local P = ADDR.PLAYER_PARTY
  local count = rb(ADDR.PARTY_COUNT)

  local ot, otName = {}, {}
  for i = 0, 3 do ot[i] = rb(P + 4 + i) end
  for i = 0, 6 do otName[i] = rb(P + 0x14 + i) end
  local lang = rb(P + 0x12)

  local slot
  if count >= 6 then
    if not REMOVE_FIRST_WHEN_FULL then return false, "party full" end
    for i = 0, 499 do wb(P + i, rb(P + 100 + i)) end
    slot = 5
  else
    slot = count
    wb(ADDR.PARTY_COUNT, count + 1)
  end

  local base = P + slot * 100
  for i = 0, 99 do wb(base + i, 0) end
  for i = 0, 3 do
    wb(base + i, math.random(0, 255))
    wb(base + 4 + i, ot[i])
  end
  wb(base + 0x12, lang)
  wb(base + 0x13, 0x02)
  for i = 0, 6 do wb(base + 0x14 + i, otName[i]) end
  wb(base + 0x55, 0xFF)

  local m = loadMon(base)
  for i = 0, 47 do m.dec[i] = 0 end
  local mi = subOff(m, "M")
  m.dec[mi + 2] = lvl
  m.dec[mi + 3] = 34
  m.dec[mi + 4] = math.random(0, 255)
  m.dec[mi + 5] = math.random(0, 255)
  m.dec[mi + 6] = math.random(0, 255)
  m.dec[mi + 7] = math.random(0, 63) + math.random(0, 1) * 128

  fillMon(m, id, lvl, name, 70)
  return true
end

local pendingPal, pendingTiles = nil, nil
local queuedPal, queuedTiles = nil, nil
local emoteActive = false
local lock = nil
local appliedFrames, missingFrames, waitFrames = 0, 0, 0
local sigPrev, sigCnt = {}, {}
local battleTile, battleBank = nil, nil
local pltOK = false

local PLT_FADED, PLT_UNFADED = 0x020371F8, 0x020375F8

local function readObj(i)
  local o = 0x07000000 + i * 8
  return memory.readwordunsigned(o), memory.readwordunsigned(o + 2), memory.readwordunsigned(o + 4)
end

local function is64(a0, a1)
  local mode  = floor(a0 / 256) % 4
  local col   = floor(a0 / 8192) % 2
  local shape = floor(a0 / 16384) % 4
  local size  = floor(a1 / 16384) % 4
  return mode ~= 2 and col == 0 and shape == 0 and size == 3
end

local function findEnemySprite()
  for i = 0, 127 do
    local a0, a1, a2 = readObj(i)
    local x, y = a1 % 512, a0 % 256
    if is64(a0, a1) and x >= 100 and x < 240 and y < 110 then
      return a2 % 1024, floor(a2 / 4096) % 16
    end
  end
  return nil
end

local function trackSprites()
  for i = 0, 127 do
    local a0, a1, a2 = readObj(i)
    if is64(a0, a1) then
      local x, y = a1 % 512, a0 % 256
      local sig = a0 + a1 * 65536 + a2 * 4294967296
      if sigPrev[i] == sig then sigCnt[i] = (sigCnt[i] or 0) + 1 else sigPrev[i] = sig; sigCnt[i] = 0 end
      local t, bk = a2 % 1024, floor(a2 / 4096) % 16
      local sameSprite = (battleTile == nil) or (t == battleTile and bk == battleBank)
      if sameSprite and sigCnt[i] >= STABLE_FRAMES and x >= ENEMY_X_MIN and x <= ENEMY_X_MAX and y <= 56 then
        return i, t, bk
      end
    else
      sigPrev[i] = nil; sigCnt[i] = 0
    end
  end
  return nil
end

local function lockValid()
  for i = 0, 127 do
    local a0, a1, a2 = readObj(i)
    if is64(a0, a1) and a2 % 1024 == lock.tile and floor(a2 / 4096) % 16 == lock.bank then
      local x = a1 % 512
      if x >= 100 and x < 240 then lock.idx = i; return true end
    end
  end
  return false
end

local function isOneD()
  return floor(memory.readwordunsigned(0x04000000) / 64) % 2 == 1
end

local function tileAddr(tile, idx, oned)
  local t
  if oned then t = tile + idx else t = tile + floor(idx / 8) * 32 + idx % 8 end
  return 0x06010000 + (t % 1024) * 32
end

local function writeEmote(tile, bank)
  local pb = 0x05000200 + bank * 32
  for i = 0, 31, 2 do
    local v = pendingPal[i + 1] + pendingPal[i + 2] * 256
    memory.writeword(pb + i, v)
    if pltOK then
      memory.writeword(PLT_FADED + 0x200 + bank * 32 + i, v)
      memory.writeword(PLT_UNFADED + 0x200 + bank * 32 + i, v)
    end
  end
  local oned = isOneD()
  for idx = 0, 63 do
    local va, sb = tileAddr(tile, idx, oned), idx * 32
    for j = 0, 30, 2 do
      memory.writeword(va + j, pendingTiles[sb + j + 1] + pendingTiles[sb + j + 2] * 256)
    end
  end
end

local function verifyPlt()
  local nz = 0
  for i = 0, 511 do if rb(0x05000200 + i) ~= 0 then nz = nz + 1 end end
  if nz < 64 then return false end
  for _, b in ipairs({ PLT_FADED, PLT_UNFADED }) do
    local same = 0
    for i = 0, 511 do
      if rb(0x05000200 + i) == rb(b + 0x200 + i) then same = same + 1 end
    end
    if same >= 500 then return true end
  end
  return false
end

local function dumpOam(reason)
  print("[diag] " .. reason .. " | locked: obj " .. lock.idx .. " tile " .. lock.tile .. " bank " .. lock.bank)
  for i = 0, 127 do
    local a0, a1, a2 = readObj(i)
    if floor(a0 / 256) % 4 ~= 2 and a0 % 256 < 160 then
      local t, bk = a2 % 1024, floor(a2 / 4096) % 16
      local shape, size = floor(a0 / 16384) % 4, floor(a1 / 16384) % 4
      local near = (t >= lock.tile - 31 and t <= lock.tile + 63)
      if near or (bk == lock.bank and i ~= lock.idx) then
        print(string.format("[diag]  obj %3d shape=%d size=%d x=%3d y=%3d tile=%3d bank=%2d prio=%d%s",
          i, shape, size, a1 % 512, a0 % 256, t, bk, floor(a2 / 1024) % 4, i == lock.idx and "  <- locked" or ""))
      end
    end
  end
end

local function clearEmote()
  pendingPal, pendingTiles = queuedPal, queuedTiles
  queuedPal, queuedTiles = nil, nil
  emoteActive, lock = false, nil
  appliedFrames, missingFrames, waitFrames = 0, 0, 0
  sigPrev, sigCnt = {}, {}
  battleTile, battleBank = nil, nil
end

local function ewramFind(sig)
  local hits, n, first = {}, #sig, sig[1]
  local a, last = 0x02000000, 0x02040000 - #sig
  while a <= last do
    if a % 0x4000 == 0 then emu.frameadvance() end
    if rb(a) == first then
      local ok = true
      for i = 2, n do
        if rb(a + i - 1) ~= sig[i] then ok = false; break end
      end
      if ok then hits[#hits + 1] = a end
    end
    a = a + 1
  end
  return hits
end

local function scanSources(tile, bank)
  local oned = isOneD()
  local data, k = {}, nil
  for idx = 0, 63 do
    local addr = tileAddr(tile, idx, oned)
    for i = 0, 31 do
      local v = rb(addr + i)
      data[idx * 32 + i + 1] = v
      if v ~= 0 and not k then k = idx end
    end
  end
  if not k then return false end

  local sig = {}
  for i = 1, 32 do sig[i] = data[k * 32 + i] end
  local tileHits = 0
  for _, c in ipairs(ewramFind(sig)) do
    local start = c - k * 32
    if start >= 0x02000000 and start + 2048 <= 0x02040000 then
      local ok = true
      for i = 1, 2048 do
        if rb(start + i - 1) ~= data[i] then ok = false; break end
      end
      if ok then
        for rep = 0, 1 do
          local s = start + rep * 2048
          if s + 2048 <= 0x02040000 then
            for i = 0, 2047 do wb(s + i, pendingTiles[i + 1]) end
          end
        end
        tileHits = tileHits + 1
      end
    end
  end

  pltOK = verifyPlt()
  local palHits = 0
  if not pltOK then
    local pb = 0x05000200 + bank * 32
    local psig, nz = {}, 0
    for i = 1, 32 do psig[i] = rb(pb + i - 1); if psig[i] ~= 0 then nz = nz + 1 end end
    if nz >= 8 then
      local ph = ewramFind(psig)
      if #ph <= 4 then
        for _, a in ipairs(ph) do
          for i = 1, 32 do wb(a + i - 1, pendingPal[i]) end
          palHits = palHits + 1
        end
      end
    end
  end
  print(string.format("[emote] sprite tile=%d palette-bank=%d mapping=%s | source copies: tiles=%d palette=%d | palette buffers %s",
        tile, bank, oned and "1D" or "2D", tileHits, palHits, pltOK and "OK" or "NOT found (fallback method)"))
  return true
end

local spawnQ, giftQ = {}, {}

local function readOutbox()
  local f = io.open(OUTBOX, "r")
  if not f then return end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then return end

  local w = io.open(OUTBOX, "w")
  if w then w:close() end

  for line in data:gmatch("[^\r\n]+") do
    local p = split(line)
    if p[1] == "S" and #spawnQ < MAX_QUEUE then
      spawnQ[#spawnQ + 1] = { id = tonumber(p[2]), lvl = tonumber(p[3]), name = p[4] or "?", user = p[5] or "?" }
      print("[queue] " .. (p[5] or "?") .. ": " .. (p[4] or "?") .. " L" .. (p[3] or "?"))
    elseif p[1] == "G" and #giftQ < MAX_QUEUE then
      giftQ[#giftQ + 1] = { id = tonumber(p[2]), lvl = tonumber(p[3]), name = p[4] or "?", user = p[5] or "?" }
      print("[gift-queue] " .. (p[5] or "?") .. ": " .. (p[4] or "?") .. " L" .. (p[3] or "?"))
    elseif p[1] == "E" and p[3] and p[4] then
      local pal, tiles = hexToBytes(p[3]), hexToBytes(p[4])
      if #pal == 32 and #tiles == 2048 then
        if emoteActive then
          queuedPal, queuedTiles = pal, tiles
        else
          pendingPal, pendingTiles = pal, tiles
        end
        say((p[2] or "?") .. ": emote ready for the next battle")
      end
    end
  end
end

local function curKey()
  local p, o = 0, 0
  for i = 3, 0, -1 do
    p = p * 256 + rb(ADDR.ENEMY_PARTY + i)
    o = o * 256 + rb(ADDR.ENEMY_PARTY + 4 + i)
  end
  return p, o
end

local function isTrainerBattle()
  return floor(rb(ADDR.BATTLE_FLAGS) / 8) % 2 == 1
end

local function inBattleBit()
  return floor(rb(ADDR.IN_BATTLE) / 2) % 2
end

local function onNewEnemy()
  local m = loadMon(ADDR.ENEMY_PARTY)
  local sp, lv = monSpecies(m), rb(ADDR.ENEMY_PARTY + 0x54)
  local trainer = isTrainerBattle()
  print(string.format("[detect] new enemy: species %d, level %d, flags=0x%02X%s",
        sp, lv, rb(ADDR.BATTLE_FLAGS), trainer and " (trainer)" or ""))
  if CHECK_TRAINER and trainer then return end
  if pendingTiles and not emoteActive then
    emoteActive, lock = true, nil
    appliedFrames, missingFrames, waitFrames = 0, 0, 0
    sigPrev, sigCnt = {}, {}
    battleTile, battleBank = nil, nil
    print("[emote] applying emote to the enemy in this battle")
  end
  if #spawnQ > 0 then
    local s = table.remove(spawnQ, 1)
    if rewriteEnemy(s.id, s.lvl, s.name) then
      say(s.user .. ": " .. s.name .. " L" .. s.lvl)
    end
  end
end

print("Pokemon FireRed x Twitch mod active. Outbox: " .. OUTBOX)
do
  local m = loadMon(ADDR.PLAYER_PARTY)
  print(string.format("[self-check] first pokemon in your party: species %d, level %d, party size %d",
        monSpecies(m), rb(ADDR.PLAYER_PARTY + 0x54), rb(ADDR.PARTY_COUNT)))
  print("   (if this does not match your real party, the memory addresses are wrong)")
end

local frame, settle = 0, 0
local lastP, lastO = nil, nil
local lastEnemyChange, lastSpriteFrame = -100000, -100000
local flagVerified, spriteNoFlag = nil, 0
local warnedWait = false

local function canGift()
  if inBattleBit() == 1 then return false end
  if GIFT_ONLY_VERIFIED and flagVerified ~= true then
    if not warnedWait then
      warnedWait = true
      print("[gift] waiting for the battle flag to be verified: do 1 (wild) battle first.")
    end
    return false
  end
  if frame - lastEnemyChange < GIFT_SETTLE then return false end
  if frame - lastSpriteFrame < GIFT_SETTLE then return false end
  return true
end

while true do
  frame = frame + 1

  if frame % POLL_FRAMES == 0 then readOutbox() end

  local p, o = curKey()
  if lastP == nil then
    lastP, lastO = p, o
  elseif p ~= lastP or o ~= lastO then
    lastP, lastO = p, o
    lastEnemyChange = frame
    if p ~= 0 or o ~= 0 then settle = SETTLE_FRAMES end
  end
  if settle > 0 then
    settle = settle - 1
    if settle == 0 then onNewEnemy() end
  end

  local tile, bank
  if frame % 10 == 0 then tile, bank = findEnemySprite() end
  if tile then lastSpriteFrame = frame end

  if frame % 10 == 0 then
    if tile then
      if inBattleBit() == 1 then
        if flagVerified ~= true then print("[check] in-battle flag is correct"); end
        flagVerified, spriteNoFlag = true, 0
      else
        spriteNoFlag = spriteNoFlag + 10
        if spriteNoFlag >= 300 and flagVerified == nil then
          flagVerified = false
          print("[check] WARNING: sprite visible but in-battle flag (0x03003529) stays 0 - address is probably wrong")
        end
      end
    else
      spriteNoFlag = 0
    end
  end

  if pendingTiles and emoteActive then
    if lock then
      if lockValid() then
        missingFrames = 0
        if not pltOK then
          pltOK = verifyPlt()
          if pltOK then print("[emote] palette buffers confirmed") end
        end
        if frame % EMOTE_FRAMES == 0 then
          writeEmote(lock.tile, lock.bank)
          appliedFrames = appliedFrames + 1
          if appliedFrames == 150 or appliedFrames == 600 then dumpOam("after " .. appliedFrames .. " frames") end
        end
        lastSpriteFrame = frame
      else
        print("[emote] enemy sprite gone, lock released")
        lock = nil
        sigPrev, sigCnt = {}, {}
      end
    else
      local idx, t, bk = trackSprites()
      if idx and t + 63 <= 1023 and (battleTile ~= nil or scanSources(t, bk)) then
        lock = { idx = idx, tile = t, bank = bk }
        battleTile, battleBank = t, bk
        missingFrames = 0
        if appliedFrames == 0 then dumpOam("on lock") end
        print(string.format("[emote] locked on OAM object %d (tile %d, bank %d)", idx, t, bk))
      elseif appliedFrames > 0 then
        missingFrames = missingFrames + 1
        if missingFrames > 90 then
          print("[emote] battle over, emote cleared")
          clearEmote()
        end
      else
        waitFrames = waitFrames + 1
        if waitFrames > EMOTE_TIMEOUT then
          print("[emote] no enemy sprite found, emote waits for the next battle")
          emoteActive, waitFrames = false, 0
          sigPrev, sigCnt = {}, {}
        end
      end
    end
  end

  if #giftQ > 0 and frame % 30 == 0 and canGift() then
    local st = partyCheck()
    if st == "ok" then
      local s = table.remove(giftQ, 1)
      local ok, why = giveMon(s.id, s.lvl, s.name)
      if ok then say(s.user .. " gives you " .. s.name .. " L" .. s.lvl)
      else print("[gift] failed: " .. tostring(why)) end
    elseif st == "bad" then
      table.remove(giftQ, 1)
      print("[gift] ERROR: party size address (0x02024029) does not match the party data - gift cancelled")
    end
  end

  if msgFrames > 0 then
    gui.text(2, 2, msg)
    msgFrames = msgFrames - 1
  end

  emu.frameadvance()
end
