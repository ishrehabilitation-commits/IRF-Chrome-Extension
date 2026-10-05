// Runs in the WellSky page's own JavaScript world (not the extension's), so it
// can read WellSky's HCS global. The panel asks for the signed-in user ID with
// an "irf:getUserId" event and gets the answer back as "irf:userId".

document.addEventListener("irf:getUserId", () => {
  let userId = "";
  try {
    userId = String(window.HCS?.userId ?? "").trim();
  } catch {
    // HCS not there yet (still logging in) — answer with an empty ID.
  }
  document.dispatchEvent(new CustomEvent("irf:userId", { detail: userId }));
});
