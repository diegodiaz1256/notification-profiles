function isChromiumDerived(app, appIcon) {
  var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  return source.indexOf("chrom") >= 0 || source.indexOf("brave") >= 0 ||
         source.indexOf("vivaldi") >= 0 || source.indexOf("microsoft-edge") >= 0 ||
         source.indexOf("opera") >= 0
}

// True when a `<...>` run is an image tag, so the name is read the way Qt's
// parser reads it: after the `<`, the leading run of letters and digits.
//
// Skip everything up to that run rather than matching the separator, because
// there is no JavaScript expression for what Qt skips. QQuickStyledText calls
// skipSpace(), which is QChar::isSpace(), and that set is not `\s`: Qt counts
// U+0085 NEL and `\s` does not, while `\s` counts U+FEFF and Qt does not. A
// name read with `\s` therefore misses a tag written as `<`, U+0085, `img`:
// Qt skips the NEL, reads `img` and issues the GET, while the regex finds no
// name at all and the tag is kept. Measured against Qt 6.11.2.
//
// Over-skipping is the safe direction. It can only classify more runs as
// images, and dropping a run never manufactures a tag: a dropped run joins two
// stretches of text that each contain no `<`.
function isImageTag(tag) {
  var name = /^<[^A-Za-z0-9]*([A-Za-z0-9]+)/.exec(tag)
  return !!name && name[1].toLowerCase() === "img"
}

// The body renders as StyledText so notifications can use the markup the
// body-markup capability advertises (see Service.qml). StyledText honours
// <img src>, and a remote src makes the shell issue an unauthenticated GET
// with no user action, so image tags go before the renderer sees them.
//
// Work in whole tags, never in substrings of one. A `<` opens a tag that runs
// to the next `>`, nested `<` and all, and only a tag whose own name is `img`
// is dropped.
//
// That is the conservative bound, not Qt's exact one: Qt lets a `>` inside a
// quoted attribute value pass without closing the tag, so a Qt tag can be
// longer than the run taken here. Do not "correct" this to match Qt. Taking
// the shorter run only ever splits one Qt tag into several, and a split can
// only expose an `<img` to be dropped, never hide one — whereas honouring
// quotes would let `<b title="a>b"><img src="http://host/x.png">` through.
//
// Deleting a substring is what makes a naive `/<img[^>]*>/g` unsafe. Given
//
//   <im<img src="http://a/decoy.png">g src="http://a/beacon.png">
//
// Qt reads ONE malformed tag named `im` and renders nothing, but removing the
// inner match closes the surviving halves up into `<img src=".../beacon.png">`
// — a live tag the input never contained. The stripper would be manufacturing
// the very thing it exists to remove.
//
// Because every `<` opens a tag, the text between tags never contains one, so
// dropping a tag cannot splice its neighbours into a new one. That makes a
// single pass sufficient, with no re-scanning and no input bound to police.
function stripImageTags(text) {
  var out = ""
  var i = 0

  while (i < text.length) {
    var open = text.indexOf("<", i)
    if (open === -1) {
      out += text.slice(i)
      break
    }

    out += text.slice(i, open)

    // An unterminated tag at the end of the string still reaches the renderer,
    // which closes it itself, so treat the remainder as one tag.
    var close = text.indexOf(">", open)
    var tag = close === -1 ? text.slice(open) : text.slice(open, close + 1)

    if (!isImageTag(tag)) out += tag
    i = close === -1 ? text.length : close + 1
  }

  return out
}

// What the card renders, and the last thing to touch the string before Qt parses
// it. The newline rewrite belongs here rather than in the card because it inserts
// `<br/>` into text stripImageTags chose to KEEP, and a kept tag may hold a `<` of
// its own: `<x`, newline, `<img src="http://…">` is one tag named `x` to both the
// stripper and Qt, until the rewrite splits it into `<x<br/>` and a live image tag
// the input never contained. Measured against Qt 6.11.2 — the rewritten form
// fetches, the original does not. So strip again after, and what Qt parses is what
// was checked last.
function styledBody(body, app, appIcon) {
  return stripImageTags(sanitizeBody(body, app, appIcon).replace(/\r\n|\r|\n/g, "<br/>"))
}

function sanitizeBody(body, app, appIcon) {
  var text = stripImageTags(String(body || ""))
  if (!isChromiumDerived(app, appIcon)) return text

  return text
    .replace(/^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i, "")
    .replace(/^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i, "")
}

// Chromium web-notification bodies lead with the sending page's own URL, as
// either a bare "www.example.com" line or a "<a href=...>...</a>" tag —
// sanitizeBody strips it as redundant display noise, but it's the one piece
// of data that can point a click at the right page rather than just the
// browser's window. Pulled from the raw (pre-sanitize) body, since the
// stripped text has already lost it by the time a click needs it.
function bodyLinkUrl(body) {
  var text = String(body || "")
  var hrefMatch = text.match(/^\s*<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>/i)
  if (hrefMatch) return hrefMatch[1]

  var bareMatch = text.match(/^\s*((?:https?:\/\/|www\.)(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?)/i)
  if (bareMatch) return /^https?:\/\//i.test(bareMatch[1]) ? bareMatch[1] : "https://" + bareMatch[1]

  return ""
}

function summaryStartsWithGlyph(summary) {
  var text = String(summary || "").replace(/^\s+/, "")
  if (!text) return false

  var offset = 1
  var first = text.charCodeAt(0)
  if (first >= 0xd800 && first <= 0xdbff && text.length > 1) offset = 2

  var spaces = 0
  while (offset < text.length && text.charAt(offset) === " ") {
    spaces++
    offset++
  }

  return spaces >= 2
}

function shouldBypassDnd(notification, criticalUrgency) {
  var appName = String((notification && notification.appName) || "")
  if (appName === "omarchy-action") return true
  return appName === "notify-send" && notification && notification.urgency === criticalUrgency
}

function isEphemeralApp(appName) {
  var name = String(appName || "")
  return name === "notify-send" || name === "omarchy-action"
}

function stringHint(hints, name) {
  try {
    if (hints) {
      var value = hints[name]
      if (value !== undefined && value !== null) return String(value)
    }
  } catch (e) {
  }
  return ""
}

function glyphFromHints(hints) {
  return stringHint(hints, "omarchy-glyph")
}

// The click action: a JSON argv string from omarchy-notification-send
// --exec. Carried as data so a toast restored after a shell restart stays
// clickable (a libnotify action can't — its sender is gone). Run via
// Util.execArgv as bash positional parameters, never a shell string, so
// attacker-controlled values (a title, a filename) can't become commands.
function execArgvFromHints(hints) {
  return stringHint(hints, "omarchy-exec-argv")
}

// Validate a persisted omarchy-exec-argv into a runnable argv, or null. This is
// a STRUCTURAL check only: it fails closed on a malformed hint (non-array, a
// non-string or empty program, or a leading-dash program that argv would read as
// an option). It does not judge intent — a well-formed ["bash","-c",…] is
// accepted. WHICH senders may set this hint is a separate boundary: any
// session-bus process can, by the freedesktop protocol's design (see
// docs/notifications.md), which is equivalent to same-uid code execution.
function parseExecArgv(value) {
  var text = String(value || "")
  if (!text) return null

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }

  if (!Array.isArray(parsed) || parsed.length === 0) return null
  for (var i = 0; i < parsed.length; i++) {
    if (typeof parsed[i] !== "string") return null
  }
  if (!parsed[0] || parsed[0].charAt(0) === "-") return null
  return parsed
}

function shouldRenderCompactGlyph(glyph, iconSource, singleLineToast) {
  return String(glyph || "").length > 0 && String(iconSource || "").length === 0 && !!singleLineToast
}

// What "app" a notification is tracked/matched/displayed under. Plain
// app_name almost always is it — but a Chromium browser running a site as
// its own window (`--app=<url>`, which is how the installed-webapp launcher
// opens things like WhatsApp) still reports the browser's own app_name
// ("Brave"/"Brave Origin") over D-Bus, making every such site indistinguishable
// from a regular tab. Chromium is expected to set the freedesktop
// `desktop-entry` hint to the launching site's own identity in that mode,
// which Quickshell exposes as notification.desktopEntry — distinct from
// appName. When present and not just a restatement of the generic app name,
// prefer it.
//
// Verified structurally (a raw D-Bus call with both fields set threads
// through end to end); NOT verified against a real Brave/Chromium webapp
// notification, since that can only be confirmed by the user triggering one
// on their machine — what Brave actually populates here in practice may
// need a follow-up tweak once that's known.
function effectiveAppName(appName, desktopEntry) {
  var app = String(appName || "").trim()
  var entry = String(desktopEntry || "").trim()
  if (!entry) return app
  if (!app) return entry
  // A desktop-entry that's just the app name again (case aside) or a
  // substring/superset of it isn't distinguishing anything — most
  // non-webapp Chromium tabs, and any sender that simply echoes its own
  // identity into both fields, fall here and should keep using appName.
  if (entry.toLowerCase() === app.toLowerCase()) return app
  return entry
}

function snapshotOf(notification, timestamp) {
  var n = notification || {}
  var id = n.id || 0
  var expireTimeout = Number(n.expireTimeout || 0)
  if (!isFinite(expireTimeout) || expireTimeout < 0) expireTimeout = 0
  return {
    id: id,
    originalId: id,
    app: effectiveAppName(n.appName, n.desktopEntry),
    appIcon: n.appIcon || "",
    summary: String(n.summary || ""),
    body: n.body || "",
    image: n.image || "",
    glyph: glyphFromHints(n.hints),
    execArgv: execArgvFromHints(n.hints),
    urgency: n.urgency,
    expireTimeout: expireTimeout,
    timestamp: timestamp === undefined ? Date.now() : timestamp
  }
}

// Everything the popup card draws, and therefore everything an in-place
// update has to write through to the row and its file.
var POPUP_ROLES = ["app", "appIcon", "summary", "body", "image", "glyph", "execArgv", "urgency", "expireTimeout"]

function popupRoles() {
  return POPUP_ROLES
}

// Whether a refresh has anything to write. Each property a client updates
// emits its own signal, and the catch-up refresh after a row is inserted
// usually finds the object exactly as it was snapshotted — without this,
// one update would rewrite the file several times over.
function popupRowChanged(row, updated) {
  var current = row || {}
  var next = updated || {}
  for (var i = 0; i < POPUP_ROLES.length; i++) {
    var role = POPUP_ROLES[i]
    if (current[role] !== next[role]) return true
  }
  return false
}

// A client updating a notification through replaces_id keeps the identity of
// the popup it took over: the file name is the timestamp and id the popup was
// first persisted under, and the restore, replace and archive paths all key
// off that name. Only what the card draws comes from the updated object.
function replacementSnapshot(notification, originalId, timestamp) {
  var updated = snapshotOf(notification, timestamp)
  updated.id = originalId
  updated.originalId = originalId
  return updated
}

function historyEntry(value, normalUrgency) {
  var e = value || {}
  return {
    id: e.id || 0,
    originalId: e.originalId || e.id || 0,
    app: e.app || "",
    appIcon: e.appIcon || "",
    summary: e.summary || "",
    body: e.body || "",
    image: e.image || "",
    glyph: e.glyph || "",
    execArgv: e.execArgv || "",
    urgency: typeof e.urgency === "number" ? e.urgency : normalUrgency,
    expireTimeout: 0,
    timestamp: e.timestamp || 0,
    // Present on every row from here, even a history-only one that never
    // shows as a toast — popupModel's Repeater delegate declares this
    // `required`, and a required property needs the model role to exist on
    // every row or the delegate fails to instantiate, not just the ones
    // that came through popupEntry.
    important: !!e.important,
    // True only for a row that arrived via writeSilenced — muted by a
    // profile, dndAll, global DND, or an unmuted first-time sender under a
    // block. Absent (falsy) means it was actually shown as a toast and
    // later expired or was dismissed normally.
    silenced: !!e.silenced
  }
}

// notifications.json holds nothing but the last-set DND preference now that
// history is a directory of files. Older versions kept `pending`/`past`
// (and, older still, `entries`) arrays in there; their presence is reported
// so the service can rewrite the file without the dead payload.
function parseSettings(raw) {
  var text = String(raw || "").trim()
  if (!text) return { error: false, dnd: null, legacy: false, profiles: null, activeProfile: null, seenApps: null, importantApps: null }

  try {
    var parsed = JSON.parse(text)
    return {
      error: false,
      dnd: parsed && typeof parsed.dnd === "boolean" ? parsed.dnd : null,
      legacy: !!(parsed && (parsed.pending || parsed.past || parsed.entries)),
      profiles: parsed && Array.isArray(parsed.profiles) ? sanitizeProfiles(parsed.profiles) : null,
      activeProfile: parsed && typeof parsed.activeProfile === "string" ? parsed.activeProfile : null,
      seenApps: parsed && Array.isArray(parsed.seenApps) ? sanitizeSeenApps(parsed.seenApps) : null,
      importantApps: parsed && Array.isArray(parsed.importantApps) ? sanitizeAppNames(parsed.importantApps) : null
    }
  } catch (e) {
    return { error: true, errorMessage: String(e), dnd: null, legacy: false, profiles: null, activeProfile: null, seenApps: null, importantApps: null }
  }
}

// seenApps moved from a flat name array to {name, lastSeen} objects so
// entries can age out after 30 days — a settings file from before that
// change carries the old shape, and gets each name stamped with "now" so it
// isn't pruned immediately on the first load after upgrading. `manual` is a
// later addition (an app added from the installed-apps picker, before it
// has ever actually sent anything) and defaults to false for both the old
// string shape and any object shape written before it existed.
function sanitizeSeenApps(list) {
  var out = []
  var seen = {}
  var now = Date.now()
  for (var i = 0; i < (list || []).length; i++) {
    var raw = list[i]
    var name, lastSeen, manual
    if (typeof raw === "string") {
      name = raw.trim()
      lastSeen = now
      manual = false
    } else if (raw && typeof raw === "object") {
      name = String(raw.name || "").trim()
      lastSeen = Number(raw.lastSeen)
      if (!isFinite(lastSeen) || lastSeen <= 0) lastSeen = now
      manual = !!raw.manual
    } else {
      continue
    }
    if (!name || seen[name]) continue
    seen[name] = true
    out.push({ name: name, lastSeen: lastSeen, manual: manual })
  }
  return out
}

// ---------------------------------------------------- notification profiles
//
// A profile is a named set of muting rules the user switches between: Work
// silences the games, Game silences the chat apps. Rules match on a
// notification's app_name, which is the only sender identity the freedesktop
// spec guarantees — hence seenApps, so the config panel offers names that
// have actually arrived rather than asking the user to guess spellings.

// The set every install starts with. Normal is deliberately empty: it is the
// "no rules" profile, and having it present means switching away from a
// muting profile is one click rather than a rule-by-rule undo.
function defaultProfiles() {
  return [
    { name: "Normal", icon: "󰶚", muteApps: [], dndAll: false, allowUnknownApps: true, importantOverrideOn: [], importantOverrideOff: [] },
    { name: "Work", icon: "󰂱", muteApps: [], dndAll: false, allowUnknownApps: true, importantOverrideOn: [], importantOverrideOff: [] },
    { name: "Game", icon: "󰖃", muteApps: [], dndAll: false, allowUnknownApps: true, importantOverrideOn: [], importantOverrideOff: [] }
  ]
}

function sanitizeAppNames(list) {
  var out = []
  var seen = {}
  for (var i = 0; i < (list || []).length; i++) {
    var name = String(list[i] || "").trim()
    if (!name || seen[name]) continue
    seen[name] = true
    out.push(name)
  }
  return out
}

// Drops anything malformed rather than throwing: a hand-edited settings file
// with one bad profile should cost that profile, not every notification.
function sanitizeProfiles(list) {
  var out = []
  var seen = {}
  for (var i = 0; i < (list || []).length; i++) {
    var raw = list[i] || {}
    var name = String(raw.name || "").trim()
    if (!name || seen[name]) continue
    seen[name] = true
    // An app in both override lists (a hand-edited settings file, or a
    // client sending stale data) resolves "on" — importantOverrideOff is
    // filtered clear of anything importantOverrideOn already claims, so the
    // two never actually disagree once sanitized.
    var overrideOn = sanitizeAppNames(raw.importantOverrideOn)
    var overrideOnSet = {}
    for (var j = 0; j < overrideOn.length; j++) overrideOnSet[overrideOn[j].toLowerCase()] = true
    var overrideOff = sanitizeAppNames(raw.importantOverrideOff).filter(function(a) {
      return !overrideOnSet[a.toLowerCase()]
    })

    out.push({
      name: name,
      icon: String(raw.icon || ""),
      muteApps: sanitizeAppNames(raw.muteApps),
      dndAll: !!raw.dndAll,
      // Plain per-profile boolean, defaulting true (allow) — a profile that
      // has never touched this, or a legacy/malformed value, behaves as
      // "allow" rather than silently starting to block first-time senders.
      allowUnknownApps: typeof raw.allowUnknownApps === "boolean" ? raw.allowUnknownApps : true,
      // Per-app override of the global "keep this app's toasts on screen"
      // setting, same inherit/on/off shape as allowUnknownApps but per-app
      // rather than a single switch — an app not in either list inherits
      // whatever the global importantApps list says.
      importantOverrideOn: overrideOn,
      importantOverrideOff: overrideOff
    })
  }
  return out
}

function findSeenApp(seenApps, name) {
  var needle = String(name || "")
  for (var i = 0; i < (seenApps || []).length; i++) {
    if (seenApps[i] && seenApps[i].name === needle) return seenApps[i]
  }
  return null
}

// True when two profile lists show the same set of names with the same
// icons, in any order — the only two fields the Super+Space menu actually
// renders (see Service.qml's syncProfilesMenu). Order and every other field
// (muteApps, dndAll, allowUnknownApps) are irrelevant to what the menu
// looks like, so a pure rule edit compares equal here and skips a rewrite.
function sameProfileIdentities(a, b) {
  var listA = (a || []).map(function(p) { return String(p.name || "") + "|" + String(p.icon || "") }).sort()
  var listB = (b || []).map(function(p) { return String(p.name || "") + "|" + String(p.icon || "") }).sort()
  if (listA.length !== listB.length) return false
  for (var i = 0; i < listA.length; i++) {
    if (listA[i] !== listB[i]) return false
  }
  return true
}

// ---------------------------------------------------- Super+Space menu sync
//
// Builds the JSONC lines for a "Profiles" submenu (one row per profile, plus
// the submenu header row) and splices them into a marked region of the
// user's menu extensions file — see Service.qml's syncProfilesMenu for why
// this has to be generated rather than static.

// Escapes a value for both JSON-string and embedded-shell-single-quote
// contexts at once: the JSON string escaping (quotes, backslashes) happens
// first via JSON.stringify, then the result — still containing the raw
// profile name — is safe to drop into the `checked` shell expression's own
// single-quoted string because single quotes inside it are neutralized by
// closing/reopening the quote ('\'') the standard POSIX way. A name holding
// a literal `'` is the only character that needs that; JSON.stringify
// already made `"`, `\`, and control characters safe for the JSON side.
function shellSingleQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

function profilesMenuBlock(profiles, markerStart, markerEnd, idFor) {
  var used = {}
  var lines = [markerStart]
  lines.push('  "profiles": {"icon":"󰂚","label":"Profiles","aliases":["profile","notifications"]},')
  for (var i = 0; i < (profiles || []).length; i++) {
    var p = profiles[i]
    if (!p || !p.name) continue
    var id = idFor(p.name, used)
    var icon = p.icon || "󰂚"
    var nameJson = JSON.stringify(p.name)
    var iconJson = JSON.stringify(icon)
    var idJson = JSON.stringify("profiles." + id)
    var setProfileCmd = "omarchy-shell notifications setProfile " + shellSingleQuote(p.name)
    var checkedExpr = "[ \"$(omarchy-shell notifications activeProfile)\" = " + shellSingleQuote(p.name) + " ]"
    lines.push("  " + idJson + ": {\"icon\":" + iconJson + ",\"label\":" + nameJson +
      ",\"action\":" + JSON.stringify(setProfileCmd) + ",\"checked\":" + JSON.stringify(checkedExpr) + "},")
  }
  lines.push(markerEnd)
  return lines.join("\n")
}

// Replaces the region between markerStart/markerEnd (inclusive) with block,
// or inserts block just before the file's final "}" when the markers aren't
// present yet. Returns null when the existing content doesn't look like a
// single JSONC object (no trailing "}" found) — callers should leave the
// file alone rather than guess at a malformed one.
function spliceMenuBlock(existingRaw, block, markerStart, markerEnd) {
  var text = String(existingRaw || "").replace(/\r\n/g, "\n")
  if (!text.trim()) {
    return "{\n" + block + "\n}\n"
  }

  var startIdx = text.indexOf(markerStart)
  var endIdx = startIdx >= 0 ? text.indexOf(markerEnd, startIdx) : -1
  if (startIdx >= 0 && endIdx >= 0) {
    var before = text.slice(0, startIdx)
    var after = text.slice(endIdx + markerEnd.length)
    // block already ends with markerEnd and no trailing newline of its own —
    // exactly one newline belongs between it and whatever follows (the
    // closing "}" on a fresh file, or blank-line padding on a repeated
    // sync). `after` normally already starts with that newline (this is
    // itself the output of a previous sync, or hand-typed the same way);
    // only synthesize one when it's missing, never strip one that's there.
    if (after.charAt(0) !== "\n") after = "\n" + after
    return before + block + after
  }

  // No existing markers: insert as new top-level entries just before the
  // last "}" in the file, matching how a person would hand-add entries.
  var lastBrace = text.lastIndexOf("}")
  if (lastBrace < 0) return null
  var head = text.slice(0, lastBrace)
  var tail = text.slice(lastBrace)
  // The object needs a trailing comma before new keys if the last real line
  // before the closing brace doesn't already end with one (a file with no
  // trailing comma on its last entry, unlike this plugin's own writes).
  var trimmedHead = head.replace(/\s+$/, "")
  var needsComma = trimmedHead.length > 0 && trimmedHead.charAt(trimmedHead.length - 1) !== "," &&
    trimmedHead.charAt(trimmedHead.length - 1) !== "{"
  return trimmedHead + (needsComma ? "," : "") + "\n" + block + "\n" + tail
}

function findProfile(profiles, name) {
  var needle = String(name || "")
  for (var i = 0; i < (profiles || []).length; i++) {
    if (profiles[i] && profiles[i].name === needle) return profiles[i]
  }
  return null
}

// Which profile the next notification is judged against. An activeProfile
// naming a profile that has since been deleted falls back to the first one
// rather than to "no rules at all", so a rename cannot silently unmute
// everything.
function resolveActiveProfile(profiles, activeName) {
  var hit = findProfile(profiles, activeName)
  if (hit) return hit
  return (profiles && profiles.length) ? profiles[0] : null
}

// True when the active profile says this notification should not raise a
// toast. Case-insensitive on app_name: senders are inconsistent about
// capitalising their own brand ("Slack" vs "slack") and a rule the user set
// from one spelling should hold for the other.
function profileSilences(profile, appName) {
  if (!profile) return false
  if (profile.dndAll) return true
  var needle = String(appName || "").trim().toLowerCase()
  if (!needle) return false
  var muted = profile.muteApps || []
  for (var i = 0; i < muted.length; i++) {
    if (String(muted[i] || "").trim().toLowerCase() === needle) return true
  }
  return false
}

function listHasApp(list, needle) {
  for (var i = 0; i < (list || []).length; i++) {
    if (String(list[i] || "").trim().toLowerCase() === needle) return true
  }
  return false
}

// Whether an app's toast should stay on screen instead of auto-dismissing.
// A profile's own override list wins when the app appears in either one
// (importantOverrideOn/Off are already mutually exclusive post-sanitize);
// with no override, the global importantApps list decides. Evaluated once
// per notification at the moment it arrives (see Service.qml's
// handleNotification) and stored on the row, not re-resolved on every
// render — a toast restored after a shell restart, or one still on screen
// after the active profile changed, keeps the answer that was true when it
// was received rather than one that drifts under it.
function isAppImportant(profile, appName, globalImportantApps) {
  var needle = String(appName || "").trim().toLowerCase()
  if (!needle) return false
  if (profile) {
    if (listHasApp(profile.importantOverrideOn, needle)) return true
    if (listHasApp(profile.importantOverrideOff, needle)) return false
  }
  return listHasApp(globalImportantApps, needle)
}

// The next profile in the list, wrapping. Used by the cycleProfile IPC so a
// keybind can rotate through them without the panel open.
function nextProfileName(profiles, activeName) {
  if (!profiles || !profiles.length) return ""
  for (var i = 0; i < profiles.length; i++) {
    if (profiles[i] && profiles[i].name === String(activeName || "")) {
      return profiles[(i + 1) % profiles.length].name
    }
  }
  return profiles[0].name
}

// ---------------------------------------------------- popup persistence
//
// Each on-screen popup is mirrored to its own file under
// ~/.local/state/omarchy/notifications/ so toasts survive shell restarts
// (e.g. the restart `omarchy-update` performs). The file exists exactly as
// long as the popup is on screen: it is written when the toast appears and
// moved into the history/ subdirectory when the toast expires, is dismissed,
// or its action is invoked. History is those moved files, newest last-10.

function popupEntry(value, normalUrgency) {
  var entry = historyEntry(value, normalUrgency)
  var expire = Number((value || {}).expireTimeout || 0)
  if (!isFinite(expire) || expire < 0) expire = 0
  entry.expireTimeout = expire
  // Absolute expiry deadline, set only when a restore resets a surviving
  // popup's display lifetime. Kept out of the entry entirely when unset so
  // restored rows match the roles of freshly received ones.
  var deadline = Number((value || {}).deadline || 0)
  if (isFinite(deadline) && deadline > 0) entry.deadline = deadline
  // Resolved once when the notification arrived (see Service.qml's
  // handleNotification / isAppImportant) and carried as data from there —
  // a history row has no use for it (importance only ever affects whether a
  // toast stays on screen), so it's added here rather than in historyEntry.
  entry.important = !!(value || {}).important
  return entry
}

function popupFileName(entry) {
  return imageStem(entry) + ".json"
}

// ---------------------------------------------------- persisted images
//
// A notification's images only exist while it is live: Chromium-family
// senders (all Omarchy web apps) delete their scoped /tmp files on close,
// and image-data hints surface as in-process image:// URLs that die with
// the server object. Persisted entries therefore reference their own
// copies, named by the entry's file stem so cleanup can find them from
// the JSON file name alone.

var PERSISTED_IMAGE_ROLES = ["appIcon", "image"]

function imageStem(entry) {
  var e = entry || {}
  return String(e.timestamp || 0) + "-" + String(e.originalId || 0)
}

// The filesystem path behind a file-backed image value, or "" for anything
// a copy can't capture: themed icon names, in-process image:// URLs, empty.
function localImageFile(value) {
  var s = String(value || "")
  if (s.indexOf("file://") === 0) {
    s = s.slice(7)
    try { s = decodeURIComponent(s) } catch (e) {}
  }
  return s.charAt(0) === "/" ? s : ""
}

// The entry as it should hit the disk, plus the copies that make it true.
// File-backed images redirect to their copy under imagesDir; dead image://
// URLs drop to "" (the card falls back to the app icon). Already-redirected
// values map onto themselves and produce no copy, keeping restores no-ops.
function persistablePopup(entry, imagesDir) {
  var e = entry || {}
  var out = {}
  for (var key in e) out[key] = e[key]
  var copies = []
  for (var i = 0; i < PERSISTED_IMAGE_ROLES.length; i++) {
    var role = PERSISTED_IMAGE_ROLES[i]
    var value = String(out[role] || "")
    if (!value) continue
    var source = localImageFile(value)
    if (source) {
      var copy = String(imagesDir || "") + imageStem(e) + "-" + role
      if (source !== copy) copies.push({ from: source, to: copy })
      out[role] = "file://" + copy
    } else if (value.indexOf("image://") === 0) {
      out[role] = ""
    }
  }
  return { entry: out, copies: copies }
}

function serializePopup(entry, normalUrgency) {
  // Compact (single-line) on purpose: restore cats every file together and
  // parses line by line, which only works when each file is one line.
  return JSON.stringify(popupEntry(entry, normalUrgency))
}

// Parse the concatenation of every persisted popup file into entries,
// newest-first. Deliberately NO dedupe by originalId: ids restart from 1
// with every server process, so two files sharing an id are usually
// different generations — dropping the older one would silently discard a
// restored critical alert the moment a fresh notification reuses its id.
// The one case that leaves a genuine duplicate (a crash between a
// replacement's write and the replaced file's delete) merely re-shows a
// superseded toast, which expires or is dismissed and cleans itself up.
function parsePopupFiles(raw, normalUrgency) {
  var lines = String(raw || "").split("\n")
  var entries = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var value = JSON.parse(line)
      if (value && typeof value === "object") entries.push(popupEntry(value, normalUrgency))
    } catch (e) {
      // A torn write from a crash mid-save — skip the line, keep the rest.
    }
  }
  entries.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return entries
}

// A persisted popup whose lifetime already ran out would have expired on
// screen had the shell kept running, so it is not restored. duration 0 means
// the popup never expires (critical urgency) and always survives restarts.
// A restore-reset deadline outranks the original timestamp: without it, a
// second restart would judge a re-shown toast by a clock that no longer
// governs its display and drop it while it is still on screen.
function popupExpired(entry, duration, now) {
  var deadline = Number((entry || {}).deadline || 0)
  if (isFinite(deadline) && deadline > 0) return Number(now) >= deadline
  var lifetime = Number(duration || 0)
  if (!isFinite(lifetime) || lifetime <= 0) return false
  return (Number(now) - Number((entry || {}).timestamp || 0)) >= lifetime
}

function popupPlacement(barPosition, barClearance, gapsOut) {
  var position = String(barPosition || "top")
  var clearance = Number(barClearance)
  var gap = Number(gapsOut)
  if (!isFinite(clearance)) clearance = 0
  if (!isFinite(gap)) gap = 0

  return {
    anchors: { top: true, bottom: false, left: false, right: true },
    margins: {
      top: position === "top" ? clearance : gap,
      bottom: gap,
      left: gap,
      right: position === "right" ? clearance : gap
    }
  }
}

// The archived files are the history. They are read back exactly like the
// live popup files, then normalized into history rows: replaying a toast
// must not inherit the original's expire timeout or restore deadline, so it
// gets the standard on-screen lifetime for its urgency instead.
//
// liveRows are the toasts still on screen when the replay was asked for.
// They belong in it — they're the newest notifications there are — but the
// directory read races their archival, so they're carried across by hand and
// keyed by file name (timestamp + id) to drop the copy the read already saw.
function historyRows(raw, liveRows, normalUrgency, limit) {
  var max = limit === undefined || limit === null ? 10 : Number(limit)
  if (isNaN(max)) max = 10
  max = Math.max(0, max)

  var out = []
  var seen = {}
  function collect(rows) {
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i]
      if (!entry) continue
      var key = popupFileName(entry)
      if (seen[key]) continue
      seen[key] = true
      out.push(historyEntry(entry, normalUrgency))
    }
  }

  collect(Array.isArray(liveRows) ? liveRows : [])
  collect(parsePopupFiles(raw, normalUrgency))
  out.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return out.slice(0, max)
}

if (typeof module !== "undefined") {
  module.exports = {
    isChromiumDerived: isChromiumDerived,
    sanitizeBody: sanitizeBody,
    bodyLinkUrl: bodyLinkUrl,
    styledBody: styledBody,
    summaryStartsWithGlyph: summaryStartsWithGlyph,
    shouldBypassDnd: shouldBypassDnd,
    isEphemeralApp: isEphemeralApp,
    stringHint: stringHint,
    glyphFromHints: glyphFromHints,
    execArgvFromHints: execArgvFromHints,
    parseExecArgv: parseExecArgv,
    shouldRenderCompactGlyph: shouldRenderCompactGlyph,
    snapshotOf: snapshotOf,
    popupRoles: popupRoles,
    popupRowChanged: popupRowChanged,
    replacementSnapshot: replacementSnapshot,
    historyEntry: historyEntry,
    parseSettings: parseSettings,
    defaultProfiles: defaultProfiles,
    sanitizeProfiles: sanitizeProfiles,
    sanitizeAppNames: sanitizeAppNames,
    sanitizeSeenApps: sanitizeSeenApps,
    findSeenApp: findSeenApp,
    sameProfileIdentities: sameProfileIdentities,
    profilesMenuBlock: profilesMenuBlock,
    spliceMenuBlock: spliceMenuBlock,
    findProfile: findProfile,
    resolveActiveProfile: resolveActiveProfile,
    profileSilences: profileSilences,
    isAppImportant: isAppImportant,
    nextProfileName: nextProfileName,
    historyRows: historyRows,
    popupEntry: popupEntry,
    popupFileName: popupFileName,
    imageStem: imageStem,
    localImageFile: localImageFile,
    persistablePopup: persistablePopup,
    serializePopup: serializePopup,
    parsePopupFiles: parsePopupFiles,
    popupExpired: popupExpired,
    popupPlacement: popupPlacement
  }
}
