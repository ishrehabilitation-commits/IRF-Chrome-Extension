# One-time setup for the "Update now" button

> **New Windows PC?** Double-click `setup\IRF-Setup.cmd` instead. It does
> everything below and more: installs Git if needed, downloads the extension,
> sets up Update now, and opens Chrome or Edge ready to add it. The file works
> on its own, so you can copy it to a network share and run it from there.

A Chrome extension can't run git by itself, so the panel asks a small script on
this computer to do it. Chrome only talks to that script if it has been
registered first, which is what the installer below does. You run it once per
computer; after that, updating is a click in the panel.

Without this setup, everything else still works. The panel simply tells people
to run `git pull` themselves.

## What you need first

- **git**, and a clone of this repository that the extension is loaded from.
  On Windows the installer handles both: if git is missing it offers to
  install it with winget, and if the folder was downloaded as a ZIP it links
  it to GitHub in place.
- On Windows, nothing else: the helper is a PowerShell script
  (`irf_updater.ps1`), and PowerShell comes with Windows.
- On a Mac, **Python 3**, which is usually already there. The Mac helper is
  `irf_updater.py`.

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

## If Update now says "Error when communicating with the native messaging host"

That means Chrome started the helper but it died before answering. To see why:

1. Look at `updater/updater.log` in the extension folder. Every run is logged
   there; if PowerShell itself failed to start the script, the reason is in
   `updater/updater-errors.log`.
2. Run the helper by hand, exactly as Chrome does, from Command Prompt in the
   extension folder:

   ```
   updater\irf_updater.bat --check
   ```

   It should print `OK: PowerShell 5.1…, git sees the extension folder`. On a
   Mac: `updater/irf_updater.py --check`.

If it says git can't be found, run the installer again; it will offer to
install Git.

If Windows says the script "is not digitally signed", use the
`powershell -ExecutionPolicy Bypass -File …` command above rather than running
the .ps1 directly.

To try a real update outside Chrome, use `--test` in place of `--check`.

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
