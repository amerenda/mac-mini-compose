const fs = require('fs');
const path = require('path');
const mqtt = require('mqtt');

const CACHE_FILE = path.join(__dirname, 'sl-cache.json');
const CONFIG_TOPIC = 'zigbee2mqtt/sl/config';
const STATUS_TOPIC = 'zigbee2mqtt/sl/status';
const BASE_TOPIC = 'zigbee2mqtt';

// Zigbee scene IDs: morning=1, day=2, evening=3, night=4
const WINDOW_SCENE_ID = { morning: 1, day: 2, evening: 3, night: 4 };
const WINDOWS = ['morning', 'day', 'evening', 'night'];
const DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

class SmartLighting {
    constructor(zigbee, mqtt, state, publishEntityState, eventBus, enableDisableExtension, restartCallback, addExtension, settings, logger) {
        this.zigbee = zigbee;
        this.z2mMqtt = mqtt;
        this.state = state;
        this.eventBus = eventBus;
        this.settings = settings;
        this.logger = logger;
        this.config = null;
        this.currentWindow = null;
        this.checkInterval = null;
        this.cmdClient = null; // Separate MQTT client for sending commands
    }

    async start() {
        this.logger.info('[SL] Smart Lighting extension starting');

        // Create a separate MQTT client for sending commands to Z2M
        // Z2M ignores messages from its own client, so we need a separate connection
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

        // Load cached config from disk
        this.config = this._loadCache();
        if (this.config) {
            this.logger.info('[SL] Loaded cached config from disk');
            this.currentWindow = this._calculateCurrentWindow();
            this.logger.info(`[SL] Current window: ${this.currentWindow}`);
        } else {
            this.logger.info('[SL] No cached config found, waiting for HA to push config');
        }

        // Subscribe to config topic from HA (via Z2M's MQTT)
        await this.z2mMqtt.subscribe(CONFIG_TOPIC);
        this.logger.info(`[SL] Subscribed to ${CONFIG_TOPIC}`);

        // Listen for MQTT messages (config updates from HA)
        this.eventBus.onMQTTMessage(this, this._onMQTTMessage.bind(this));

        // Listen for device announce (bulb power-on)
        this.eventBus.onDeviceAnnounce(this, this._onDeviceAnnounce.bind(this));

        // Check for window transitions every 30 seconds
        this.checkInterval = setInterval(() => this._checkWindowTransition(), 30000);

        // Initial scene push if we have config
        if (this.config && this.currentWindow) {
            setTimeout(() => this._onWindowTransition(this.currentWindow), 5000);
        }

        this._publishStatus('started');
    }

    async stop() {
        this.logger.info('[SL] Smart Lighting extension stopping');
        if (this.checkInterval) {
            clearInterval(this.checkInterval);
            this.checkInterval = null;
        }
        if (this.cmdClient) {
            this.cmdClient.end();
            this.cmdClient = null;
        }
        this.eventBus.removeListeners(this);
    }

    // ── Send command via external MQTT client ────────────────

    _sendCommand(topic, payload) {
        const fullTopic = `${BASE_TOPIC}/${topic}`;
        const message = typeof payload === 'string' ? payload : JSON.stringify(payload);
        if (this.cmdClient && this.cmdClient.connected) {
            this.cmdClient.publish(fullTopic, message);
            this.logger.debug(`[SL] CMD → ${fullTopic}: ${message}`);
        } else {
            this.logger.warn(`[SL] CMD client not connected, dropping: ${fullTopic}`);
        }
    }

    // ── MQTT config from HA ──────────────────────────────────

    _onMQTTMessage(data) {
        if (data.topic !== CONFIG_TOPIC) return;

        try {
            const newConfig = JSON.parse(data.message);
            this.config = newConfig;
            this._saveCache(newConfig);
            this.logger.info('[SL] Received and cached new config from HA');

            const window = this._calculateCurrentWindow();
            this.currentWindow = window;
            this._onWindowTransition(window);
            this._publishStatus('config_updated');
        } catch (e) {
            this.logger.error(`[SL] Failed to parse config: ${e.message}`);
        }
    }

    // ── Device announce (bulb powered on) ────────────────────

    _onDeviceAnnounce(data) {
        if (!this.config || !this.currentWindow) return;

        const device = data.device;
        if (!device || !device.zh || !device.zh.interviewCompleted) return;

        const friendlyName = device.name;
        const room = this._findRoomForDevice(friendlyName);
        if (!room) return;

        const scene = this._getSceneForRoom(room, this.currentWindow);
        if (!scene) return;

        this.logger.info(`[SL] Device announce: ${friendlyName} (${room}) → applying ${this.currentWindow} scene`);

        // Delay to let the device fully initialize after power-on
        setTimeout(() => {
            const payload = { state: 'ON', brightness: scene.brightness };
            if (scene.color_temp !== undefined) {
                payload.color_temp = scene.color_temp;
            }
            this._sendCommand(`${friendlyName}/set`, payload);
        }, 500);
    }

    // ── Window transition check ──────────────────────────────

    _checkWindowTransition() {
        if (!this.config) return;

        const newWindow = this._calculateCurrentWindow();
        if (newWindow && newWindow !== this.currentWindow) {
            this.logger.info(`[SL] Window transition: ${this.currentWindow} → ${newWindow}`);
            this.currentWindow = newWindow;
            this._onWindowTransition(newWindow);
        }
    }

    _onWindowTransition(window) {
        if (!this.config || !this.config.rooms) return;

        this.logger.info(`[SL] Applying window: ${window}`);

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            const effectiveWindow = this._getEffectiveWindow(roomName);
            const scene = roomConfig.scenes ? roomConfig.scenes[effectiveWindow] : null;
            if (!scene) continue;

            // Store scene on the Z2M group via external MQTT
            const scenePayload = {
                scene_add: {
                    ID: WINDOW_SCENE_ID[effectiveWindow],
                    name: effectiveWindow,
                    transition: 2,
                    brightness: scene.brightness,
                }
            };
            if (scene.color_temp !== undefined) {
                scenePayload.scene_add.color_temp = scene.color_temp;
            }
            this._sendCommand(`${roomName}/set`, scenePayload);

            // Update hue_power_on_* on each bulb for wall switch scenario
            const lights = roomConfig.lights || [];
            for (const light of lights) {
                this._sendCommand(`${light}/set`, {
                    hue_power_on_behavior: 'on',
                    hue_power_on_brightness: 1,
                    hue_power_on_color_temperature: scene.color_temp || 500,
                });
            }

            // If lights in this group are currently on, recall the new scene
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
            this.logger.info(`[SL] Recalling ${window} scene on ${roomName} (lights are on)`);
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

        const currentTime = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;

        if (currentTime >= profile.night) return 'night';
        if (currentTime >= profile.evening) return 'evening';
        if (currentTime >= profile.day) return 'day';
        if (currentTime >= profile.morning) return 'morning';
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
            for (const [windowName, time] of Object.entries(roomConfig.overrides)) {
                profile[windowName] = time;
            }
        }

        const currentTime = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;

        if (currentTime >= profile.night) return 'night';
        if (currentTime >= profile.evening) return 'evening';
        if (currentTime >= profile.day) return 'day';
        if (currentTime >= profile.morning) return 'morning';
        return 'night';
    }

    // ── Helpers ──────────────────────────────────────────────

    _findRoomForDevice(friendlyName) {
        if (!this.config || !this.config.rooms) return null;
        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            if (roomConfig.lights && roomConfig.lights.includes(friendlyName)) {
                return roomName;
            }
        }
        return null;
    }

    _getSceneForRoom(roomName, window) {
        const effectiveWindow = this._getEffectiveWindow(roomName);
        const roomConfig = this.config.rooms[roomName];
        if (!roomConfig || !roomConfig.scenes) return null;
        return roomConfig.scenes[effectiveWindow] || null;
    }

    _loadCache() {
        try {
            const data = fs.readFileSync(CACHE_FILE, 'utf8');
            return JSON.parse(data);
        } catch {
            return null;
        }
    }

    _saveCache(config) {
        try {
            fs.writeFileSync(CACHE_FILE, JSON.stringify(config, null, 2));
        } catch (e) {
            this.logger.error(`[SL] Failed to save cache: ${e.message}`);
        }
    }

    _publishStatus(status) {
        const payload = {
            status,
            current_window: this.currentWindow,
            has_config: !!this.config,
            timestamp: new Date().toISOString(),
        };
        // Status goes through Z2M's MQTT (for logging), not the command client
        this.z2mMqtt.publish(STATUS_TOPIC, JSON.stringify(payload), undefined, undefined, false, false);
    }
}

module.exports = SmartLighting;
