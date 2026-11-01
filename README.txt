If you'd like to support this project, consider donating! :) https://ko-fi.com/stonepixels

Pokemon FireRed Twitch mod

This lets your Twitch chat mess with Pokemon FireRed while you play.

Chat commands:

!pokemon <name> [level]
The next wild battle becomes that Pokemon.

!pokedex <name> [level]
You get that Pokemon in your party. If your party is full, the first Pokemon gets replaced.

!pokemonemote <emote>
The enemy sprite in the next wild battle becomes that Twitch emote.

Examples: !pokemon pikachu 12, !pokemon mr mime, !pokedex nidoran f 20, !pokemonemote Kappa
If you leave out the level, a random one is picked. Only the original 151 Pokemon work.


What you need

- VBA-rr (the version of VisualBoyAdvance with Lua support)
- English Pokemon FireRed, version 1.0 or 1.1
- Python 3.8 or newer, and Pillow (pip install pillow)

You don't need a Twitch login. The bridge just reads chat anonymously.


Setup

1. Open bridge.py and put your channel name in CHANNEL, without the #.

2. Run bridge.py (python bridge.py). It prints a line saying where it writes outbox.txt. Copy that path.

3. Open pokemon_twitch_firered.lua and paste that path in OUTBOX at the top. Use / instead of \ in the path.

4. Start FireRed in VBA-rr, open the Lua window (Tools > Lua Scripting > New Lua Script Window) and load pokemon_twitch_firered.lua.

5. Done. Keep bridge.py running while you play.

When the script loads, the Lua window prints the game code and the first Pokemon in your party. If that doesn't match your game, you're probably not on the English FireRed.


Things to know

- Spawns and emotes only work in wild battles, not trainer battles.
- Commands wait in a queue (max 10) and get used one per battle.
- !pokedex only works outside of battle. It also only starts working after you've done one wild battle, because the script needs that to check that it detects battles correctly. If gifts don't do anything, play one wild battle first.
- Chatters have a 30 second cooldown per command, 120 seconds for !pokedex. Mods and the broadcaster don't have a cooldown.
- Emotes get turned into a 64x64 sprite with 16 colors, so they look pixelated. If a new emote comes in during a battle, it's used in the next battle.

![image URL](https://github.com/Stonepixels/Pokemon-FireRed-Twitch-Intergration-mod/blob/main/Example.png)
![image URL](https://github.com/Stonepixels/Pokemon-FireRed-Twitch-Intergration-mod/blob/main/Example1.png)

