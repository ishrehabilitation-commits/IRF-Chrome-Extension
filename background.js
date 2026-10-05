// Service worker: reads the WellSky session cookies (works even if they're
// HttpOnly, which page scripts can't see) and toggles the panel.

const COOKIE_NAMES = ["JSESSIONTOKEN", "ssoId"];

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
