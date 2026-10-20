# Extra Magic Mouse

A free menu bar app that turns Magic Mouse touch gestures into **held arrow keys**,
for panning the camera in RTS games without pushing the pointer to the edge of the screen.

Rest two fingers on the mouse and push them forward, back, left or right. The matching
arrow key stays held for as long as you hold that direction, and diagonals work too.
Lift your fingers and the key is released.

## Features

- **Joystick mode** (default): push from where you first touched and hold to keep panning.
- **Drag mode**: keys are held only while your fingers are moving.
- **Flick glide**: flick and lift, and the view keeps going and slows to a stop.
  Put your fingers back down to stop it instantly. Choose Off, Short, Medium or Long;
  turn off *Slow Down Gradually* if a game stutters while the view slows.
- 1-finger or 2-finger trigger, four sensitivity levels, arrow keys or WASD,
  invert either axis.
- **Only in the games you list** (default), or everywhere.
- Blocks Magic Mouse scrolling while you pan, so the game doesn't zoom at the same time.
  One-finger scrolling still zooms when 2-finger panning is selected.
- **⌃⌥M** turns it on or off with a sound, so you can toggle it inside a full-screen game.
- Releases keys automatically if the mouse disconnects or sleeps mid-pan, so keys don't get stuck.
- Launch at Login.

## Build & install

You need macOS 13 or later and the Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```sh
git clone https://github.com/seastwood/ExtraMagicMouse.git
cd ExtraMagicMouse
./scripts/build_app.sh --install
```

The first build creates a self-signed signing certificate. Because every build is signed
with it, macOS keeps your Accessibility permission across rebuilds.

## First run

1. **Grant Accessibility**: System Settings → Privacy & Security → Accessibility →
   enable *Extra Magic Mouse*. The app asks for this on first launch. It's needed to
   send key presses and to block scrolling.
2. **Turn off the Magic Mouse's built-in swipes**, which would otherwise switch Spaces
   while you pan: System Settings → Mouse → *More Gestures* → turn off
   *Swipe between pages*, *Swipe between full-screen applications* and *Mission Control*.
3. Open your game, then click the mouse icon in the menu bar → **Add "‹game›" to Games**.

## Tips

- If forward pans the wrong way, use **Invert Forward/Back** (or Left/Right).
- To tune how far you push before panning starts, use **Sensitivity**. High means a tiny push.
- Games under CrossOver/Whisky/Wine are listed under the wrapper app's name.

## How it works

Magic Mouse touch data isn't exposed through any public API, so the app reads it from
Apple's private `MultitouchSupport.framework`, the same approach as BetterTouchTool and
MiddleClick. The framework is loaded at runtime. For each touch frame the app averages the
finger positions, compares them with where you first touched (or measures speed in drag mode),
and holds or releases synthetic key events. An event tap drops touch-surface scroll events
while you're panning.
