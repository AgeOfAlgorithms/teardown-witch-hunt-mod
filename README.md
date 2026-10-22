# Witch Hunt

A multiplayer social deduction game mode for [Teardown](https://teardowngame.com). Some of the players are secretly
witches, and they don't even know each other. Find them before they pick you off.

## How to play

- Pick **Witch Hunt** as the game mode on any map. The host chooses the number of witches, the round time, the amount
  of items and the time of day.
- At least 3 players. At most a third of them can be witches.
- Everyone is told their role in secret when the round starts. Everyone starts together near the middle of the map.
- When someone dies, everyone is told 4 seconds later, but not who or which side. The bodies keep their names.
- The lobby explains the rules. During a round, hold **L** to see your own side's rules and the players.

### Humans

- Win by killing all the witches, or by preventing them from killing anyone before the time runs out.
- **Fire reveals a witch:** after 3 seconds in fire she is forced out of her human shape.
- **Journals** lie around the map. Each one says one thing, who is a witch or who is a human, and only to the person
  reading it. Put it down and it crumbles to ash.

### Witches

- Kill every human, or kill at least one and survive until the time runs out.
- **Q: spirit form.** A white spirit for 15 seconds, then 60 seconds to recover. Fly with Space and Crouch, strike with
  LMB: three strikes kill. Bullets and blades pass through you; fire doesn't.
- Other witches see your name while you're a spirit. Humans don't.
- Don't touch a holy cross.

### Items

- **Pistol**, **knife**, or your bare hands if you have to.
- **Flamethrower**: enough fuel for about two witches.
- **Holy cross**: hold it up at a spirit to freeze her in the air.
- **Sensor**: shows where everyone is for a few seconds.
- **Medkit**, **walkie-talkie**, **speakerphone**.

E picks up, G drops.

## Voice, chat and pings

Walkie-talkies, the speakerphone and pings need the
[Proximity Comms](https://github.com/AgeOfAlgorithms/teardown-prox-text-chat-mod) mod, enabled by the host. The dead
talk only to each other. A ping reaches as far as your talk mode, and a spirit's pin shows no name.

## Install

Subscribe on the Steam Workshop, or clone this repository into `Documents/Teardown/mods/witch hunt`. Online play needs
the Workshop version: Teardown's multiplayer only allows published mods.

## Credits

Made by AgeOfAlgorithms with Claude (Anthropic).

- `mplib/`: Tuxedo Labs' multiplayer library ([tuxedolabsorg/mplib](https://github.com/tuxedolabsorg/mplib)), with small
  changes. It keeps its own licence.
- `fonts/NothingYouCouldDo.ttf`: the Nothing You Could Do font, SIL Open Font License (`fonts/OFL.txt`).
- Everything else: MIT (`LICENSE`).
