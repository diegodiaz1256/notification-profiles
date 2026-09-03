// Notification service for the omarchy shell.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import qs.Commons

import "components"
import "NotificationLogic.js" as NotificationLogic

Item {
  id: service

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  // History + DND live under XDG_STATE_HOME: they're persistent user state
  // (the notifications received, the last-set DND preference), not
  // regeneratable cache that a `rm -rf ~/.cache` should wipe.
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string settingsPath: stateDir + "notifications.json"
  // One file per on-screen popup, so live toasts survive shell restarts.
  // A file exists exactly as long as its popup is showing: written when the
  // toast appears, moved into historyDir when it expires, is dismissed, or is
  // acted upon.
  readonly property string popupStateDir: stateDir + "notifications/"
  // The notifications that already left the screen, one file each, trimmed to
  // the newest historyLimit. This directory IS the history: `showHistory`
  // replays exactly what has been moved in here.
  readonly property string historyDir: popupStateDir + "history/"
  // Copies of the avatars/images persisted entries reference — the sender's
  // originals don't outlive the notification (see persistablePopup). Each
  // copy lives and dies with the JSON file whose stem it carries.
  readonly property string imagesDir: popupStateDir + "images/"
  // Corner radius is shared with the menu and shell panels.
  // It mirrors Hyprland's current decoration:rounding value.
  readonly property int cornerRadius: Style.cornerRadius
  // Toasts are fixed to the top-right corner. They only clear the omarchy bar
  // when the bar occupies the top or right edge, so left/bottom bars do not
  // pull notification popups away from the expected top-right location.
  // Falls back to the bar's default size (26 horizontal / 28 vertical) when
  // shell.bar isn't reachable so the popup never lands on top of the bar.
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property bool barVertical: barPosition === "left" || barPosition === "right"
  readonly property int defaultBarSize: barVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property int liveBarSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize) : defaultBarSize
  readonly property int barClearance: liveBarSize + Style.gapsOut

  // Live Notification objects by originalId, kept OUT of the ListModels: a
  // QObject stored in a model role becomes a dangling C++ pointer when the
  // server destroys the notification (sender close, DND untrack, dismiss),
  // and the next read of that role segfaults in QQmlListModel::data. A JS
  // map only holds a wrapper, which degrades to a catchable error instead.
  property var liveRefs: ({})

  // PersistentProperties handles in-process QML reloads. The on-disk
  // notifications.json file is the cross-restart backstop — its `dnd` key
  // is hydrated into persisted.doNotDisturb on startup and written back via
  // a debounced save timer.
  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-notifications"
    property bool doNotDisturb: false
    onDoNotDisturbChanged: {
      // Suppress the write that load-time hydration would otherwise trigger.
      if (service._hydrating) return
      service.scheduleSettingsSave()
    }
  }

  // Guards onDoNotDisturbChanged while we're hydrating from disk so the
  // hydration assignment doesn't immediately schedule a write-back.
  property bool _hydrating: false

  readonly property alias doNotDisturb: persisted.doNotDisturb

  function setDoNotDisturb(value) {
    persisted.doNotDisturb = !!value
  }

  // ---------------------------------------------------- notification profiles
  //
  // Named rule sets ("Work", "Game") the user switches between, each muting a
  // list of app_names. Kept alongside DND rather than folded into it: DND is
  // the momentary "silence everything" switch, a profile is the standing
  // answer to "what do I want to hear while doing this".
  property var profiles: NotificationLogic.defaultProfiles()
  property string activeProfileName: "Normal"
  // Every app_name that has sent a notification, so the config panel can list
  // real senders instead of asking the user to spell them from memory. Each
  // entry carries when it was last seen, so an app that stops notifying
  // ages out (see seenAppsMaxAgeMs) instead of accumulating forever — a
  // machine that runs test scripts or one-off senders would otherwise grow
  // this list without bound between manual prunes.
  property var seenApps: []
  readonly property var seenAppNames: seenApps.map(function(e) { return e.name })

  // Apps whose toast stays on screen instead of auto-dismissing, by
  // default. A profile can override this per-app in either direction (see
  // NotificationLogic.isAppImportant) — this is only the fallback for an
  // app with no override in the active profile.
  property var importantApps: []

  function setImportantApp(appName, important) {
    var app = String(appName || "").trim()
    if (!app) return
    var next = service.importantApps.filter(function(a) {
      return String(a).trim().toLowerCase() !== app.toLowerCase()
    })
    if (important) next.push(app)
    service.importantApps = next
    service.scheduleSettingsSave()
  }

  readonly property var activeProfile: NotificationLogic.resolveActiveProfile(profiles, activeProfileName)

  function setActiveProfile(name) {
    var hit = NotificationLogic.findProfile(service.profiles, name)
    if (!hit) return false
    service.activeProfileName = hit.name
    service.scheduleSettingsSave()
    return true
  }

  function cycleProfile() {
    var next = NotificationLogic.nextProfileName(service.profiles, service.activeProfileName)
    if (next) service.setActiveProfile(next)
    return service.activeProfileName
  }

  // The one profile that can't be deleted, only edited — a machine with
  // profiles always needs at least one, and picking a fixed name for it
  // (rather than e.g. "whichever is first") means the guard survives
  // reordering and doesn't depend on list position.
  readonly property string defaultProfileName: "Normal"

  // Replaces the whole profile list in one write — the config panel edits a
  // copy and hands the result back, so partial-update races between the panel
  // and the daemon can't leave a half-applied rule set behind.
  function setProfiles(list) {
    var incoming = NotificationLogic.sanitizeProfiles(list)
    // The panel is where deletion is invoked, but the daemon is authoritative
    // per this file's role — a list missing the protected profile (deleted
    // client-side despite the panel's own guard, or sent by some other
    // caller entirely) gets it re-added rather than silently losing it.
    if (!NotificationLogic.findProfile(incoming, service.defaultProfileName)) {
      var restored = NotificationLogic.findProfile(service.profiles, service.defaultProfileName)
      incoming = incoming.concat([restored || {
        name: service.defaultProfileName, icon: "󰶚", muteApps: [], dndAll: false, allowUnknownApps: true,
        importantOverrideOn: [], importantOverrideOff: []
      }])
    }

    // Menu resync is keyed on what the menu actually shows: profile names
    // and icons. A rule-only edit (muteApps/dndAll/allowUnknownApps) changes
    // nothing the menu displays, so comparing sorted "name|icon" pairs before
    // and after is enough to decide whether a rewrite is warranted — this is
    // computed before service.profiles is reassigned, against the state that
    // was live until now.
    var menuRelevantChange = !NotificationLogic.sameProfileIdentities(service.profiles, incoming)

    service.profiles = incoming
    if (!NotificationLogic.findProfile(service.profiles, service.activeProfileName)) {
      service.activeProfileName = service.profiles.length ? service.profiles[0].name : ""
    }
    service.scheduleSettingsSave()
    if (menuRelevantChange) service.syncProfilesMenu()
  }

  // ---------------------------------------------------- Super+Space menu sync
  //
  // Keeps a "Profiles" submenu in the Omarchy launcher in step with the
  // current profile list. Profile names are user data, so the menu can't be
  // a static file — this rewrites one marked region of the user's own
  // ~/.config/omarchy/extensions/omarchy-menu.jsonc, leaving everything else
  // in that file untouched. The menu watches that file (watchChanges: true)
  // and reloads on change, so this takes effect without a shell restart.
  //
  // Called only when setProfiles sees the set of names or icons actually
  // change — a pure rule edit (mute list, dndAll, allowUnknownApps) changes
  // nothing the menu renders and would just be a needless rewrite.
  readonly property string menuExtensionsPath: home + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  readonly property string menuMarkerStart: "  // >>> zeroge.notification-profiles: managed, do not edit <<<"
  readonly property string menuMarkerEnd: "  // <<< zeroge.notification-profiles <<<"

  // A profile name becomes a menu id segment: lowercased, non-alphanumeric
  // collapsed to "-", trimmed. Two names that collide after that (e.g. "Work!"
  // and "Work?") get a numeric suffix so every row still gets its own id.
  function menuIdFor(name, used) {
    var base = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    if (!base) base = "profile"
    var id = base
    var n = 2
    while (used[id]) { id = base + "-" + n; n++ }
    used[id] = true
    return id
  }

  function syncProfilesMenu() {
    readMenuFileProc.running = true
  }

  Process {
    id: readMenuFileProc
    command: ["bash", "-c", "cat \"$1\" 2>/dev/null || true", "--", service.menuExtensionsPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.writeProfilesMenuBlock(this.text)
    }
  }

  function writeProfilesMenuBlock(existingRaw) {
    var block = NotificationLogic.profilesMenuBlock(
      service.profiles, service.menuMarkerStart, service.menuMarkerEnd, service.menuIdFor)
    var merged = NotificationLogic.spliceMenuBlock(
      existingRaw, block, service.menuMarkerStart, service.menuMarkerEnd)
    if (merged === null) return // malformed existing file — leave it alone rather than guess

    // Atomic write: a temp file in the same directory, then rename, so a
    // crash mid-write can't leave the user's menu file half-written.
    writeMenuFileProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname -- \"$1\")\" || exit 0\n" +
      "printf '%s' \"$2\" > \"$1.tmp\" && mv -f \"$1.tmp\" \"$1\"",
      "--", service.menuExtensionsPath, merged]
    writeMenuFileProc.running = true
  }

  Process { id: writeMenuFileProc; running: false }

  function setAppMuted(profileName, appName, muted) {
    var app = String(appName || "").trim()
    if (!app) return false
    // QML only notices a property change when the reference changes, so the
    // list is rebuilt rather than mutated in place.
    var next = []
    var found = false
    for (var i = 0; i < service.profiles.length; i++) {
      var p = service.profiles[i]
      if (p.name !== String(profileName || "")) { next.push(p); continue }
      found = true
      var apps = (p.muteApps || []).filter(function(a) {
        return String(a).trim().toLowerCase() !== app.toLowerCase()
      })
      if (muted) apps.push(app)
      next.push({
        name: p.name, icon: p.icon, muteApps: apps, dndAll: p.dndAll, allowUnknownApps: p.allowUnknownApps,
        importantOverrideOn: p.importantOverrideOn, importantOverrideOff: p.importantOverrideOff
      })
    }
    if (!found) return false
    service.profiles = next
    service.scheduleSettingsSave()
    return true
  }

  // Plain per-profile boolean — true allows a first-time sender through
  // normally, false silences it (see the wasUnknownApp handling in
  // handleNotification). No global fallback: every profile already decides
  // this for itself, so a separate global default only ever mattered for a
  // profile left on "inherit", which wasn't worth the extra state.
  function setProfileAllowUnknownApps(profileName, value) {
    var next = []
    var found = false
    for (var i = 0; i < service.profiles.length; i++) {
      var p = service.profiles[i]
      if (p.name !== String(profileName || "")) { next.push(p); continue }
      found = true
      next.push({
        name: p.name, icon: p.icon, muteApps: p.muteApps, dndAll: p.dndAll, allowUnknownApps: !!value,
        importantOverrideOn: p.importantOverrideOn, importantOverrideOff: p.importantOverrideOff
      })
    }
    if (!found) return false
    service.profiles = next
    service.scheduleSettingsSave()
    return true
  }

  // value: true forces this app important in this profile regardless of the
  // global list, false forces it not-important, null clears the override
  // and goes back to inheriting the global. Same rebuild-not-mutate shape as
  // setAppMuted/setProfileAllowUnknownApps.
  function setProfileImportantOverride(profileName, appName, value) {
    var app = String(appName || "").trim()
    if (!app) return false
    var next = []
    var found = false
    for (var i = 0; i < service.profiles.length; i++) {
      var p = service.profiles[i]
      if (p.name !== String(profileName || "")) { next.push(p); continue }
      found = true
      var onList = (p.importantOverrideOn || []).filter(function(a) {
        return String(a).trim().toLowerCase() !== app.toLowerCase()
      })
      var offList = (p.importantOverrideOff || []).filter(function(a) {
        return String(a).trim().toLowerCase() !== app.toLowerCase()
      })
      if (value === true) onList.push(app)
      else if (value === false) offList.push(app)
      next.push({
        name: p.name, icon: p.icon, muteApps: p.muteApps, dndAll: p.dndAll, allowUnknownApps: p.allowUnknownApps,
        importantOverrideOn: onList, importantOverrideOff: offList
      })
    }
    if (!found) return false
    service.profiles = next
    service.scheduleSettingsSave()
    return true
  }

  // Records a sender, refreshing its lastSeen if already tracked. Capped so
  // a misbehaving app that randomises its app_name can't grow the settings
  // file unbounded — the oldest entry is dropped to make room, same as the
  // 30-day prune would eventually get it anyway.
  //
  // manual marks an entry added from the installed-apps picker rather than
  // an actual notification (see trackApp) — pruneSeenApps exempts it from
  // the age-based sweep, since a user pre-configuring a rule for an app they
  // expect to use soon shouldn't have it vanish before it ever fires once.
  // A real notification always clears the bit: once the app has genuinely
  // notified, it ages out on the normal schedule like everything else.
  readonly property int seenAppsLimit: 200
  readonly property int seenAppsMaxAgeMs: 30 * 24 * 60 * 60 * 1000
  function recordSeenApp(appName, manual) {
    var app = String(appName || "").trim()
    if (!app) return
    var now = Date.now()
    var next = service.seenApps.filter(function(e) { return e.name !== app })
    next.push({ name: app, lastSeen: now, manual: !!manual })
    next.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    if (next.length > service.seenAppsLimit) {
      // Manual entries are exempt from the age prune, but not from this
      // count cap — 200 tracked apps is already generous, and a manual
      // add competing on the same "oldest first" ordering as everything
      // else keeps this cap simple instead of needing its own carve-out.
      next.sort(function(a, b) { return a.lastSeen - b.lastSeen })
      next = next.slice(next.length - service.seenAppsLimit)
      next.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    }
    service.seenApps = next
    service.scheduleSettingsSave()
  }

  // Adds an app to the tracked list from the installed-apps picker, before
  // it has ever actually sent a notification — so its mute/important rules
  // can be set up ahead of time. A no-op if the app is already tracked
  // (manually or otherwise): the picker filters those out already, but the
  // daemon doesn't trust the panel not to double-submit.
  function trackApp(appName) {
    var app = String(appName || "").trim()
    if (!app) return
    if (NotificationLogic.findSeenApp(service.seenApps, app)) return
    service.recordSeenApp(app, true)
  }

  // Drops one name from the tracked list — test senders and one-off scripts
  // otherwise pile up here forever with nothing to prune them. The next
  // notification from that app re-adds it, same as it was seen the first
  // time; this only clears the stale entry, not a standing block.
  function forgetSeenApp(appName) {
    var app = String(appName || "").trim()
    if (!app) return
    service.seenApps = service.seenApps.filter(function(e) { return e.name !== app })
    service.scheduleSettingsSave()
  }

  // Ages out anything not seen in 30 days. Run at startup and periodically
  // (see pruneTimer) rather than only on the next notification, so a name
  // that genuinely stopped sending altogether still eventually clears.
  // manual entries are exempt — see recordSeenApp/trackApp.
  function pruneSeenApps() {
    var cutoff = Date.now() - service.seenAppsMaxAgeMs
    var next = service.seenApps.filter(function(e) { return e.manual || (e.lastSeen || 0) >= cutoff })
    if (next.length === service.seenApps.length) return
    service.seenApps = next
    service.scheduleSettingsSave()
  }

  Timer {
    // Once a day is plenty for a 30-day threshold — this isn't chasing
    // precision, just making sure prune isn't only-on-restart.
    interval: 24 * 60 * 60 * 1000
    running: true
    repeat: true
    onTriggered: service.pruneSeenApps()
  }

  // popupModel feeds the on-screen toast stack — the only model the service
  // keeps. Everything a toast leaves behind lives on disk under historyDir.
  //
  // Aliased as a property so consumers outside this Item's id scope can bind
  // to it. QML ids aren't visible to external consumers without the alias.
  property alias popupModel: popupModel
  ListModel { id: popupModel }

  // How many notifications the history directory keeps, and therefore how
  // many `showHistory` can replay.
  readonly property int historyLimit: 10

  readonly property int lowPopupDuration: 5000
  readonly property int normalPopupDuration: 8000
  readonly property int maxPopupDuration: 30000

  // important short-circuits to 0 (never auto-dismiss) ahead of the urgency
  // switch, same treatment Critical already gets — an important app's toast
  // stays up regardless of the urgency it happened to be sent at.
  function durationFor(urgency, expireTimeout, important) {
    if (important) return 0
    switch (urgency) {
    case NotificationUrgency.Critical:
      return 0
    case NotificationUrgency.Low:
      return Math.min(maxPopupDuration, Math.max(lowPopupDuration, requestedDuration(expireTimeout)))
    default:
      return Math.min(maxPopupDuration, Math.max(normalPopupDuration, requestedDuration(expireTimeout)))
    }
  }

  function requestedDuration(expireTimeout) {
    // FreeDesktop notification spec (and Quickshell) report expireTimeout in
    // milliseconds, so pass it through directly.
    var ms = Number(expireTimeout || 0)
    if (!isFinite(ms) || ms <= 0) return 0
    return Math.round(ms)
  }

  // DND bypass: only let through notifications we trust to be intentional
  // and rare.
  //   - omarchy-action: a user-action confirmation toast ("Theme changed",
  //     "Screenshot saved"). The user JUST did something — their feedback
  //     should show.
  //   - urgency=critical AND app_name=notify-send: bare-CLI emergency alerts.
  //     Trusted because it's almost always omarchy or system shell scripts —
  //     chat apps set app_name to their brand (Discord/Slack/Vesktop), which
  //     falls outside this rule.
  function shouldBypassDnd(notification) {
    return NotificationLogic.shouldBypassDnd(notification, NotificationUrgency.Critical)
  }

  function snapshotOf(notification) {
    return NotificationLogic.snapshotOf(notification, Date.now())
  }

  // A notification nobody looks back at:
  //   - the freedesktop `transient` hint is set ("popup only, don't store")
  //   - app_name is "notify-send" (the CLI default — means the sender
  //     didn't bother declaring an identity, so it's almost certainly
  //     ephemeral test/feedback noise)
  //   - app_name is "omarchy-action" (Omarchy's own user-action toasts —
  //     the user just triggered them)
  // Their toasts still land in history like any other once they've been on
  // screen; the distinction only decides whether a DND-silenced one is worth
  // recording at all.
  function isEphemeral(notification) {
    var transient = false
    try {
      transient = !!(notification.hints && notification.hints["transient"])
    } catch (e) { transient = false }
    return transient || NotificationLogic.isEphemeralApp(String(notification.appName || ""))
  }

  function handleNotification(notification) {
    // Without `tracked = true` the Notification object is destroyed as soon
    // as this signal handler returns, which would null out the `ref` we just
    // captured for the popup card.
    notification.tracked = true
    var snapshot = snapshotOf(notification)
    // Resolved once, now, against the profile active at arrival — carried
    // on the row from here rather than re-evaluated on every render, so a
    // toast that outlives a profile switch (or a shell restart) keeps
    // answering to the profile that was active when it actually arrived.
    // See NotificationLogic.isAppImportant.
    snapshot.important = NotificationLogic.isAppImportant(
      service.activeProfile, notification.appName, service.importantApps)
    liveRefs[snapshot.originalId] = notification
    // Guard the delete: a newer notification may have reused this originalId
    // (freedesktop replaces_id) and taken over the map slot.
    notification.closed.connect(function() {
      if (service.liveRefs[snapshot.originalId] === notification)
        delete service.liveRefs[snapshot.originalId]
    })

    // Checked before recordSeenApp — that call is what makes the app known,
    // so the check has to run against the state from before this very
    // notification, or an app could never be "unknown" by the time it's
    // asked about. Plain per-profile boolean — every profile can already set
    // its own Allow/Block, so a separate global default only mattered for a
    // profile left on "inherit", which wasn't worth the extra state.
    var effectiveAllowUnknown = service.activeProfile && typeof service.activeProfile.allowUnknownApps === "boolean"
      ? service.activeProfile.allowUnknownApps
      : true
    var wasUnknownApp = !effectiveAllowUnknown &&
      NotificationLogic.findSeenApp(service.seenApps, notification.appName) === null
    service.recordSeenApp(notification.appName)

    // A first-time sender blocked by allowUnknownApps isn't silenced just
    // this once — it's muted in the active profile going forward, the same
    // as if the user had opted it in manually. Without this, the *next*
    // notification from the same app would find it already in seenApps
    // (recordSeenApp just added it) and let it straight through, which is
    // not what "block apps I haven't approved" means.
    if (wasUnknownApp) {
      service.setAppMuted(service.activeProfileName, notification.appName, true)
    }

    // The active profile silences this sender, or silences everything. Same
    // treatment as DND from here on — a silenced notification still earns its
    // history entry — and the same bypass, so a profile can't swallow the
    // critical CLI alerts DND already lets through.
    var profileSilenced = NotificationLogic.profileSilences(service.activeProfile,
                                                            notification.appName)

    // DND bypass rules: chat apps abuse urgency=critical to force
    // visibility, so critical alone isn't enough — we also require the
    // sender to be CLI-style. See shouldBypassDnd().
    if ((service.doNotDisturb || profileSilenced || wasUnknownApp) && !shouldBypassDnd(notification)) {
      // The toast never shows, so the only record a silenced notification
      // can leave is a history entry. Write it straight into history —
      // "what did I miss while silenced" is exactly what history is for.
      if (!isEphemeral(notification)) {
        writeSilenced(notification, snapshot)
        return
      }
      delete liveRefs[snapshot.originalId]
      notification.tracked = false
      return
    }

    persistPopupFile(snapshot)
    watchForUpdates(notification, snapshot)
    // Qt.callLater avoids "QV4::Object::insertMember" crashes when a
    // Repeater is mid-incubation while we mutate its model.
    Qt.callLater(function() {
      removePopupsByOriginalId(snapshot.originalId, NotificationLogic.popupFileName(snapshot))
      popupModel.insert(0, snapshot)
      // An update that arrived while the insert was deferred found no row to
      // write to, and a property that already changed will not change again.
      // Reading the object once the row exists catches up on it.
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    })
  }

  // Persist a silenced notification, held tracked until its content is
  // stable: untracking tells the sender its notification closed (Chromium
  // then deletes its avatar file), and a replaces_id update lands on this
  // object without a second onNotification — releasing on a stale snapshot
  // would drop it. Each catch-up write reuses the original file identity.
  function writeSilenced(notification, written) {
    writeHistoryFile(written, function() {
      var updated = null
      try {
        updated = NotificationLogic.replacementSnapshot(notification, written.originalId, written.timestamp)
      } catch (e) {
        // Torn down by the server while the write was queued.
      }
      if (updated && NotificationLogic.popupRowChanged(written, updated)) {
        service.writeSilenced(notification, updated)
        return
      }
      service.releaseSilenced(notification, written.originalId)
    })
  }

  // Let go of a DND-silenced notification once its history write has run.
  // The id may have been reused and the object torn down meanwhile.
  function releaseSilenced(notification, originalId) {
    if (liveRefs[originalId] === notification) delete liveRefs[originalId]
    try {
      notification.tracked = false
    } catch (e) {
      // Object already destroyed by the server — nothing left to release.
    }
  }

  // Everything the card draws. A change to any of these is a client updating
  // the notification in place, which is the only kind of update we ever hear
  // about after the popup exists.
  readonly property var updateSignals: [
    "summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged",
    "imageChanged", "urgencyChanged", "expireTimeoutChanged", "hintsChanged"
  ]

  // A client that updates a notification through replaces_id does not produce
  // a second onNotification: the server writes the new content onto the object
  // we are already holding. The card draws a snapshot copied out of that
  // object — deliberately, since the object itself must stay out of the model
  // — so nothing reaches the screen until we copy it again.
  function watchForUpdates(notification, snapshot) {
    function refresh() {
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    }

    for (var i = 0; i < updateSignals.length; i++) {
      var signal = notification[updateSignals[i]]
      if (signal && typeof signal.connect === "function") signal.connect(refresh)
    }
  }

  function refreshPopup(notification, originalId, timestamp) {
    // A newer notification may have taken this id over, and the object may
    // outlive its popup — in both cases there is nothing here to refresh.
    if (service.liveRefs[originalId] !== notification) return

    var updated
    try {
      updated = NotificationLogic.replacementSnapshot(notification, originalId, timestamp)
    } catch (e) {
      // Object torn down by the server while the signal was in flight.
      return
    }

    var roles = NotificationLogic.popupRoles()
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId || row.timestamp !== timestamp) continue
      if (!NotificationLogic.popupRowChanged(row, updated)) return
      for (var r = 0; r < roles.length; r++) popupModel.setProperty(i, roles[r], updated[roles[r]])
      // important isn't a POPUP_ROLES field (a client update can't change
      // it), but persistPopupFile needs it on the object it's given —
      // replacementSnapshot doesn't carry it, so it's read back off the row
      // that setProperty just left untouched.
      updated.important = row.important
      // The file name is the timestamp and id this popup was persisted under,
      // so the rewrite lands on the same file: a restart restores the version
      // last shown, and so does the copy that ends up in history.
      persistPopupFile(updated)
      return
    }
  }

  // A restored row carries an id from the previous server generation, and
  // the new server hands out ids from 1 again — so a fresh notification
  // with the same originalId is a coincidence, not the same notification.
  // The timestamp (via the file name) disambiguates: it travels with the
  // row through every model and file round-trip.
  function isRestoredRow(row) {
    return !!row && !!restoredPopups[NotificationLogic.popupFileName(row)]
  }

  // A notification arriving under an originalId a popup on screen already
  // holds supersedes it, so that row leaves the screen. Its file is deleted
  // rather than archived: the row taking its place archives itself when it
  // goes, and history would otherwise hold two entries for what the sender
  // means as one notification.
  // keepFileName is the replacement's own file: a same-millisecond
  // replacement shares the replaced row's filename, and the new write is
  // already queued — deleting that path here would erase the replacement's
  // only file.
  function removePopupsByOriginalId(originalId, keepFileName) {
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId) continue
      // Not a replaces_id match — see isRestoredRow. Removing it here
      // would silently kill a restored critical alert on an unrelated ping.
      if (isRestoredRow(row)) continue
      if (NotificationLogic.popupFileName(row) !== keepFileName) deletePopupFileFor(row)
      popupModel.remove(i)
    }
  }

  function dismissPopup(index) {
    removePopup(index, "dismiss")
  }

  function expirePopup(index) {
    removePopup(index, "expire")
  }

  function removePopup(index, reason) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)
    var originalId = entry ? entry.originalId : -1
    // A restored row has no live server object, and its old-generation id
    // may meanwhile belong to a fresh notification — resolving liveRefs by
    // id would dismiss that unrelated notification at the server.
    var restored = isRestoredRow(entry)
    var ref = !restored && originalId >= 0 ? liveRefs[originalId] : null
    // The popup is leaving the screen — for any reason — so its file must not
    // survive to the next shell restart. It becomes the newest history entry
    // instead. Rows that never had a file (a history replay, the empty-history
    // placeholder) archive to nothing, which the move tolerates.
    if (entry) {
      archivePopupFileFor(entry)
      if (restored) delete restoredPopups[NotificationLogic.popupFileName(entry)]
    }
    popupModel.remove(index)
    if (ref) {
      try {
        if (ref.tracked) {
          if (reason === "expire" && typeof ref.expire === "function") ref.expire()
          else ref.dismiss()
        }
      } catch (e) {
        // Object already torn down by the server — nothing to dismiss.
      }
    }
  }

  function clearPopups() {
    while (popupModel.count > 0) dismissPopup(0)
  }

  // Run the popup's click action, then dismiss. Omarchy's own toasts carry the
  // action as an argv vector in the `execArgv` role (see execArgvFromHints),
  // which the persistence files preserve, so restored toasts stay clickable.
  // Third-party clients register a libnotify action under the canonical
  // identifier "default" instead; that one only works while the sender is live.
  function invokePopupDefault(index) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)

    // Run the argv (via Util.execArgv, no shell interpretation). Detached so it
    // outlives the shell, which installer toasts depend on: they restart it.
    var argv = NotificationLogic.parseExecArgv(entry ? entry.execArgv : "")
    if (argv) {
      Util.execArgv(argv)
      dismissPopup(index)
      return
    }
    // Restored rows have no live actions, and looking up liveRefs by their
    // old-generation id could fire an unrelated fresh notification's action.
    var ref = entry && !isRestoredRow(entry) ? liveRefs[entry.originalId] : null
    var invoked = false
    try {
      if (ref && ref.actions) {
        for (var i = 0; i < ref.actions.length; i++) {
          var action = ref.actions[i]
          if (action && action.identifier === "default") {
            action.invoke()
            invoked = true
            break
          }
        }
      }
    } catch (e) {
      // Notification already torn down by the server — fall through to focus.
      console.warn("invoke default failed:", e)
    }
    // Chat apps (Slack, Discord, Vesktop, etc.) rarely register a "default"
    // libnotify action — they just expect clicking the notification to
    // focus their window. Fall back to focusing the sending app by class so
    // that click-to-jump actually works.
    if (!invoked) focusApp(entry)
    dismissPopup(index)
  }

  // Try to focus an existing Hyprland window matching the notification's
  // sender. The helper handles case-insensitive class matching.
  //
  // A Chromium web-notification's body leads with the sending page's own
  // URL (see bodyLinkUrl) — window-focus alone raises the browser but lands
  // wherever it already was, not the tab the notification was about.
  // Opening that URL directly is the one thing that reliably gets there:
  // xdg-open on an http(s) URL hands it to the default browser, which
  // reuses an existing tab for that origin rather than opening a new one
  // when the site is already loaded there.
  function focusApp(entry) {
    if (!entry || !entry.app) return
    var url = NotificationLogic.bodyLinkUrl(entry.body)
    if (url) {
      openUrlProc.command = ["xdg-open", url]
      openUrlProc.running = true
      return
    }
    focusAppProc.command = [
      service.omarchyPath + "/bin/omarchy-hyprland-focus-app",
      String(entry.app)
    ]
    focusAppProc.running = true
  }

  Process { id: focusAppProc; running: false }
  Process { id: openUrlProc; running: false }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", service.stateDir, service.popupStateDir, service.historyDir, service.imagesDir]
    running: false
  }

  // ---------------------------------------------------- popup persistence
  //
  // Mirror every on-screen popup to its own file under popupStateDir so
  // toasts survive shell restarts (notably the restart `omarchy-update`
  // performs). Writes, moves and deletes go through one serialized queue: a
  // burst of replaces_id updates must not race a single reused Process, and
  // ordering guarantees a delete issued after a write wins.

  // Popups restored from a previous shell process, keyed by their file
  // name (timestamp-originalId) since ids alone repeat across server
  // generations. The replaces_id handling and liveRefs lookups must not
  // match these rows against fresh notifications.
  property var restoredPopups: ({})

  // Entries are either { command, done } for a file job or { read: true } for
  // a replay's directory read. Queueing the read rather than running it beside
  // the queue is what makes it a barrier: it takes its place in line, so the
  // history it sees is the one that existed when the replay was asked for.
  // Everything queued after it — a clear, an archive, a silenced write — waits
  // for it, and no amount of later traffic can push it back.
  property var popupFileQueue: []

  // Done callback of the job popupFileProc is currently running.
  property var runningPopupFileJobDone: null

  function enqueuePopupFileJob(command, done) {
    popupFileQueue = popupFileQueue.concat([{ command: command, done: done || null }])
    runNextPopupFileJob()
  }

  function enqueueHistoryRead() {
    popupFileQueue = popupFileQueue.concat([{ read: true }])
    runNextPopupFileJob()
  }

  function runNextPopupFileJob() {
    if (readHistoryProc.running || popupFileProc.running) return
    if (popupFileQueue.length === 0) return

    var job = popupFileQueue[0]
    popupFileQueue = popupFileQueue.slice(1)

    if (job.read) {
      startHistoryRead()
      return
    }

    popupFileProc.command = job.command
    service.runningPopupFileJobDone = job.done || null
    popupFileProc.running = true
  }

  Process {
    id: popupFileProc
    running: false
    onExited: {
      var done = service.runningPopupFileJobDone
      service.runningPopupFileJobDone = null
      if (done) {
        try {
          done()
        } catch (e) {
          console.warn("notifications: file job callback failed:", e)
        }
      }
      service.runNextPopupFileJob()
    }
  }

  // Consumes the remaining args as from/to pairs. Bounded read into a temp
  // file, validated, then renamed into place: the source path is
  // sender-controlled and may grow, block, or become a FIFO mid-copy, and
  // must neither hang the serialized queue nor fill the state dir.
  readonly property string copyImagesScript:
    "while (( $# >= 2 )); do\n" +
    "  if [[ -f $1 ]] && timeout 5 head -c 5242881 -- \"$1\" > \"$2.tmp\" 2>/dev/null &&\n" +
    "     (( $(stat -c%s -- \"$2.tmp\") <= 5242880 )); then mv -f -- \"$2.tmp\" \"$2\"; else rm -f -- \"$2.tmp\"; fi\n" +
    "  shift 2\n" +
    "done\n"

  function persistPopupFile(snapshot) {
    // The JSON travels as an argument, not through shell interpolation, so
    // summaries/bodies with quotes or backticks can't break the command. The
    // mkdir guards notifications that arrive before ensureDirsProc has run.
    // Copies run before the JSON referencing them, while the source exists.
    var persistable = NotificationLogic.persistablePopup(snapshot, imagesDir)
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$2\" || exit 0\n" +
      "dir=\"$1\" json=\"$3\" name=\"$4\"\n" +
      "shift 4\n" +
      copyImagesScript +
      "printf '%s\\n' \"$json\" > \"$dir/$name\"", "--",
      popupStateDir,
      imagesDir,
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      NotificationLogic.popupFileName(snapshot)]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command)
  }

  function deletePopupFileFor(row) {
    if (!row) return
    // History replays and the "no recent notifications" placeholder never
    // had a file — rm -f on the computed paths is a harmless no-op there.
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$2.json\" \"$3/$2\"-*", "--",
      popupStateDir, NotificationLogic.imageStem(row), imagesDir])
  }

  // ---------------------------------------------------- history
  //
  // A popup that leaves the screen keeps its file — it just moves one level
  // down, into historyDir. Trimming happens right there in the same shell
  // job: the names sort numerically by their leading millisecond timestamp,
  // so everything but the newest historyLimit files is the tail to drop,
  // image copies included. Callers set $hist, $limit and $imgs first.
  readonly property string trimHistoryScript:
    "ls -1 \"$hist\" 2>/dev/null | sort -n | head -n \"-$limit\" | while IFS= read -r stale; do rm -f \"$hist/$stale\" \"$imgs/${stale%.json}\"-*; done"

  function archivePopupFileFor(row) {
    if (!row) return
    // A history replay or the empty-history placeholder has no file to move;
    // the failed mv leaves the history untouched, trimming included. Image
    // copies stay put — live and archived entries share imagesDir.
    enqueuePopupFileJob(["bash", "-c",
      "mkdir -p \"$1\" || exit 0\n" +
      "hist=\"$1\" limit=\"$2\" imgs=\"$5\"\n" +
      "mv -f \"$4/$3\" \"$1/$3\" 2>/dev/null || exit 0\n" +
      trimHistoryScript, "--",
      historyDir,
      String(historyLimit),
      NotificationLogic.popupFileName(row),
      popupStateDir,
      imagesDir])
  }

  // Record a notification that never made it to the screen (DND silenced it),
  // straight into history. Same file format as an archived popup, so the
  // replay can't tell the two apart.
  //
  // A silenced notification is untracked the moment it arrives, so the server
  // has nothing left for a later replaces_id to replace and hands the sender a
  // fresh id instead. Every update from a chatty thread is therefore its own
  // notification here, and several can sit in the ten slots together — there
  // is no id to recognize them by, and guessing from app and summary would
  // merge genuinely separate messages.
  function writeHistoryFile(entry, done) {
    if (!entry) {
      if (done) done()
      return
    }
    var persistable = NotificationLogic.persistablePopup(entry, imagesDir)
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$5\" || exit 0\n" +
      "hist=\"$1\" limit=\"$2\" name=\"$3\" json=\"$4\" imgs=\"$5\"\n" +
      "shift 5\n" +
      copyImagesScript +
      "printf '%s\\n' \"$json\" > \"$hist/$name\" || exit 0\n" +
      trimHistoryScript, "--",
      historyDir,
      String(historyLimit),
      NotificationLogic.popupFileName(entry),
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      imagesDir]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command, done)
  }

  function clearHistory() {
    enqueuePopupFileJob(["bash", "-c",
      "for f in \"$1\"/*.json; do\n" +
      "  [[ -e $f ]] || continue\n" +
      "  stale=\"${f##*/}\"\n" +
      "  rm -f \"$f\" \"$2/${stale%.json}\"-*\n" +
      "done", "--", historyDir, imagesDir])
  }

  // Drops one archived notification and its image copy, named by the same
  // "<timestamp>-<originalId>" stem clearHistory sweeps in bulk. The stem is
  // taken as an argument rather than rebuilt here so a malformed one can't
  // walk outside historyDir — validated before it ever reaches the shell.
  function removeHistoryEntry(stem) {
    var safe = String(stem || "")
    if (!/^[0-9]+-[0-9]+$/.test(safe)) return
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$3.json\" \"$2/$3\"-*", "--",
      historyDir, imagesDir, safe])
  }

  // A restart can kill a queued job between its cp and its JSON write,
  // leaving copies no JSON-derived cleanup can name. Swept at startup,
  // through the queue so in-flight copies aren't mistaken for orphans.
  function sweepOrphanImages() {
    enqueuePopupFileJob(["bash", "-c",
      "for img in \"$3\"/*; do\n" +
      "  [[ -e $img ]] || continue\n" +
      "  [[ $img == *.tmp ]] && { rm -f -- \"$img\"; continue; }\n" +
      "  stem=\"${img##*/}\"\n" +
      "  stem=\"${stem%-*}\"\n" +
      "  [[ -e $1/$stem.json || -e $2/$stem.json ]] || rm -f \"$img\"\n" +
      "done", "--", popupStateDir, historyDir, imagesDir])
  }

  Process {
    id: readHistoryProc
    running: false
    // Let the file queue go again, whatever the read did — a failed or empty
    // read must not leave archives and clears parked behind it forever.
    onExited: service.runNextPopupFileJob()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.replayHistory(text)
    }
  }

  // Toasts that were on screen when the replay was asked for. The clear in
  // replayHistory archives them, but the directory read is already in flight
  // by then, so they're handed over in memory instead of being waited for.
  property var replayCarryOver: []

  // Set from the moment a read is queued until it starts, so a second
  // showHistory while one is still waiting its turn doesn't queue another.
  property bool historyReadQueued: false

  // Re-show what's in historyDir as toasts. The read goes through the file
  // queue and its own subprocess, so the replay lands in replayHistory once
  // the work queued ahead of it has finished.
  function showRecentHistory() {
    if (readHistoryProc.running || service.historyReadQueued) return "ok"
    service.replayCarryOver = liveRowsForReplay()
    service.historyReadQueued = true
    enqueueHistoryRead()
    return "ok"
  }

  function startHistoryRead() {
    service.historyReadQueued = false
    readHistoryProc.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", historyDir]
    readHistoryProc.running = true
  }

  // Copy the on-screen rows out of the model. The placeholder from an earlier
  // empty replay carries originalId -1 and is not a notification, so it is
  // left behind rather than replayed as one. The replay dismisses these
  // notifications, and senders delete their images on close — so the carried
  // rows point at the persisted copies, like the archived files they join.
  function liveRowsForReplay() {
    var rows = []
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId < 0) continue
      rows.push(NotificationLogic.persistablePopup({
        id: row.id,
        originalId: row.originalId,
        app: row.app,
        appIcon: row.appIcon,
        summary: row.summary,
        body: row.body,
        image: row.image,
        glyph: row.glyph || "",
        execArgv: row.execArgv || "",
        urgency: row.urgency,
        timestamp: row.timestamp
      }, imagesDir).entry)
    }
    return rows
  }

  function replayHistory(raw) {
    var rows = NotificationLogic.historyRows(
      raw, service.replayCarryOver, NotificationUrgency.Normal, service.historyLimit)
    service.replayCarryOver = []

    // Replaying nothing at all looks like a dead keybinding, so say so.
    if (rows.length === 0) {
      popupModel.insert(0, {
        id: -1,
        originalId: -1,
        app: "omarchy-action",
        appIcon: "",
        summary: "No recent notifications",
        body: "",
        image: "",
        glyph: "󰂚",
        execArgv: "",
        urgency: NotificationUrgency.Low,
        expireTimeout: 0,
        timestamp: Date.now(),
        important: false
      })
      return
    }

    clearPopups()
    // Rows arrive newest-first, and index 0 is the top of the toast stack.
    for (var i = 0; i < rows.length; i++) {
      // Replayed rows are restored rows: their notification died with the
      // sender long ago, so they must never resolve to a live server object
      // that has since been handed their old id.
      service.restoredPopups[NotificationLogic.popupFileName(rows[i])] = true
      popupModel.append(rows[i])
    }
  }

  Process {
    id: restorePopupsProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.restorePopups(text)
    }
  }

  function restorePopups(raw) {
    var entries = NotificationLogic.parsePopupFiles(raw, NotificationUrgency.Normal)
    var now = Date.now()
    var live = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var duration = durationFor(entry.urgency, entry.expireTimeout, entry.important)
      if (NotificationLogic.popupExpired(entry, duration, now)) {
        // It would have expired on screen had the shell kept running, so it
        // gets archived exactly like an expiry that happened while it did.
        archivePopupFileFor(entry)
        continue
      }
      // Survivors restart with a full lifetime on purpose: shell restarts
      // are rare, and a full look after the restart flicker beats resuming
      // a toast with a second left on its clock. The reset is persisted as
      // an absolute deadline so a second restart while the toast is still
      // on screen judges it by the reset clock, not the original timestamp.
      if (duration > 0) {
        entry.deadline = now + duration
        persistPopupFile(entry)
        // deadline is persistence metadata, not a model role — fresh rows
        // never carry it, and ListModel roles must stay consistent.
        delete entry.deadline
      }
      live.push(entry)
    }
    if (live.length === 0) return

    Qt.callLater(function() {
      for (var j = 0; j < live.length; j++) {
        var restored = live[j]
        // A notification received while the restore was reading the dir can
        // already occupy this originalId with the same timestamp — then it
        // IS this entry, live with its own file, and must be left alone. A
        // different timestamp is indistinguishable between a genuine
        // cross-restart replaces_id and a new-generation id coincidence, so
        // show both: a briefly duplicated toast beats silently dropping a
        // restored critical alert.
        var duplicate = false
        for (var k = 0; k < popupModel.count; k++) {
          var row = popupModel.get(k)
          if (row && row.originalId === restored.originalId && row.timestamp === restored.timestamp) {
            duplicate = true
            break
          }
        }
        if (duplicate) continue
        // Append (entries are newest-first) so restored toasts stack in
        // their original order below anything that just arrived. Restored
        // popups have no liveRefs entry — the server object died with the
        // old shell — so dismissal and action fallbacks degrade gracefully.
        service.restoredPopups[NotificationLogic.popupFileName(restored)] = true
        popupModel.append(restored)
      }
    })
  }

  // ---------------------------------------------------- settings persistence

  FileView {
    id: settingsFile
    path: service.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadSettings(text())
    // First-run: the file doesn't exist yet. Without this branch,
    // `settingsLoaded` stays false forever and `scheduleSettingsSave` becomes
    // a no-op — so the file is never created and the DND preference vanishes
    // on shell restart.
    onLoadFailed: service.loadSettings("")
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: service.flushSettings()
  }

  function scheduleSettingsSave() {
    if (!service.settingsLoaded) return
    settingsSaveTimer.restart()
  }

  property bool settingsLoaded: false

  function loadSettings(raw) {
    // FileView can fire onLoaded more than once during startup — the implicit
    // preload when `path` resolves, plus the explicit `settingsFile.reload()`
    // in Component.onCompleted can both end up calling here.
    if (service.settingsLoaded) return

    var parsed = NotificationLogic.parseSettings(raw)
    if (parsed.error) console.warn("notifications: settings parse failed:", parsed.errorMessage || "")

    if (parsed.dnd !== null) {
      service._hydrating = true
      persisted.doNotDisturb = parsed.dnd
      service._hydrating = false
    }

    // A file written before profiles existed has none of these keys; the
    // defaults already assigned stand, and the next save writes them out.
    if (parsed.profiles && parsed.profiles.length) service.profiles = parsed.profiles
    if (parsed.activeProfile) service.activeProfileName = parsed.activeProfile
    if (parsed.seenApps) service.seenApps = parsed.seenApps
    if (parsed.importantApps) service.importantApps = parsed.importantApps

    service.settingsLoaded = true
    // A machine that's been off for a while, or just upgraded from before
    // lastSeen existed, shouldn't wait a full day for the periodic timer to
    // catch entries that are already past 30 days old.
    service.pruneSeenApps()
    // Versions before the history moved into its own directory kept every
    // notification in here. Rewrite once so that dead payload doesn't sit in
    // the file until the next DND toggle happens to clear it.
    if (parsed.legacy) service.scheduleSettingsSave()
    // Keeps the Super+Space menu right from the first load — a fresh shell
    // process only reaches this once, and the profile list it just hydrated
    // may not match whatever the menu file's managed block currently shows
    // (e.g. it was hand-edited, or a profile changed while the shell was down).
    service.syncProfilesMenu()
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({
      // 7: allowUnknownApps moved from a top-level global (with each profile
      // able to null-inherit it) to a plain boolean living only on each
      // profile — every profile already set its own Allow/Block, so the
      // global default only mattered for a profile left on "inherit", which
      // wasn't worth the extra state. Deliberate simplification, not a bug.
      version: 7,
      dnd: persisted.doNotDisturb,
      activeProfile: service.activeProfileName,
      profiles: service.profiles,
      seenApps: service.seenApps,
      importantApps: service.importantApps
    }, null, 2) + "\n")
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    // Once mkdir has had a tick, load the existing settings file. FileView
    // surfaces an empty string when the file doesn't exist; loadSettings
    // handles that path.
    Qt.callLater(function() {
      settingsFile.reload()
      // Re-show popups that were on screen when the previous shell died.
      // The glob-through-bash tolerates a missing/empty dir (first run).
      // awk 1 (not cat) so a torn file missing its trailing newline can't
      // glue itself onto the next file and take a valid popup down with it.
      restorePopupsProc.command = ["bash", "-c",
        "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", service.popupStateDir]
      restorePopupsProc.running = true
      // Safe beside the restore read: it only re-persists entries whose
      // JSON exists, exactly the images the sweep keeps.
      service.sweepOrphanImages()
    })
  }

  // ---------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function dndState(): string {
      return service.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      var v = String(value || "").toLowerCase()
      var on = v === "true" || v === "1" || v === "on" || v === "yes"
      service.setDoNotDisturb(on)
      return dndState()
    }

    function isDnd(): string {
      return dndState()
    }

    // Replay the notifications that have been moved into the history dir.
    function showHistory(): string {
      return service.showRecentHistory()
    }

    // `clear` forgets the recorded history; the toasts on screen stay put.
    function clear(): string {
      service.clearHistory()
      return "ok"
    }

    // One archived notification, by its "<timestamp>-<originalId>" stem.
    function removeHistoryEntry(stem: string): string {
      service.removeHistoryEntry(stem)
      return "ok"
    }

    // Clicking a history row: no live Notification object survives into the
    // archive, so there's no stored action to replay — focusing the sender
    // by app name is what invokePopupDefault already falls back to for chat
    // apps, and it's the only thing an archived entry can still do.
    function focusHistoryApp(app: string, body: string): string {
      service.focusApp({ app: String(app || ""), body: String(body || "") })
      return "ok"
    }

    function dismissAll(): string {
      service.clearPopups()
      return "ok"
    }

    // Dismiss the most recent popup.
    function dismissOne(): string {
      if (popupModel.count === 0) return "none"
      service.dismissPopup(0)
      return "ok"
    }

    // Fire the default action on the most recent popup, then dismiss it.
    function invokeLast(): string {
      if (popupModel.count === 0) return "none"
      service.invokePopupDefault(0)
      return "ok"
    }

    // Take a toast off the screen by summary substring, used by the
    // first-run notifications once their action has been clicked.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var hit = false
      for (var i = popupModel.count - 1; i >= 0; i--) {
        var row = popupModel.get(i)
        if (row && String(row.summary || "").indexOf(needle) !== -1) {
          service.dismissPopup(i)
          hit = true
        }
      }
      return hit ? "ok" : "none"
    }

    // ------------------------------------------------ profiles
    //
    // The config panel and the bar widget both drive the daemon through
    // these rather than sharing the settings file, so there is one writer
    // and no read-modify-write race against a notification arriving.

    function listProfiles(): string {
      return JSON.stringify({
        active: service.activeProfileName,
        profiles: service.profiles,
        seenApps: service.seenAppNames,
        importantApps: service.importantApps
      })
    }

    function activeProfile(): string {
      return service.activeProfileName
    }

    function setProfile(name: string): string {
      return service.setActiveProfile(name) ? service.activeProfileName : "unknown"
    }

    function cycleProfile(): string {
      return service.cycleProfile()
    }

    // Whole-list replacement from the config panel, as a JSON array.
    // Takes {"profiles": [...]} rather than a bare JSON array: qs ipc's
    // argv parsing strips a leading "[" / trailing "]" from an argument
    // that starts and ends with them, so a bare array arrives at
    // JSON.parse missing its outer brackets. Wrapping in an object sidesteps
    // that entirely.
    function saveProfiles(json: string): string {
      var parsed = null
      try {
        parsed = JSON.parse(String(json || ""))
      } catch (e) {
        return "invalid"
      }
      if (!parsed || !Array.isArray(parsed.profiles)) return "invalid"
      service.setProfiles(parsed.profiles)
      return "ok"
    }

    function muteApp(profileName: string, appName: string): string {
      return service.setAppMuted(profileName, appName, true) ? "ok" : "unknown"
    }

    function unmuteApp(profileName: string, appName: string): string {
      return service.setAppMuted(profileName, appName, false) ? "ok" : "unknown"
    }

    // Plain per-profile boolean now — "true" allows a first-time sender
    // through in this profile, anything else blocks it.
    function setProfileAllowUnknownApps(profileName: string, value: string): string {
      var v = String(value || "").toLowerCase()
      var allow = v === "true" || v === "1" || v === "on" || v === "yes"
      return service.setProfileAllowUnknownApps(profileName, allow) ? "ok" : "unknown"
    }

    // Whether an app's toast stays on screen by default, absent a profile
    // override — see NotificationLogic.isAppImportant for how a profile's
    // own override list can still change the outcome for that app.
    function setImportantApp(appName: string, important: string): string {
      var v = String(important || "").toLowerCase()
      service.setImportantApp(appName, v === "true" || v === "1" || v === "on" || v === "yes")
      return "ok"
    }

    // value: "true" forces this app important in this profile, "false"
    // forces it not-important, "inherit" (or anything else) clears the
    // override and goes back to the global importantApps list.
    function setProfileImportantOverride(profileName: string, appName: string, value: string): string {
      var v = String(value || "").toLowerCase()
      var stored = v === "true" ? true : (v === "false" ? false : null)
      return service.setProfileImportantOverride(profileName, appName, stored) ? "ok" : "unknown"
    }

    // Drops one tracked app so it stops cluttering the mute list. Not a
    // block: the next notification from it re-adds it, seen fresh.
    function forgetSeenApp(appName: string): string {
      service.forgetSeenApp(appName)
      return "ok"
    }

    // Adds an app to the tracked list from the installed-apps picker, ahead
    // of it ever actually sending a notification — see service.trackApp.
    function trackApp(appName: string): string {
      service.trackApp(appName)
      return "ok"
    }

    function ping(): string { return "ok" }
  }

  // ---------------------------------------------------- server

  NotificationServer {
    id: server
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true

    onNotification: function(notification) {
      service.handleNotification(notification)
    }
  }

  // -------------------------------------------------------------- popup UI
  //
  // One PanelWindow per output (Variants on Quickshell.screens) holding the
  // stacked toast cards. Layer is Overlay, exclusionMode Ignore, no
  // keyboard focus — popups are passive surfaces and must never steal input
  // from the focused application.

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: popupWindow
      required property var modelData
      screen: modelData
      visible: popupModel.count > 0

      WlrLayershell.namespace: "omarchy-notifications"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      readonly property var popupPlacement: NotificationLogic.popupPlacement(
        service.barPosition, service.barClearance, Style.gapsOut)

      // Full-screen, fixed-size surface (like the OSD overlay). Adding or
      // removing a toast changes only the content inside; the Wayland surface
      // never resizes, so the compositor can't briefly scale a stale buffer --
      // which is what stretched/squished the cards during count changes.
      anchors { top: true; bottom: true; left: true; right: true }

      // Keep the surface click-through except over the toast column, so the
      // rest of the (invisible) full-screen overlay never eats input.
      mask: Region { item: popupColumn }

      ColumnLayout {
        id: popupColumn
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: popupWindow.popupPlacement.margins.top
        anchors.rightMargin: popupWindow.popupPlacement.margins.right
        spacing: Style.space(8)

        Repeater {
          model: popupModel

          // The delegate is a slot Item that owns lifetime timer state. The
          // actual visuals live in NotificationCard, which the history panel
          // also reuses.
          delegate: Item {
            id: cardSlot
            required property int index
            required property string app
            required property string appIcon
            required property string summary
            required property string body
            required property string image
            required property string glyph
            required property int urgency
            required property double expireTimeout
            required property double timestamp
            required property bool important

            // Each card sizes itself based on mode (text vs media); the slot
            // tracks the card so the column auto-fits to whichever is widest.
            Layout.preferredWidth: card.implicitWidth
            Layout.alignment: Qt.AlignRight
            implicitHeight: card.implicitHeight

            readonly property real lifetime: service.durationFor(cardSlot.urgency, cardSlot.expireTimeout, cardSlot.important)
            property real remainingLifetime: 1.0
            readonly property bool ticking: cardSlot.lifetime > 0 && !card.hovered

            // A client updating this notification in place rewrites the row
            // under the card (see refreshPopup). New text deserves a full look,
            // so the countdown starts over instead of running out the clock the
            // superseded text was already most of the way through. Delegates
            // keep their own row as the model changes around them, so only a
            // real content change lands here.
            onSummaryChanged: cardSlot.remainingLifetime = 1.0
            onBodyChanged: cardSlot.remainingLifetime = 1.0
            onImageChanged: cardSlot.remainingLifetime = 1.0

            Timer {
              interval: 50
              repeat: true
              running: cardSlot.ticking
              onTriggered: {
                if (cardSlot.lifetime <= 0) return
                cardSlot.remainingLifetime -= 50.0 / cardSlot.lifetime
                if (cardSlot.remainingLifetime <= 0) {
                  cardSlot.remainingLifetime = 0
                  service.expirePopup(cardSlot.index)
                }
              }
            }

            NotificationCard {
              id: card
              anchors.right: parent.right
              app: cardSlot.app
              appIcon: cardSlot.appIcon
              summary: cardSlot.summary
              body: cardSlot.body
              image: cardSlot.image
              urgency: cardSlot.urgency
              timestamp: cardSlot.timestamp
              cornerRadius: service.cornerRadius
              fontFamily: service.shell && service.shell.bar ? service.shell.bar.fontFamily : ""
              glyph: cardSlot.glyph

              onCloseRequested: service.dismissPopup(cardSlot.index)
              onCardClicked: service.invokePopupDefault(cardSlot.index)
            }
          }
        }
      }
    }
  }
}
