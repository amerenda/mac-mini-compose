const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const mqtt = require('mqtt');

const CACHE_FILE = path.join(__dirname, 'sl-cache.json');
const CONFIG_TOPIC = 'zigbee2mqtt/sl/config';
const STATUS_TOPIC = 'zigbee2mqtt/sl/status';
const BASE_TOPIC = 'zigbee2mqtt';

// Zigbee scene IDs: morning=1, day=2, evening=3, night=4
const WINDOW_SCENE_ID = { morning: 1, day: 2, evening: 3, night: 4 };
const WINDOWS = ['morning', 'day', 'evening', 'night'];
const DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

// Stagger delay between Zigbee commands (ms) to avoid flooding
const CMD_STAGGER = 200;

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

        await new Promise((resolve, reject) => {
            this.cmdClient.on('connect', () => {
                this.logger.info('[SL] Command MQTT client connected');
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
            this.logger.info(`[SL] Loaded cached config from disk (hash: ${this.configHash})`);
            this.currentWindow = this._calculateCurrentWindow();
            this.logger.info(`[SL] Current window: ${this.currentWindow}`);
        } else {
            this.logger.info('[SL] No cached config, waiting for HA');
        }

        // Subscribe to HA config pushes
        await this.z2mMqtt.subscribe(CONFIG_TOPIC);
        this.logger.info(`[SL] Subscribed to ${CONFIG_TOPIC}`);

        this.eventBus.onMQTTMessage(this, this._onMQTTMessage.bind(this));
        this.eventBus.onDeviceAnnounce(this, this._onDeviceAnnounce.bind(this));

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
        if (this.cmdClient) this.cmdClient.end();
        this.checkInterval = null;
        this.cmdClient = null;
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
        if (data.topic !== CONFIG_TOPIC) return;
        try {
            const newConfig = JSON.parse(data.message);
            this.config = newConfig;
            this.configHash = this._hashConfig(newConfig);
            this._saveCache(newConfig);
            this.logger.info(`[SL] Received and cached new config from HA (hash: ${this.configHash})`);
            this.currentWindow = this._calculateCurrentWindow();
            this._fullScenePush();
            this._publishStatus('config_updated');
        } catch (e) {
            this.logger.error(`[SL] Failed to parse config: ${e.message}`);
        }
    }

    // ── Device announce (bulb powered on after wall switch) ──

    _onDeviceAnnounce(data) {
        if (!this.config || !this.currentWindow) return;
        const device = data.device;
        if (!device || !device.zh || !device.zh.interviewCompleted) return;

        const friendlyName = device.name;
        const room = this._findRoomForDevice(friendlyName);
        if (!room) return;

        const roomConfig = this.config.rooms[room];
        if (!roomConfig) return;

        // Only intervene if smart_power_on is enabled for this room
        // When disabled, the bulb already boots at the correct scene values
        if (!roomConfig.smart_power_on) {
            this.logger.info(`[SL] Device announce: ${friendlyName} (${room}) — smart power-on disabled, skipping`);
            return;
        }

        const scene = this._getSceneForRoom(room);
        if (!scene) return;

        this.logger.info(`[SL] Device announce: ${friendlyName} (${room}) → ${this._getEffectiveWindow(room)} scene`);

        // Delay for device init, then push correct state
        setTimeout(() => {
            const payload = { state: 'ON', brightness: scene.brightness };
            if (scene.color_temp !== undefined) payload.color_temp = scene.color_temp;
            this._sendCommand(`${friendlyName}/set`, payload);
        }, 500);
    }

    // ── Full scene push (startup + config change) ────────────
    // Stores ALL 4 scenes on every group so scene_recall works for any window.
    // Updates hue_power_on_* for current window (wall switch fallback).

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

                const scenePayload = {
                    scene_add: {
                        ID: WINDOW_SCENE_ID[window],
                        name: window,
                        transition: 2,
                        brightness: scene.brightness,
                    }
                };
                if (scene.color_temp !== undefined) {
                    scenePayload.scene_add.color_temp = scene.color_temp;
                }
                commands.push({ topic: `${roomName}/set`, payload: scenePayload });
            }

            // Set hue_power_on_* on each bulb
            const currentScene = this._getSceneForRoom(roomName);
            const smartPowerOn = roomConfig.smart_power_on !== false;
            const lights = roomConfig.lights || [];
            for (const light of lights) {
                commands.push({
                    topic: `${light}/set`,
                    payload: {
                        hue_power_on_behavior: 'on',
                        // Smart: brightness 1 (dark boot, Z2M corrects). Normal: actual scene brightness.
                        hue_power_on_brightness: smartPowerOn ? 1 : (currentScene ? currentScene.brightness : 200),
                        hue_power_on_color_temperature: currentScene ? (currentScene.color_temp || 500) : 500,
                    }
                });
            }
        }

        this.logger.info(`[SL] Sending ${commands.length} commands (staggered ${CMD_STAGGER}ms)`);
        await this._sendCommandsStaggered(commands);

        // Recall current scene on groups with lights on
        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            const effectiveWindow = this._getEffectiveWindow(roomName);
            this._recallSceneIfOn(roomName, roomConfig, effectiveWindow);
        }

        this.lastSyncTime = new Date().toISOString();
        this._publishStatus(`synced`);
    }

    // ── Window transition ────────────────────────────────────
    // Only updates hue_power_on_* and recalls scene on active lights.
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
        const commands = [];

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            const effectiveWindow = this._getEffectiveWindow(roomName);
            const scene = roomConfig.scenes ? roomConfig.scenes[effectiveWindow] : null;
            if (!scene) continue;

            // Update hue_power_on_* for wall switch scenario
            const smartPowerOn = roomConfig.smart_power_on !== false;
            const lights = roomConfig.lights || [];
            for (const light of lights) {
                commands.push({
                    topic: `${light}/set`,
                    payload: {
                        hue_power_on_behavior: 'on',
                        hue_power_on_brightness: smartPowerOn ? 1 : (scene.brightness || 200),
                        hue_power_on_color_temperature: scene.color_temp || 500,
                    }
                });
            }
        }

        await this._sendCommandsStaggered(commands);

        // Recall new scene on groups with lights currently on
        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            const effectiveWindow = this._getEffectiveWindow(roomName);
            this._recallSceneIfOn(roomName, roomConfig, effectiveWindow);
        }

        this._publishStatus(`window_${window}`);
    }

    _recallSceneIfOn(roomName, roomConfig, window) {
        const lights = roomConfig.lights || [];
        const anyOn = lights.some(light => {
            const device = this.zigbee.resolveEntity(light);
            if (!device) return false;
            const deviceState = this.state.get(device);
            return deviceState && deviceState.state === 'ON';
        });
        if (anyOn) {
            this.logger.info(`[SL] Recalling ${window} scene on ${roomName} (lights on)`);
            this._sendCommand(`${roomName}/set`, { scene_recall: WINDOW_SCENE_ID[window] });
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

    _findRoomForDevice(friendlyName) {
        if (!this.config || !this.config.rooms) return null;
        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            if (roomConfig.lights && roomConfig.lights.includes(friendlyName)) return roomName;
        }
        return null;
    }

    _getSceneForRoom(roomName) {
        const effectiveWindow = this._getEffectiveWindow(roomName);
        const roomConfig = this.config.rooms[roomName];
        if (!roomConfig || !roomConfig.scenes) return null;
        return roomConfig.scenes[effectiveWindow] || null;
    }

    _loadCache() {
        try { return JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8')); }
        catch { return null; }
    }

    _saveCache(config) {
        try { fs.writeFileSync(CACHE_FILE, JSON.stringify(config, null, 2)); }
        catch (e) { this.logger.error(`[SL] Failed to save cache: ${e.message}`); }
    }

    _hashConfig(config) {
        return crypto.createHash('sha256').update(JSON.stringify(config)).digest('hex').substring(0, 12);
    }

    _publishStatus(status) {
        this.z2mMqtt.publish(STATUS_TOPIC, JSON.stringify({
            status,
            current_window: this.currentWindow,
            has_config: !!this.config,
            config_hash: this.configHash,
            last_sync: this.lastSyncTime,
            timestamp: new Date().toISOString(),
        }), undefined, undefined, false, false);
    }
}

module.exports = SmartLighting;
