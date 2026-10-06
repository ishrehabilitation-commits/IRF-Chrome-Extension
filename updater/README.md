# One-time setup for the "Update now" button

A Chrome extension can't run git by itself, so the panel asks a small script on
this computer to do it. Chrome only talks to that script if it has been
registered first, which is what the installer below does. You run it once per
computer; after that, updating is a click in the panel.

Without this setup, everything else still works. The panel simply tells people
to run `git pull` themselves.

## What you need first

- **git**, and a clone of this repository that the extension is loaded from.
- **Python 3** ([python.org](https://www.python.org/downloads/); on a Mac it is
  usually already there).

## Windows

Right-click `install-windows.ps1` and choose **Run with PowerShell**, or from a
PowerShell window in the extension folder:

```
powershell -ExecutionPolicy Bypass -File updater\install-windows.ps1
```

## Mac

In Terminal, from the extension folder:

```
bash updater/install-macos.sh
```

Restart Chrome afterwards. Then open the panel: when a newer version is on
GitHub, **Update now** pulls it and reloads the extension on its own. Refresh
the WellSky tab to pick up the new panel.

## Notes

- The extension's ID is pinned by the `key` in `manifest.json`, so every
  computer gets the same ID and these installers need no editing. **The first
  time you load a build that has this key, Chrome treats it as a new
  extension**: remove the old IRF Minutes entry at `chrome://extensions` and
  load the folder unpacked again. Facility and sort settings reset once.
- The updater only ever runs `git fetch` and `git merge --ff-only` in this
  folder. It won't throw away local edits; if there are any, it says so and
  does nothing.
- To remove it: delete the registry key
  `HKCU\Software\Google\Chrome\NativeMessagingHosts\com.irf.minutes.updater`
  on Windows, or
  `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.irf.minutes.updater.json`
  on a Mac.
