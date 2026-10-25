# Wraith Hunt

A multiplayer social deduction game mode for [Teardown](https://teardowngame.com). Some of the players are secretly
wraiths in human form, and they don't even know each other. Find them before they pick you off.

## How to play

- Pick **Wraith Hunt** as the game mode on any map. The host chooses the number of wraiths, the round time, the amount
  of items and the time of day.
- At least 3 players. At most a third of them can be wraiths.
- Everyone is told their role in secret when the round starts. Everyone starts together near the middle of the map.
- When someone dies, everyone is told 4 seconds later, but not who or which side. The bodies keep their names.
- The lobby explains the rules. During a round, hold **L** to see your own side's rules and the players.

### Humans

- Win by killing all the wraiths, or by preventing them from killing anyone before the time runs out.
- **Fire reveals a wraith:** after 2 seconds in fire she is forced out of human form into wraith form.
- **Journals** lie around the map. Each one says one thing, who is a wraith or who is a human, and only to the person
  reading it. Put it down and it crumbles to ash.

### Wraiths

- Kill every human, or kill at least one and survive until the time runs out.
- **Q: wraith form.** You leave human form for 15 seconds, then 60 seconds to recover. Fly with Space and Crouch, strike with
  LMB: three strikes kill. Bullets and blades pass through you; fire doesn't.
- Other wraiths see your name in wraith form. Humans don't.
- Don't touch a holy cross.

### Items

- **Pistol**, **knife**, or your bare hands if you have to.
- **Flamethrower**: enough fuel for about two wraiths.
- **Holy cross**: hold it up at a wraith in wraith form to freeze her in the air. It works twice, then cracks.
- **Sensor**: shows where everyone is for a few seconds.
- **Medkit**: hold LMB for 5 seconds to heal yourself, or RMB to heal the player in front of you. You crouch and can't move while you apply it.
- **Walkie-talkie**: everyone with one hears it, in hand or not. While it's in your hand, what you say or type goes
  through it; RMB switches it off and on.
- **Speakerphone**: while it's in your hand, your voice carries far; RMB switches it off and on.

E picks up, G drops. Walk or jump into a ledge up to chest height and you climb onto it (hold Crouch to let go).

## Voice, chat and pings

Walkie-talkies, the speakerphone and pings need the
[Proximity Comms](https://github.com/AgeOfAlgorithms/teardown-prox-text-chat-mod) mod, enabled by the host. The dead
talk only to each other. A ping reaches as far as your talk mode, and a pin from a wraith in wraith form shows no name.

## Install

Subscribe on the Steam Workshop, or clone this repository into `Documents/Teardown/mods/wraith hunt`. Online play needs
the Workshop version: Teardown's multiplayer only allows published mods.

## Credits

Made by AgeOfAlgorithms with Claude (Anthropic).

- `mplib/`: Tuxedo Labs' multiplayer library ([tuxedolabsorg/mplib](https://github.com/tuxedolabsorg/mplib)), with small
  changes. It keeps its own licence.
- `fonts/NothingYouCouldDo.ttf`: the Nothing You Could Do font, SIL Open Font License (`fonts/OFL.txt`).
- Everything else: MIT (`LICENSE`).
