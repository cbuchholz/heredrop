# HereDrop

HereDrop is a small macOS resident app for sharing files through here.now.

It adds:

- A borderless floating desktop avatar that stays above normal windows and joins all Spaces.
- File and folder drag-and-drop onto the avatar.
- Direct upload to `https://here.now/api/v1/publish`.
- Automatic clipboard copy of the public `https://<slug>.here.now/` URL.
- A status bar menu for copying or opening the last URL.
- Optional login item installation.

## Build

```bash
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

Drag the avatar to reposition it. Drop a file onto it to upload and copy the public URL. Right-click the avatar or use the `HN` status bar item for the last URL menu.

## Permanent here.now uploads

HereDrop reads credentials in this order:

1. `HERENOW_API_KEY`
2. `~/.herenow/credentials`

Without a key, here.now creates anonymous public sites that expire in 24 hours. With a saved key, uploads are permanent and saved to the account.

## Start at login

```bash
./scripts/install-login-item.sh
```

Remove it with:

```bash
./scripts/uninstall-login-item.sh
```

## CLI upload

The app binary also has a small command-line mode:

```bash
dist/HereDrop.app/Contents/MacOS/HereDrop --upload path/to/file.pdf
```

It prints the public URL and copies it to the clipboard.
