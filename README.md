# HereDrop

HereDrop is a small macOS desktop utility for sharing files through [here.now](https://here.now/).

It runs as a resident floating avatar. Drop a file or folder onto the avatar, and HereDrop uploads it to here.now and copies a public URL to your clipboard.

## Features

- Floating desktop avatar that stays above normal windows and joins all Spaces.
- File and folder drag-and-drop.
- Public URL copied to the system clipboard after each upload.
- Status bar menu for the last URL, project selection, and app controls.
- Quick Share mode for one-off uploads.
- Named project mode for appending files to one stable here.now site.
- Optional LaunchAgent installer to start at login.
- Credentials read from local environment or `~/.herenow/credentials`.

## Requirements

- macOS 13 or newer.
- Xcode command line tools with Swift available at `/usr/bin/swift`.
- A here.now account/API key for permanent uploads and named project sites.

Install Xcode command line tools if needed:

```bash
xcode-select --install
```

## Build

Clone the repo and build the app bundle:

```bash
git clone https://github.com/cbuchholz/heredrop.git
cd heredrop
./scripts/build.sh
```

The app bundle is created at:

```text
dist/HereDrop.app
```

## Run

```bash
open dist/HereDrop.app
```

You should see:

- A floating `HN` avatar on the desktop.
- An `HN` status bar item.

Drag the avatar to reposition it. Drop a file or folder onto it to upload. Right-click the avatar, or use the status bar item, to access the menu.

## Configure here.now Credentials

HereDrop reads the API key from these locations, in order:

1. `HERENOW_API_KEY`
2. `~/.herenow/credentials`

Recommended local setup:

```bash
mkdir -p ~/.herenow
printf '%s' 'YOUR_HERENOW_API_KEY' > ~/.herenow/credentials
chmod 600 ~/.herenow/credentials
```

Do not commit API keys. This repo ignores local here.now state with `.gitignore`, and HereDrop stores its own runtime project data outside the repo under:

```text
~/Library/Application Support/HereDrop
```

Without an API key, Quick Share uploads are anonymous here.now sites that expire in 24 hours. With an API key, uploads are authenticated and permanent.

Named project uploads require an API key because they update an owned here.now site by slug.

## Sharing Modes

### Quick Share

Quick Share is the default target. Each drop creates a new here.now site and copies the site URL.

Use this for one-off file shares.

### Named Projects

Named projects are for repeated sharing into one stable public site.

Create a project from the status bar menu:

```text
HN > Target > New Project...
```

Then enter:

- `Name`: the label shown in the menu.
- `Folder path inside site`: where files are placed inside that project's public site. The default is `uploads`.

When that project is selected, each dropped file is copied into the local project cache, the existing project site is republished, and the direct public file URL is copied to your clipboard.

Example copied URL:

```text
https://bright-canvas-a7k2.here.now/uploads/screenshot.png
```

If a project does not have a here.now slug yet, the first drop creates one and saves the slug locally. Later drops update the same site.

## Start at Login

Install the LaunchAgent:

```bash
./scripts/install-login-item.sh
```

Remove it:

```bash
./scripts/uninstall-login-item.sh
```

## CLI Upload

The app binary also has a command-line upload mode:

```bash
dist/HereDrop.app/Contents/MacOS/HereDrop --upload path/to/file.pdf
```

It prints the public URL and copies it to the clipboard.

## Security Notes

- Public here.now URLs are public internet URLs. Anyone with the URL can access the uploaded file unless you add protection outside this app.
- HereDrop never writes API keys into this repository.
- API keys are read at runtime from `HERENOW_API_KEY` or `~/.herenow/credentials`.
- Named project metadata and staged copies of shared files live in `~/Library/Application Support/HereDrop`.
- `dist/`, `.herenow/`, `.build/`, and common local build state are ignored by git.

## Development

Build:

```bash
./scripts/build.sh
```

Validate the app plist:

```bash
plutil -lint Resources/Info.plist dist/HereDrop.app/Contents/Info.plist
```

Verify local ad-hoc signing:

```bash
codesign --verify --deep --strict dist/HereDrop.app
```

Check tracked files:

```bash
git ls-files
```
