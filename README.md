# notification-profiles

An [Omarchy](https://omarchy.org) plugin that adds named notification
profiles — Work, Game, Normal, whatever you want — each muting its own set
of apps. Switch from a bar chip; the same panel shows recent notification
history underneath.

Built as a fork of Omarchy's first-party `omarchy.notifications` plugin
(the daemon that owns the freedesktop notification D-Bus name), extended
with profile-aware filtering, plus a new bar widget for switching profiles
and browsing history.

## What it does

- **Profiles**: each is `{ name, icon, muteApps, dndAll }`. A muted app's
  notification never raises a toast while that profile is active — it still
  lands in history, same as the existing DND toggle already worked.
- **Bar widget**: click to switch profiles, click the pencil on a profile
  chip to edit it, `+` to add one. History list sits right below, always
  visible alongside the profile strip.
- **Seen apps**: every app that has ever sent a notification is tracked, so
  the editor offers real names instead of asking you to type one from
  memory.

## Install

```bash
omarchy plugin add https://github.com/diegodiaz1256/notification-profiles --enable --yes
```

Installing this disables the stock `omarchy.notifications` (Omarchy's clone
semantics — only one plugin can own the notification D-Bus name at a time).
`omarchy plugin remove notification-profiles` restores it.

## Settings

| Setting | Default | |
| --- | --- | --- |
| Show profile name in the bar | on | Off leaves just the icon, for a crowded bar. |

## Upstream

`Service.qml` and `NotificationLogic.js` started as a copy of Omarchy's
`shell/plugins/notifications/` at
[basecamp/omarchy](https://github.com/basecamp/omarchy) (MIT), via
`omarchy plugin clone omarchy.notifications`. `Panel.qml` — the bar widget
and profile/history UI — is new.

## License

MIT.
