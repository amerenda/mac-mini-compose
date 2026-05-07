const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const mqtt = require('mqtt');

const CACHE_FILE = path.join(__dirname, 'sl-cache.json');
const RUNTIME_FILE = path.join(__dirname, 'sl-runtime.json');
const CONFIG_TOPIC = 'zigbee2mqtt/sl/config';
const SNAP_TOPIC = 'zigbee2mqtt/sl/snap';
const STATUS_TOPIC = 'zigbee2mqtt/sl/status';
const BASE_TOPIC = 'zigbee2mqtt';

// Zigbee scene IDs: morning=1, day=2, evening=3, night=4
const WINDOW_SCENE_ID = { morning: 1, day: 2, evening: 3, night: 4 };
const WINDOWS = ['morning', 'day', 'evening', 'night'];
const DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

const ROOM_KEY_TO_GROUP = {
    living_room: 'Living Room',
    bedroom: 'Bedroom',
    bathroom: 'Bathroom',
    kitchen: 'Kitchen',
    hallway: 'Hallway',
};

const GROUP_TO_ROOM_KEY = Object.fromEntries(
    Object.entries(ROOM_KEY_TO_GROUP).map(([k, v]) => [v, k])
);

/** Hue dimmer MQTT payload → config key on switch object */
const PAYLOAD_TO_SLOT = {
    on_press_release: 'b1_short',
    on_hold: 'b1_long',
    up_press_release: 'b2_short',
    up_hold: 'b2_long',
    down_press_release: 'b3_short',
    down_hold: 'b3_long',
    off_press_release: 'b4_short',
    off_hold: 'b4_long',
};

/** Blueprint "Default" behavior per raw payload (matches sl_hue_dimmer default branch) */
const DEFAULT_ACTION_BY_PAYLOAD = {
    on_press_release: '__toggle_default',
    on_hold: 'Power Off Room',
    up_press_release: 'Brightness Up',
    up_hold: 'Brightness Max',
    down_press_release: 'Brightness Down',
    down_hold: 'Brightness Min',
    off_press_release: 'Cycle Scenes',
    off_hold: 'Custom Scene',
};

// Stagger delay between Zigbee commands (ms) to avoid flooding
const CMD_STAGGER = 200;
// Hue dimmers are often Zigbee-bound to the same group as MQTT control. Their On
// after mains restore can race our publish and restore white (PHY power-on state).
// A second scene_recall after bind traffic settles fixes that class of bug.
const ROOM_ON_REINFORCE_MS = 380;

class SmartLighting {
    constructor(zigbee, mqtt, state, publishEntityState, eventBus, enableDisableExtension, restartCallback, addExtension, settings, logger) {
        this.zigbee = zigbee;
        this.z2mMqtt = mqtt;
        this.state = state;
        this.eventBus = eventBus;
        this.settings = settings;
        this.logger = logger;
        this.config = null;
        this.configHash = null;
        this.lastSyncTime = null;
        this.currentWindow = null;
        this.checkInterval = null;
        this.cmdClient = null;
        /** @type {string[]} */
        this._switchTopics = [];
        /** @type {Record<string, ReturnType<typeof setTimeout>>} */
        this._roomOnReinforceTimers = Object.create(null);
        this.runtime = this._loadRuntime();
        /** @type {Record<string, 'ON'|'OFF'>} Populated via cmdClient MQTT subscription */
        this._deviceStateCache = Object.create(null);
        /** What WE last commanded each room group to be. Used for toggle direction instead of
         *  _deviceStateCache so the Zigbee binding race can't flip the toggle the wrong way:
         *  when B1 is pressed the dimmer binding fires "on" to the group before the action
         *  arrives, updating _deviceStateCache; _desiredState is immune to that. */
        this._desiredState = Object.create(null);
        /** Epoch ms before which device announces are ignored (avoids Z2M-restart flood) */
        this._smartPowerOnReadyAt = 0;
    }

    async start() {
        this.logger.info('[SL] Smart Lighting extension starting');

        // Separate MQTT client for commands (Z2M ignores its own messages)
        const mqttSettings = this.settings.get().mqtt;
        const brokerUrl = mqttSettings.server || 'mqtt://localhost:1883';
        this.cmdClient = mqtt.connect(brokerUrl, {
            clientId: 'z2m-smart-lighting-cmd',
            username: mqttSettings.user || undefined,
            password: mqttSettings.password || undefined,
        });

        this.logger.info(`[SL] Connecting cmdClient to ${brokerUrl}`);

        this.cmdClient.on('message', (topic, msg) => {
            // Bridge events: device announce, etc.
            if (topic === 'zigbee2mqtt/bridge/event') {
                try {
                    const ev = JSON.parse(msg.toString());
                    if (ev.type === 'device_announce') {
                        const fn = ev.data && ev.data.friendly_name;
                        if (fn) this._onDeviceAnnounce(fn);
                    }
                } catch { /* ignore */ }
                return;
            }

            const m = topic.match(/^zigbee2mqtt\/([^/]+)$/);
            if (!m) return;
            const deviceName = m[1];
            try {
                const parsed = JSON.parse(msg.toString());
                if (parsed.state === 'ON' || parsed.state === 'OFF') {
                    this._deviceStateCache[deviceName] = parsed.state;
                }
                if (typeof parsed.action === 'string' && parsed.action) {
                    this.logger.info(`[SL] cmdClient RX action: device="${deviceName}" action="${parsed.action}"`);
                    const knownSwitches = this.config && this.config.switches
                        ? Object.keys(this.config.switches) : [];
                    const sw = knownSwitches.length > 0
                        ? this.config.switches[deviceName] : null;
                    if (sw) {
                        this._handleSwitchAction(sw, parsed.action);
                    } else {
                        this.logger.warn(`[SL] cmdClient action: no switch config for "${deviceName}". Known switches: [${knownSwitches.join(', ')}]`);
                    }
                }
            } catch { /* ignore non-JSON */ }
        });

        await new Promise((resolve, reject) => {
            this.cmdClient.on('connect', () => {
                this.logger.info('[SL] Command MQTT client connected');
                // Single-level wildcard captures device + group state topics.
                // Filtered to ON/OFF in the message handler above.
                this.cmdClient.subscribe('zigbee2mqtt/+', err => {
                    if (err) this.logger.warn(`[SL] state-cache subscribe: ${err.message}`);
                    else this.logger.info('[SL] cmdClient subscribed for device/group state cache');
                });
                this.cmdClient.subscribe('zigbee2mqtt/bridge/+', err => {
                    if (err) this.logger.warn(`[SL] bridge subscribe: ${err.message}`);
                    else this.logger.info('[SL] cmdClient subscribed to bridge events');
                });
                resolve();
            });
            this.cmdClient.on('error', (err) => {
                this.logger.error(`[SL] Command MQTT client error: ${err.message}`);
                reject(err);
            });
            setTimeout(() => reject(new Error('MQTT connect timeout')), 5000);
        });

        // Load cached config
        this.config = this._loadCache();
        if (this.config) {
            this.configHash = this._hashConfig(this.config);
            const cachedSwitches = Object.keys(this.config.switches || {});
            this.logger.info(`[SL] Loaded cached config from disk — hash=${this.configHash} switches=[${cachedSwitches.join(', ')}]`);
            this.currentWindow = this._calculateCurrentWindow();
            this.logger.info(`[SL] Current window: ${this.currentWindow}`);
        } else {
            this.logger.info('[SL] No cached config, waiting for HA');
        }

        // Subscribe to HA config pushes
        await this.z2mMqtt.subscribe(CONFIG_TOPIC);
        this.logger.info(`[SL] Subscribed to ${CONFIG_TOPIC}`);

        // Snap-on-edit: HA fires this after a per-room save so we can recall when
        // the saved window matches the current window.
        await this.z2mMqtt.subscribe(SNAP_TOPIC);
        this.logger.info(`[SL] Subscribed to ${SNAP_TOPIC}`);

        await this._refreshSwitchTopicSubscriptions();

        this.eventBus.onMQTTMessage(this, this._onMQTTMessage.bind(this));

        // Ignore device announces during the first 60 s so that Z2M-restart
        // re-joins don't trigger smart_power_on for every bulb simultaneously.
        this._smartPowerOnReadyAt = Date.now() + 60000;

        // Note: Z2M auto-discovers scene entities to HA via MQTT.
        // These are disabled in HA's entity registry to avoid duplicates.
        // Our HA scenes (from scenes.yaml) are the canonical ones.

        // Check window transitions every 30s
        this.checkInterval = setInterval(() => this._checkWindowTransition(), 30000);

        // Initial full push after Z2M finishes starting
        if (this.config && this.currentWindow) {
            setTimeout(() => this._fullScenePush(), 5000);
        }

        this._publishStatus('started');
    }

    async stop() {
        this.logger.info('[SL] Smart Lighting extension stopping');
        if (this.checkInterval) clearInterval(this.checkInterval);
        for (const k of Object.keys(this._roomOnReinforceTimers)) {
            clearTimeout(this._roomOnReinforceTimers[k]);
            delete this._roomOnReinforceTimers[k];
        }
        if (this.cmdClient) this.cmdClient.end();
        this.checkInterval = null;
        this.cmdClient = null;
        for (const t of this._switchTopics) {
            try {
                await this.z2mMqtt.unsubscribe(t);
            } catch (_) { /* ignore */ }
        }
        this._switchTopics = [];
        this.eventBus.removeListeners(this);
    }

    // ── Send command via external MQTT client ────────────────

    _sendCommand(topic, payload) {
        const fullTopic = `${BASE_TOPIC}/${topic}`;
        const message = typeof payload === 'string' ? payload : JSON.stringify(payload);
        if (this.cmdClient && this.cmdClient.connected) {
            this.cmdClient.publish(fullTopic, message);
        } else {
            this.logger.warn(`[SL] CMD client not connected, dropping: ${fullTopic}`);
        }
    }

    // Helper: send multiple commands with stagger delay
    async _sendCommandsStaggered(commands) {
        for (let i = 0; i < commands.length; i++) {
            this._sendCommand(commands[i].topic, commands[i].payload);
            if (i < commands.length - 1) {
                await new Promise(r => setTimeout(r, CMD_STAGGER));
            }
        }
    }

    // ── Config from HA ───────────────────────────────────────

    _onMQTTMessage(data) {
        if (data.topic === CONFIG_TOPIC) {
            try {
                const newConfig = JSON.parse(data.message.toString());
                this.config = newConfig;
                this.configHash = this._hashConfig(newConfig);
                this._saveCache(newConfig);
                const switchKeys = Object.keys(newConfig.switches || {});
                this.logger.info(`[SL] Config received — hash=${this.configHash} switches=[${switchKeys.join(', ')}] rooms=[${Object.keys(newConfig.rooms || {}).join(', ')}]`);
                this.currentWindow = this._calculateCurrentWindow();
                this._refreshSwitchTopicSubscriptions()
                    .catch(e => this.logger.error(`[SL] switch subscribe: ${e.message}`));
                this._fullScenePush();
                this._publishStatus('config_updated');
            } catch (e) {
                this.logger.error(`[SL] Failed to parse config: ${e.message}`);
            }
            return;
        }

        if (data.topic === SNAP_TOPIC) {
            this._handleSnap(data.message.toString());
            return;
        }

        // Z2M 1.x fallback: action published as plain string on a separate /action subtopic.
        // Z2M 2.x routes actions via the main device topic; those are handled in the
        // cmdClient message handler (separate MQTT connection, receives Z2M's own publishes).
        const actionMatch = data.topic.match(/^zigbee2mqtt\/([^/]+)\/action$/);
        if (!actionMatch) return;
        const device = actionMatch[1];
        const sw = this.config && this.config.switches ? this.config.switches[device] : null;
        if (!sw) return;
        this._handleSwitchAction(sw, data.message.toString().trim());
    }

    _handleSnap(messageStr) {
        let parsed;
        try {
            parsed = JSON.parse(messageStr);
        } catch (e) {
            this.logger.error(`[SL] snap parse: ${e.message}`);
            return;
        }
        const roomKey = parsed && parsed.room_key;
        const window = parsed && parsed.window;
        if (!roomKey || !window) {
            this.logger.warn(`[SL] snap missing room_key/window: ${messageStr}`);
            return;
        }
        if (!WINDOWS.includes(window)) {
            this.logger.info(`[SL] snap ignored: window=${window} not standard`);
            return;
        }
        if (window !== this.currentWindow) {
            this.logger.info(`[SL] snap ignored: window=${window} != currentWindow=${this.currentWindow}`);
            return;
        }
        const displayName = ROOM_KEY_TO_GROUP[roomKey];
        if (!displayName) {
            this.logger.warn(`[SL] snap unknown room_key: ${roomKey}`);
            return;
        }
        const roomConfig = this.config && this.config.rooms ? this.config.rooms[displayName] : null;
        if (!roomConfig) {
            this.logger.warn(`[SL] snap no roomConfig for ${displayName}`);
            return;
        }
        this.logger.info(`[SL] snap edit-recall: ${displayName} (${window})`);
        this._recallSceneIfOn(displayName, roomConfig, window);
    }

    async _refreshSwitchTopicSubscriptions() {
        const want = [];
        if (this.config && this.config.switches) {
            for (const dev of Object.keys(this.config.switches)) {
                want.push(`${BASE_TOPIC}/${dev}/action`);
            }
        }
        const wantSet = new Set(want);
        const oldSet = new Set(this._switchTopics);
        for (const t of this._switchTopics) {
            if (!wantSet.has(t)) {
                try {
                    await this.z2mMqtt.unsubscribe(t);
                } catch (e) {
                    this.logger.warn(`[SL] unsubscribe ${t}: ${e.message}`);
                }
            }
        }
        for (const t of want) {
            if (!oldSet.has(t)) {
                await this.z2mMqtt.subscribe(t);
                this.logger.info(`[SL] Subscribed to ${t}`);
            }
        }
        this._switchTopics = want;
    }

    _resolveSwitchAction(sw, payload) {
        const slot = PAYLOAD_TO_SLOT[payload];
        if (!slot) return 'Do Nothing';
        const configured = sw[slot];
        if (configured && configured !== 'Default') return configured;
        return DEFAULT_ACTION_BY_PAYLOAD[payload] || 'Do Nothing';
    }

    _handleSwitchAction(sw, payload) {
        const action = this._resolveSwitchAction(sw, payload);
        if (action === 'Do Nothing') return;

        if (action === 'Custom Scene') {
            this.logger.warn('[SL] Custom Scene requires Home Assistant (scene.turn_on); no-op in Z2M-only runtime');
            return;
        }

        const roomKey = sw.room_key;
        const roomGroup = sw.room_group;

        if (action === '__toggle_default') {
            this._toggleRoomDefault(sw);
            return;
        }

        switch (action) {
            case 'Toggle Room':
                this._toggleRoom(roomKey, roomGroup);
                break;
            case 'Power Off Room':
                this._roomOff(roomKey, roomGroup);
                break;
            case 'Power Off All':
                this._powerOffAll();
                break;
            case 'Brightness Up':
                this._brightnessStep(roomGroup, sw, 1);
                break;
            case 'Brightness Down':
                this._brightnessStep(roomGroup, sw, -1);
                break;
            case 'Brightness Max':
                this._brightnessSet(roomGroup, roomKey, 255);
                break;
            case 'Brightness Min':
                this._brightnessSet(roomGroup, roomKey, this._minBrightness255(sw));
                break;
            case 'Cycle Scenes':
                this._cycleScene(roomKey, roomGroup);
                break;
            case 'Multi-Room Scene':
                this._multiRoomOn(sw);
                break;
            default:
                break;
        }
    }

    _minBrightness255(sw) {
        const pct = Number(sw.min_brightness_pct);
        const p = Number.isFinite(pct) ? pct : 20;
        return Math.max(1, Math.min(255, Math.round((p / 100) * 255)));
    }

    _brightnessStep255(sw) {
        const pct = Number(sw.brightness_step_pct);
        const p = Number.isFinite(pct) ? pct : 20;
        return Math.max(1, Math.min(255, Math.round((p / 100) * 255)));
    }

    _brightnessStep(roomGroup, sw, sign) {
        const step = this._brightnessStep255(sw);
        const delta = sign * step;
        this._sendCommand(`${roomGroup}/set`, { brightness_step: delta });
        const rk = sw.room_key;
        if (rk) {
            this.runtime.manualOverride[rk] = true;
            this._saveRuntime();
        }
    }

    _brightnessSet(roomGroup, roomKey, brightness) {
        this._sendCommand(`${roomGroup}/set`, { state: 'ON', brightness });
        if (roomKey) {
            this.runtime.manualOverride[roomKey] = true;
            this._saveRuntime();
        }
    }

    _roomAnyOn(roomDisplayName) {
        // Prefer group-level state (single lookup, always up to date after any
        // command to the group). Fall back to per-device check so early-startup
        // calls (before the group topic is published) still work.
        if (this._deviceStateCache[roomDisplayName] !== undefined) {
            const result = this._deviceStateCache[roomDisplayName] === 'ON';
            this.logger.info(`[SL] _roomAnyOn ${roomDisplayName}: group=${this._deviceStateCache[roomDisplayName]} → ${result}`);
            return result;
        }
        const roomConfig = this.config && this.config.rooms ? this.config.rooms[roomDisplayName] : null;
        if (!roomConfig) {
            this.logger.info(`[SL] _roomAnyOn ${roomDisplayName}: no roomConfig → false`);
            return false;
        }
        const onDevices = (roomConfig.lights || []).filter(l => this._deviceStateCache[l] === 'ON');
        const result = onDevices.length > 0;
        this.logger.info(`[SL] _roomAnyOn ${roomDisplayName}: per-device cache=${JSON.stringify(Object.fromEntries((roomConfig.lights||[]).map(l=>[l,this._deviceStateCache[l]??'?'])))} onDevices=[${onDevices.join(',')}] → ${result}`);
        return result;
    }

    _toggleRoomDefault(sw) {
        const roomKey = sw.room_key;
        const roomGroup = sw.room_group;
        const multi = Array.isArray(sw.multi_room_groups) ? sw.multi_room_groups : [];
        const targets = multi.length > 0 ? multi : [roomGroup];
        // Use _desiredState (what we last commanded) rather than _deviceStateCache.
        // The Zigbee binding fires "on" to the group when B1 is pressed, which can
        // update the MQTT state cache before the action message arrives, flipping the
        // toggle the wrong way. _desiredState is only written by our own commands.
        const anyOn = targets.some(g =>
            g in this._desiredState ? this._desiredState[g] === 'ON' : this._roomAnyOn(g)
        );
        this.logger.info(`[SL] toggle ${roomGroup}: desired=${this._desiredState[roomGroup] ?? 'unknown'} anyOn=${anyOn} → ${anyOn ? 'OFF' : 'ON'}`);
        if (anyOn) {
            for (const g of targets) {
                const rk = GROUP_TO_ROOM_KEY[g] || roomKey;
                this._roomOff(rk, g);
            }
        } else {
            for (const g of targets) {
                const rk = GROUP_TO_ROOM_KEY[g] || roomKey;
                this._roomOn(rk, g);
            }
        }
    }

    _toggleRoom(roomKey, roomGroup) {
        if (this._roomAnyOn(roomGroup)) this._roomOff(roomKey, roomGroup);
        else this._roomOn(roomKey, roomGroup);
    }

    _roomOff(roomKey, roomGroup) {
        this.logger.info(`[SL] room_off ${roomGroup}`);
        this._desiredState[roomGroup] = 'OFF';
        if (roomKey && this._roomOnReinforceTimers[roomKey]) {
            clearTimeout(this._roomOnReinforceTimers[roomKey]);
            delete this._roomOnReinforceTimers[roomKey];
        }
        this._sendCommand(`${roomGroup}/set`, { state: 'OFF' });
        if (roomKey) {
            this.runtime.manualOverride[roomKey] = false;
            this.runtime.cycleLast[roomKey] = '';
            this._saveRuntime();
        }
    }

    /** @returns {object | null} */
    _buildDirectScenePayload(windowKey, roomConfig) {
        const scene = roomConfig.scenes && roomConfig.scenes[windowKey];
        if (!scene) return null;
        const cmd = { state: 'ON', brightness: scene.brightness };
        if (scene.color) cmd.color = scene.color;
        else if (scene.color_temp !== undefined) cmd.color_temp = scene.color_temp;
        const secs = Number(roomConfig.transition_secs) > 0 ? Number(roomConfig.transition_secs) : 0;
        if (secs > 0) cmd.transition = secs;
        return cmd;
    }

    _scheduleRoomOnReinforce(roomKey, roomDisplayName, effectiveWindow, roomConfig) {
        const prev = this._roomOnReinforceTimers[roomKey];
        if (prev) clearTimeout(prev);
        // Capture payload now so the closure doesn't need roomConfig to be stable.
        const payload = this._buildDirectScenePayload(effectiveWindow, roomConfig);
        if (!payload) return;
        this._roomOnReinforceTimers[roomKey] = setTimeout(() => {
            delete this._roomOnReinforceTimers[roomKey];
            if (!this.config || !this.config.rooms) return;
            if (this.runtime.manualOverride[roomKey]) return;
            this.logger.info(`[SL] room_on reinforce (post-dimmer-bind) ${roomDisplayName}`);
            this._sendCommand(`${roomDisplayName}/set`, payload);
        }, ROOM_ON_REINFORCE_MS);
    }

    _powerOffAll() {
        if (!this.config || !this.config.rooms) return;
        for (const rk of Object.keys(ROOM_KEY_TO_GROUP)) {
            const g = ROOM_KEY_TO_GROUP[rk];
            if (this.config.rooms[g]) this._roomOff(rk, g);
        }
    }

    _roomOn(roomKey, roomDisplayName) {
        if (!this.config || !this.config.rooms) return;
        if (this.config.sl_enabled === false) {
            this.logger.info('[SL] room_on skipped (sl_enabled off)');
            return;
        }
        // Safety net: if HA (or anything else) turned the room fully OFF, an old
        // manualOverride from a prior brightness step should not block this on.
        if (this.runtime.manualOverride[roomKey] && !this._roomAnyOn(roomDisplayName)) {
            this.logger.info(`[SL] clearing stale manualOverride for ${roomKey} (group is OFF)`);
            this.runtime.manualOverride[roomKey] = false;
            this._saveRuntime();
        }
        if (this.runtime.manualOverride[roomKey]) {
            this.logger.info(`[SL] room_on skipped (manual override) ${roomKey}`);
            return;
        }
        const roomConfig = this.config.rooms[roomDisplayName];
        if (!roomConfig) return;

        const hm = this.config.house_mode || 'Home';
        if (hm === 'Away') {
            this._sendCommand(`${roomDisplayName}/set`, { state: 'OFF' });
            return;
        }
        if (hm === 'Sleep' && !roomConfig.motion_night) {
            this.logger.info(`[SL] room_on skipped (Sleep, motion_night off) ${roomKey}`);
            return;
        }

        const effectiveWindow = this._getEffectiveWindow(roomDisplayName);
        const payload = this._buildDirectScenePayload(effectiveWindow, roomConfig);
        if (!payload) return;
        this.logger.info(`[SL] room_on ${roomDisplayName} → ${effectiveWindow}`);
        this._desiredState[roomDisplayName] = 'ON';
        this._sendCommand(`${roomDisplayName}/set`, payload);
        this._scheduleRoomOnReinforce(roomKey, roomDisplayName, effectiveWindow, roomConfig);
    }

    _multiRoomOn(sw) {
        const groups = Array.isArray(sw.multi_room_groups) ? sw.multi_room_groups : [];
        for (const g of groups) {
            const rk = GROUP_TO_ROOM_KEY[g];
            if (rk) this._roomOn(rk, g);
        }
    }

    _cycleScene(roomKey, roomDisplayName) {
        if (!this.config || !this.config.rooms) return;
        const roomConfig = this.config.rooms[roomDisplayName];
        if (!roomConfig || !roomConfig.scenes) return;

        const last = this.runtime.cycleLast[roomKey] || '';
        let targetWindow;
        const cw = this._calculateCurrentWindow();
        if (!last || !WINDOWS.includes(last)) {
            targetWindow = WINDOWS.includes(cw) ? cw : 'morning';
        } else {
            targetWindow = WINDOWS[(WINDOWS.indexOf(last) + 1) % 4];
        }
        const payload = this._buildDirectScenePayload(targetWindow, roomConfig);
        if (!payload) return;
        this._sendCommand(`${roomDisplayName}/set`, payload);

        this.runtime.cycleLast[roomKey] = targetWindow;
        this._saveRuntime();
    }

    // ── Full scene push (startup + config change) ────────────
    // Stores ALL 4 scenes on every group so scene_recall works for any window.
    // Does NOT touch hue_power_on_* — script.set_bulb_defaults in HA is the
    // sole authority on firmware defaults (wall-switch power-on behavior).
    // Does NOT scene_recall here (avoids visible snap-back after config push).

    async _fullScenePush() {
        if (!this.config || !this.config.rooms) return;

        this.logger.info(`[SL] Full scene push — storing all 4 scenes on all groups, current window: ${this.currentWindow}`);
        const commands = [];

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            if (!roomConfig.scenes) continue;

            // Store all 4 window scenes on the group
            for (const window of WINDOWS) {
                const scene = roomConfig.scenes[window];
                if (!scene) continue;

                const sceneAdd = {
                    ID: WINDOW_SCENE_ID[window],
                    name: window,
                    transition: 2,
                    brightness: scene.brightness,
                };
                if (scene.color) {
                    sceneAdd.color = scene.color;
                } else if (scene.color_temp !== undefined) {
                    sceneAdd.color_temp = scene.color_temp;
                }
                commands.push({ topic: `${roomName}/set`, payload: { scene_add: sceneAdd } });
            }
        }

        this.logger.info(`[SL] Sending ${commands.length} commands (staggered ${CMD_STAGGER}ms)`);
        await this._sendCommandsStaggered(commands);

        this.lastSyncTime = new Date().toISOString();
        this._publishStatus(`synced`);
    }

    // ── Window transition ────────────────────────────────────
    // Recalls the new window's scene on rooms with lights currently on (if
    // auto_transition). Does NOT touch hue_power_on_* — see set_bulb_defaults.
    // All 4 scenes are already stored from the full push.

    _checkWindowTransition() {
        if (!this.config) return;
        const newWindow = this._calculateCurrentWindow();
        if (newWindow && newWindow !== this.currentWindow) {
            this.logger.info(`[SL] Window transition: ${this.currentWindow} → ${newWindow}`);
            this.currentWindow = newWindow;
            this._onWindowTransition(newWindow);
        }
    }

    async _onWindowTransition(window) {
        if (!this.config || !this.config.rooms) return;

        this.logger.info(`[SL] Window transition → ${window}`);

        // Recall new scene on groups with lights currently on
        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            const effectiveWindow = this._getEffectiveWindow(roomName);
            this._recallSceneIfOn(roomName, roomConfig, effectiveWindow);
        }

        this._publishStatus(`window_${window}`);
    }

    _recallSceneIfOn(roomName, roomConfig, window) {
        if (roomConfig.auto_transition === false) {
            this.logger.info(`[SL] Recall skipped for ${roomName} (auto_transition off)`);
            return;
        }
        if (!this._roomAnyOn(roomName)) return;
        const payload = this._buildDirectScenePayload(window, roomConfig);
        if (!payload) return;
        const secs = payload.transition ?? 'default';
        this.logger.info(`[SL] Recalling ${window} scene on ${roomName} (lights on, transition=${secs})`);
        this._sendCommand(`${roomName}/set`, payload);
    }

    _onDeviceAnnounce(friendlyName) {
        if (Date.now() < this._smartPowerOnReadyAt) return;
        if (!this.config || !this.config.rooms) return;
        if (this.config.sl_enabled === false) return;
        const hm = this.config.house_mode || 'Home';
        if (hm === 'Away') return;

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            if (!roomConfig.smart_power_on) continue;
            if (!(roomConfig.lights || []).includes(friendlyName)) continue;
            if (hm === 'Sleep' && !roomConfig.motion_night) {
                this.logger.info(`[SL] smart_power_on: ${friendlyName} skipped (Sleep, motion_night off)`);
                return;
            }
            const effectiveWindow = this._getEffectiveWindow(roomName);
            const scene = roomConfig.scenes && roomConfig.scenes[effectiveWindow];
            if (!scene) return;

            // Send direct state command to the individual device so this path
            // does not depend on Zigbee scenes having been stored via scene_add.
            const cmd = { state: 'ON', brightness: scene.brightness };
            if (scene.color) cmd.color = scene.color;
            else if (scene.color_temp !== undefined) cmd.color_temp = scene.color_temp;

            this.logger.info(`[SL] smart_power_on: ${friendlyName} announced → ${effectiveWindow} (${roomName})`);
            // 2 s delay: let the bulb finish its rejoin handshake before commanding it.
            setTimeout(() => this._sendCommand(`${friendlyName}/set`, cmd), 2000);
            return;
        }
    }

    // ── Schedule calculation ─────────────────────────────────

    _calculateCurrentWindow() {
        if (!this.config || !this.config.profiles || !this.config.day_assignments) return null;
        const now = new Date();
        const dayName = DAY_NAMES[now.getDay()];
        const profileName = this.config.day_assignments[dayName] || 'weekday';
        const profile = this.config.profiles[profileName];
        if (!profile) return 'morning';
        const t = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
        if (t >= profile.night) return 'night';
        if (t >= profile.evening) return 'evening';
        if (t >= profile.day) return 'day';
        if (t >= profile.morning) return 'morning';
        return 'night';
    }

    _getEffectiveWindow(roomName) {
        if (!this.config || !this.config.profiles || !this.config.day_assignments) return this.currentWindow;
        const now = new Date();
        const dayName = DAY_NAMES[now.getDay()];
        const profileName = this.config.day_assignments[dayName] || 'weekday';
        const profile = { ...this.config.profiles[profileName] };
        const roomConfig = this.config.rooms[roomName];
        if (roomConfig && roomConfig.overrides) {
            for (const [w, time] of Object.entries(roomConfig.overrides)) {
                profile[w] = time;
            }
        }
        const t = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
        if (t >= profile.night) return 'night';
        if (t >= profile.evening) return 'evening';
        if (t >= profile.day) return 'day';
        if (t >= profile.morning) return 'morning';
        return 'night';
    }

    // ── Helpers ──────────────────────────────────────────────

    _loadCache() {
        try { return JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8')); }
        catch { return null; }
    }

    _saveCache(config) {
        try { fs.writeFileSync(CACHE_FILE, JSON.stringify(config, null, 2)); }
        catch (e) { this.logger.error(`[SL] Failed to save cache: ${e.message}`); }
    }

    _loadRuntime() {
        try {
            const raw = JSON.parse(fs.readFileSync(RUNTIME_FILE, 'utf8'));
            return {
                manualOverride: raw.manualOverride || {},
                cycleLast: raw.cycleLast || {},
            };
        } catch {
            return { manualOverride: {}, cycleLast: {} };
        }
    }

    _saveRuntime() {
        try {
            fs.writeFileSync(RUNTIME_FILE, JSON.stringify(this.runtime, null, 2));
        } catch (e) {
            this.logger.error(`[SL] Failed to save runtime: ${e.message}`);
        }
    }

    _hashConfig(config) {
        return crypto.createHash('sha256').update(JSON.stringify(config)).digest('hex').substring(0, 12);
    }

    _publishStatus(status) {
        const payload = JSON.stringify({
            status,
            current_window: this.currentWindow,
            has_config: !!this.config,
            config_hash: this.configHash,
            last_sync: this.lastSyncTime,
            timestamp: new Date().toISOString(),
        });
        if (this.cmdClient && this.cmdClient.connected) {
            this.cmdClient.publish(STATUS_TOPIC, payload, { retain: true });
        }
    }
}

module.exports = SmartLighting;
