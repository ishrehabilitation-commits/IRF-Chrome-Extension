// Service worker: reads the WellSky session cookies (works even if they're
// HttpOnly, which page scripts can't see), checks GitHub for a newer version,
// and toggles the panel.

const COOKIE_NAMES = ["JSESSIONTOKEN", "ssoId"];

// The extension is loaded unpacked from a git checkout, so Chrome can't update
// it. Instead we compare our version with the manifest on main and let the
// panel tell the user to pull.
const LATEST_MANIFEST_URL =
  "https://raw.githubusercontent.com/ishrehabilitation-commits/IRF-Chrome-Extension/main/manifest.json";
const UPDATE_CHECK_EVERY_MS = 6 * 60 * 60 * 1000;
// updater/ holds a small script that runs git for us, since an extension
// can't. It only answers if the user ran one of the install scripts.
const UPDATER_HOST = "com.irf.minutes.updater";

const isNewer = (a, b) => {
  const pa = String(a).split(".").map(Number);
  const pb = String(b).split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d > 0;
  }
  return false;
};

async function latestVersion() {
  const { updateCheck } = await chrome.storage.local.get("updateCheck");
  if (updateCheck && Date.now() - updateCheck.at < UPDATE_CHECK_EVERY_MS) return updateCheck.version;
  // Offline, or the repo isn't readable without signing in: say nothing.
  const res = await fetch(LATEST_MANIFEST_URL, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const { version } = await res.json();
  await chrome.storage.local.set({ updateCheck: { at: Date.now(), version } });
  return version;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id) return;
  if (msg?.type === "irf:checkUpdate") {
    const current = chrome.runtime.getManifest().version;
    latestVersion()
      .then((latest) => sendResponse({ current, latest, outdated: isNewer(latest, current) }))
      .catch(() => sendResponse({ current, latest: null, outdated: false }));
    return true;
  }
  if (msg?.type === "irf:applyUpdate") {
    chrome.runtime
      .sendNativeMessage(UPDATER_HOST, { action: "update" })
      .then((result) => {
        if (!result?.ok) {
          sendResponse(result ?? { ok: false, error: "The updater didn't answer." });
          return;
        }
        chrome.storage.local.remove("updateCheck");
        sendResponse(result);
        // Reloading restarts this worker, so let the answer land first. Chrome
        // re-reads the folder from disk, which is how the new code takes hold.
        setTimeout(() => chrome.runtime.reload(), 1000);
      })
      .catch((err) =>
        sendResponse({
          ok: false,
          error: `${err.message} The updater may not be set up on this computer, or it failed to start; details are in updater/updater.log in the extension folder.`,
        }),
      );
    return true;
  }
  if (msg?.type === "irf:openExtensions") {
    chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` });
  }
});

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type !== "irf:getSession") return;

  // Only answer our own content script running on a WellSky page.
  let origin;
  try {
    origin = new URL(sender.url).origin;
  } catch {
    sendResponse(null);
    return;
  }
  if (sender.id !== chrome.runtime.id || !origin.endsWith(".specialtycare.wellsky.com")) {
    sendResponse(null);
    return;
  }

  const url = `${origin}/Interactant/`;
  Promise.all(COOKIE_NAMES.map((name) => chrome.cookies.get({ url, name })))
    .then(([token, sso]) => sendResponse({ token: token?.value ?? null, ssoId: sso?.value ?? null }))
    .catch(() => sendResponse(null));
  return true; // keep the channel open for the async response
});

chrome.action.onClicked.addListener((tab) => {
  if (!tab.id) return;
  chrome.tabs.sendMessage(tab.id, { type: "irf:toggle" }).catch(() => {
    // Not a WellSky tab (no content script there) — nothing to toggle.
  });
});
