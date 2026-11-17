# Wallpaper-Engine-For-MAC
Use Steam wallpaper engine on your Macbook just copy the link of the wanted wallpaper and paste in the application use this commpan in Terminal to install rosetta( softwareupdate --install-rosetta --agree-to-license )
# Wallpaper Bridge

A macOS menu bar app that downloads Wallpaper Engine wallpapers from Steam Workshop links and puts them on your Mac desktop.

You paste a link like `https://steamcommunity.com/sharedfiles/filedetails/?id=1234567890`, the app downloads the item with Valve's SteamCMD, and then shows it on your desktop.

## What works on macOS

| Wallpaper type | What you get |
| --- | --- |
| **Video** (mp4, mov, webm) | Plays and loops behind your desktop icons on every screen and Space. Muted by default, with pause and mute buttons. |
| **Web** (HTML) | Runs in a WebKit view behind your icons. The wallpaper's default settings from `project.json` are passed in. Audio visualizers don't react, because there's no audio feed. |
| **Scene** | Can't be animated, because that needs Wallpaper Engine's own renderer. The app takes the largest picture inside the scene and sets it as your normal macOS wallpaper. Many "image" wallpapers are single-picture scenes, so you often get the full-resolution image. If no usable picture is found, the animated preview GIF is used instead. |
| **Application** (.exe) | Doesn't work. These are Windows programs. |

## Adjusting to your screen

Under **Adjust to screen** (below "Now showing"):

- **Fill** covers the whole screen and crops the edges. **Fit** shows the whole picture with black bars. **Stretch** fills the screen and distorts the picture. **Center** shows it at its real size.
- **Zoom** goes up to 3×. **Left ↔ Right** and **Top ↕ Bottom** choose which part stays on screen.
- Changes show up live and are saved for each wallpaper. Still pictures are re-rendered at each display's exact pixel size, so they stay sharp.
- Web wallpapers lay themselves out, so this panel doesn't appear for them.

## Reacting to audio and the cursor

In **Settings**:

- **React to cursor** (on by default): as your mouse moves over the desktop, web wallpapers get normal mouse-move events, just like in Wallpaper Engine, and the effects below can follow it. No permission is needed.
- **React to audio** (off by default): the app listens to what your Mac is playing, using ScreenCaptureKit, and passes Wallpaper Engine-style levels to web wallpapers: 64 frequency bands per channel, about 30 times a second. This makes audio-visualizer wallpapers work. macOS asks for **Screen & System Audio Recording** permission the first time. Only sound levels are measured; nothing is recorded or saved. If you run the app from Xcode, macOS may list **Xcode** in that permission list instead of Wallpaper Bridge, and may ask again after each rebuild.

When a web wallpaper asks for audio while this is off, the app offers to turn it on.

## Effects

Under **Effects** (below "Now showing"), for any wallpaper:

- **Particles:** snow, rain, fireflies, sakura petals, bubbles or twinkling stars, with an amount slider. They move out of the cursor's way, and speed up with the bass when audio is on.
- **Cursor:** **Parallax** shifts the wallpaper slightly as the mouse moves, for a sense of depth. **Soft light** puts a glow around the cursor.
- **Audio:** **Bass pulse** zooms the wallpaper on bass hits. **Visualizer bars** draws bars along the bottom of the screen.
- **Look:** brightness, saturation, blur and vignette.

Effects are saved for each wallpaper. A still picture with effects plays in a live window. Without effects it's only the macOS desktop picture, which uses no CPU. Videos now play in WebKit too, so every live wallpaper runs on the same engine.

## Lock screen and Spaces

macOS can't play video on the lock screen, and it uses your desktop picture there. With **Use on the lock screen too** on (in Settings), every wallpaper also sets a matching still as your macOS desktop picture:

- **Scenes and images:** the picture itself.
- **Videos:** a frame from about one second in.
- **Web wallpapers:** the preview image.

The still follows your Adjust settings. macOS keeps a separate desktop picture for each Space, so the app sets it again whenever you switch Spaces. You may need to lock the screen once (⌃⌘Q) before the lock screen picks up the change.

## Download progress

SteamCMD doesn't report how far a download has got, so the app watches the files grow on disk and compares that with the size Steam reports for the item. It shows a progress bar, how much has downloaded and the speed. The first run also shows SteamCMD updating itself.

## Requirements

- macOS 13 Ventura or later
- Xcode, or the Command Line Tools (`xcode-select --install`), to build the app
- A Steam account that **owns Wallpaper Engine**. Steam only lets accounts that own it download its Workshop items.
- On Apple Silicon: Rosetta, because SteamCMD is an Intel program. To install it, run `softwareupdate --install-rosetta`.

## Build and run (on the Mac)

```bash
cd WallpaperBridge
chmod +x build-app.sh
./build-app.sh
open "build/Wallpaper Bridge.app"
```

During development you can also run `swift run`, or open `Package.swift` in Xcode and press Run. When it's not built as a bundled app, "Open at login" is unavailable.

## First-time setup (in the app)

1. Click the menu bar icon.
2. Click **Install SteamCMD**. This downloads Valve's official `steamcmd_osx.tar.gz` into `~/Library/Application Support/WallpaperBridge/steamcmd`. If you already have SteamCMD, click **Choose Existing…** and pick it instead.
3. Under **Settings**, type your Steam username.
4. Paste a Workshop link and click **Download**. The first time, Steam asks you to sign in. Click **Sign in with Terminal**. Terminal opens and runs SteamCMD, and you type your password and Steam Guard code there, or approve the sign-in in the Steam mobile app. SteamCMD remembers the login, so after that downloads just work.

**The app never sees, stores or sends your Steam password.** Only SteamCMD handles it, inside Terminal.

## How it works

- `SteamWorkshop.swift` reads the item ID from the link and checks with Steam's public `GetPublishedFileDetails` API that it is a Wallpaper Engine item (app 431960).
- `SteamCMD.swift` runs `steamcmd +login <user> +workshop_download_item 431960 <id> validate +quit`. It reads the output to find where the files were saved and to spot when a sign-in is needed.
- `WallpaperImporter.swift` copies the files into `~/Library/Application Support/WallpaperBridge/Library/<id>`, reads `project.json` to tell the type, and for scenes unpacks `scene.pkg` to pull out the best still picture.
- `DesktopController.swift` shows animated wallpapers in borderless windows at desktop level, behind the icons and on all Spaces. These windows ignore the mouse and pause while the displays sleep. Still pictures go through `NSWorkspace.setDesktopImageURL`.
- The last wallpaper you used comes back when the app restarts.

## Known limits

- Scenes are still images, not animations.
- Web wallpapers that rely on Wallpaper Engine's audio or media hooks get harmless stand-in functions, so those features stay quiet.
- On macOS 14 and later, still pictures are set for the current Space. Animated wallpapers show on every Space.
- Video wallpapers keep decoding while windows cover the desktop. Pause them when you're on battery.
- Wallpapers are made by Workshop creators. Use them for your own desktop and respect each creator's terms.
