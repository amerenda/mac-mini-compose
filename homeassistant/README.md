# Home Assistant Configuration

All Home Assistant configuration is managed via GitOps through the `mac-mini-compose` repo. Files in `homeassistant/configuration/` are bind-mounted read-only into the HA container. Changes go through git, not the HA UI.

## Smart Lighting v2

A fully UI-configurable lighting system that automatically applies the correct Hue scene based on the time of day, regardless of how lights are triggered (voice, physical switch, Hue dimmer, motion sensor, automation, or timer).

### Dashboard

The **Smart Lighting** dashboard in the HA sidebar provides full control over the system. No YAML editing is needed for day-to-day configuration.

### How It Works

```
Any trigger (voice, switch, motion, timer)
  → light turns on
  → state-change automation fires
  → determines current time window (morning/day/evening/night)
  → checks weekday vs weekend schedule
  → activates scene.<room>_<window>
```

Scenes follow the naming convention `scene.<room>_<window>` (e.g., `scene.living_room_evening`). These are Hue scenes created on the Hue Bridge and discovered by HA automatically.

### Settings Reference

#### Global Settings (Top Bar)

| Setting | What It Does |
|---------|-------------|
| **Smart Lighting** (`sl_enabled`) | Master toggle for the entire v2 system. When OFF, all v2 automations are disabled and the v1 lighting system takes over. Turn OFF to instantly revert to the previous lighting behavior without any other changes. |
| **Current Window** (`sensor.sl_current_window`) | Read-only indicator showing which time window is currently active (morning, day, evening, or night). Derived from the current time, the weekday/weekend schedule, and which days are configured as weekend days. Updates automatically. |
| **House Mode** (`sl_house_mode`) | Controls how the system behaves globally. Options: **Home** — normal operation, all automations active, scenes applied based on time window. **Away** — lights are turned off when triggered (intended for when nobody is home; future: security-only behavior). **Sleep** — only rooms with night motion enabled will activate; all other rooms stay off. **Guest** — same as Home (future: guest-specific scene preferences). |

#### Schedule

The schedule defines when each time window starts. There are separate schedules for weekday and weekend days.

| Setting | What It Does |
|---------|-------------|
| **Morning Start** | The time the "morning" window begins. Before this time, the "night" window is active. Default: 06:00 weekday, 08:00 weekend. |
| **Day Start** | The time the "day" window begins. Default: 09:00 weekday, 10:00 weekend. |
| **Evening Start** | The time the "evening" window begins. Default: 17:00 weekday, 18:00 weekend. |
| **Night Start** | The time the "night" window begins. Runs until the next morning start. Default: 22:00 weekday, 23:00 weekend. |

The weekend schedule is used on days marked as weekend days. This lets you have later morning/night times on weekends without affecting your weekday routine.

#### Weekend Days

By default, Saturday and Sunday use the weekend schedule. Toggle any day on to make it use the weekend schedule instead of the weekday schedule. Use cases:

- You work a non-standard schedule (e.g., Tuesday–Saturday) — set Sunday and Monday as weekend days
- You have a day off mid-week — temporarily toggle that day to weekend
- Holiday week — toggle all days to weekend

#### Per-Room Settings

Select a room from the dropdown to configure its behavior.

| Setting | What It Does |
|---------|-------------|
| **Motion Triggers (Morning/Day/Evening/Night)** | Controls whether a motion sensor in this room will trigger the lights during each time window. Each window can be independently enabled or disabled. For example, enable night motion in the bathroom (so lights come on when you walk in at 2am) but disable it in the bedroom (so motion doesn't wake your partner). Motion sensors are not yet installed — these toggles are ready for when they are. |
| **Motion Timeout (min)** | How many minutes after motion stops before the lights automatically turn off. Only applies to motion-triggered activations. Range: 1–60 minutes. Default: 5 minutes. |
| **Auto Transition** | When enabled, if the lights in this room are already on when a time window boundary is reached (e.g., 5pm weekday = evening starts), the scene automatically transitions to the new window's scene. When disabled, lights stay on their current scene until manually changed or turned off and back on. |
| **Smooth Transition** | When enabled, scene transitions at window boundaries will gradually fade from the current scene to the new scene instead of switching instantly. **Not yet implemented** — the toggle exists and is saved, but the gradual transition logic will be added in a future update. Currently behaves the same as Auto Transition (instant switch). |
| **Transition Duration (min)** | How long a smooth transition takes, in minutes. Only applies when Smooth Transition is enabled. Range: 1–30 minutes. Default: 10 minutes. For example, at 10 minutes, the lights will gradually shift from the current scene to the new scene over a 10-minute period at each window boundary. **Not yet implemented** — saved for when smooth transition logic is added. |
| **Override Active** | Shows whether a manual override is currently active for this room. An override is set when someone explicitly requests specific lighting parameters (e.g., "set lights to full brightness" via voice). While override is active, the system will not apply time-based scenes to this room. **Override automatically clears at the next time window transition.** You can also manually toggle this off to resume normal scene behavior immediately. |

### Adding a New Room

1. Create 4 Hue scenes on the Hue Bridge following the naming convention: `<room>_morning`, `<room>_day`, `<room>_evening`, `<room>_night`
2. HA discovers the scenes automatically via the Hue integration
3. Add the room's helpers:
   - `helpers/generated/input_boolean/sl_<room>.yaml` — motion toggles, auto/smooth transition, override
   - `helpers/generated/input_number/sl_<room>.yaml` — motion timeout
   - `helpers/generated/timer/sl_motion.yaml` — add a timer entry
4. Add the room to `input_select/sl_global.yaml` → `sl_room_selector` options
5. Add automations: `automations/sl_<room>.yaml`, `sl_<room>_motion.yaml`, `sl_<room>_motion_off.yaml`
6. Add a conditional card to the dashboard YAML for the new room
7. Add the room to the override clear list in `automations/sl_window_transition.yaml`
8. Commit, push, deploy

### Switching Between v1 and v2

Toggle `input_boolean.sl_enabled` (the "Smart Lighting" toggle on the dashboard):

- **ON**: v2 automations are active. Lights trigger scenes based on time window, schedule, and house mode.
- **OFF**: v2 automations are completely disabled. The existing v1 scripts (`scheduled_light_on`, `room_toggle`, etc.) continue to work as before. No v2 logic runs.

Both systems coexist — all v2 helpers use the `sl_` prefix and do not conflict with v1 helpers. You can switch back and forth at any time.

### Architecture

```
homeassistant/configuration/
├── automations/
│   ├── sl_<room>.yaml              — State-change trigger (light on → apply scene)
│   ├── sl_<room>_motion.yaml       — Motion trigger (disabled, no sensors yet)
│   ├── sl_<room>_motion_off.yaml   — Motion auto-off timer (disabled)
│   └── sl_window_transition.yaml   — Global: re-apply scenes at window boundaries
├── scripts/
│   ├── sl_room_on.yaml             — Core logic: determine window, check mode, apply scene
│   └── sl_room_off.yaml            — Turn off room + clear override
├── helpers/generated/
│   ├── input_boolean/sl_*.yaml     — Toggles (motion, transition, override, UI)
│   ├── input_datetime/sl_*.yaml    — Schedule times (weekday + weekend)
│   ├── input_number/sl_*.yaml      — Motion timeout per room
│   ├── input_select/sl_*.yaml      — House mode, room selector
│   ├── input_text/sl_*.yaml        — Last window tracker
│   └── timer/sl_*.yaml             — Motion auto-off timers
├── packages/
│   └── sl_smart_lighting.yaml      — Template sensor (current window)
└── dashboards/
    └── smart_lighting.yaml         — Dashboard YAML
```

### Frontend Cards (installed by ha-init)

The Smart Lighting dashboard uses custom frontend cards, all installed automatically by the `hacs-init` container with pinned versions:

| Card | Version | Purpose |
|------|---------|---------|
| Mushroom Cards | v5.1.1 | Clean entity card styling |
| Bubble Card | v3.1.4 | Pop-up overlays (future use) |
| card-mod | v4.2.1 | CSS customization |
| Vertical Stack In Card | v1.0.1 | Seamless card grouping |
| Streamline Card | v0.2.0 | Template reuse for DRY YAML (future use) |

To update a card version, edit `homeassistant/scripts/ha-init.sh`, push, and redeploy. The host-side sync script picks up changes within 60 seconds.
