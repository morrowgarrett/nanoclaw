/**
 * Mattermost channel for NanoClaw.
 * Connects via WebSocket for real-time messages, REST API for sending.
 * Uses login-based auth with session token (refreshed periodically).
 */
import WebSocket from 'ws';

import { ASSISTANT_NAME } from '../config.js';
import { readEnvFile } from '../env.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import {
  Channel,
  OnChatMetadata,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

interface MattermostChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
}

interface MattermostUser {
  id: string;
  username: string;
  first_name: string;
  last_name: string;
}

export class MattermostChannel implements Channel {
  name = 'mattermost';

  private serverUrl: string;
  private loginId: string;
  private password: string;
  private token: string = '';
  private userId: string = '';
  private ws: WebSocket | null = null;
  private opts: MattermostChannelOpts;
  private connected = false;
  private wsSeq = 1;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private userCache = new Map<string, MattermostUser>();

  constructor(
    serverUrl: string,
    loginId: string,
    password: string,
    opts: MattermostChannelOpts,
  ) {
    this.serverUrl = serverUrl.replace(/\/$/, '');
    this.loginId = loginId;
    this.password = password;
    this.opts = opts;
  }

  private api(path: string, options: RequestInit = {}): Promise<Response> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      ...(options.headers as Record<string, string> || {}),
    };
    return fetch(`${this.serverUrl}/api/v4${path}`, { ...options, headers });
  }

  private async login(): Promise<void> {
    const resp = await this.api('/users/login', {
      method: 'POST',
      body: JSON.stringify({ login_id: this.loginId, password: this.password }),
    });

    if (!resp.ok) {
      const err = await resp.text();
      throw new Error(`Mattermost login failed: ${resp.status} ${err}`);
    }

    this.token = resp.headers.get('token') || '';
    const user = (await resp.json()) as MattermostUser;
    this.userId = user.id;

    logger.info(
      { username: user.username, userId: user.id },
      'Mattermost logged in',
    );
  }

  /** Refresh session token. Called periodically to prevent expiry. */
  async refreshToken(): Promise<void> {
    try {
      await this.login();
      logger.info('Mattermost token refreshed');
    } catch (err) {
      logger.error(
        { err: err instanceof Error ? err.message : String(err) },
        'Mattermost token refresh failed',
      );
    }
  }

  private async getUser(userId: string): Promise<MattermostUser> {
    const cached = this.userCache.get(userId);
    if (cached) return cached;

    try {
      const resp = await this.api(`/users/${userId}`);
      if (resp.ok) {
        const user = (await resp.json()) as MattermostUser;
        this.userCache.set(userId, user);
        return user;
      }
    } catch { /* fall through */ }

    return { id: userId, username: 'unknown', first_name: 'Unknown', last_name: '' };
  }

  private async getChannelName(channelId: string): Promise<string> {
    try {
      const resp = await this.api(`/channels/${channelId}`);
      if (resp.ok) {
        const ch = (await resp.json()) as { display_name: string; name: string; type: string };
        if (ch.type === 'D') return 'DM';
        if (ch.type === 'G') return 'Group DM';
        return ch.display_name || ch.name;
      }
    } catch { /* fall through */ }
    return 'unknown';
  }

  private connectWebSocket(): void {
    const wsUrl = this.serverUrl.replace(/^https/, 'wss').replace(/^http/, 'ws');
    this.ws = new WebSocket(`${wsUrl}/api/v4/websocket`);

    this.ws.on('open', () => {
      // Authenticate the WebSocket connection
      this.ws!.send(JSON.stringify({
        seq: this.wsSeq++,
        action: 'authentication_challenge',
        data: { token: this.token },
      }));
      this.connected = true;
      logger.info('Mattermost WebSocket connected');
    });

    this.ws.on('message', async (data: WebSocket.Data) => {
      try {
        const event = JSON.parse(data.toString());
        if (event.event === 'posted') {
          await this.handlePosted(event);
        }
      } catch (err) {
        logger.debug({ err }, 'Mattermost WS message parse error');
      }
    });

    this.ws.on('close', (code) => {
      this.connected = false;
      logger.warn({ code }, 'Mattermost WebSocket closed');
      this.scheduleReconnect();
    });

    this.ws.on('error', (err) => {
      logger.error({ err: err.message }, 'Mattermost WebSocket error');
    });
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = null;
      try {
        logger.info('Mattermost reconnecting...');
        await this.login();
        this.connectWebSocket();
      } catch (err) {
        logger.error({ err }, 'Mattermost reconnect failed');
        this.scheduleReconnect();
      }
    }, 5000);
  }

  private async handlePosted(event: any): Promise<void> {
    const post = JSON.parse(event.data?.post || '{}');
    if (!post.id || !post.channel_id || !post.message) return;

    // Skip own messages
    if (post.user_id === this.userId) return;

    const chatJid = `mm:${post.channel_id}`;
    const group = this.opts.registeredGroups()[chatJid];
    if (!group) return;

    const user = await this.getUser(post.user_id);
    const senderName = user.first_name || user.username || 'Unknown';
    const timestamp = new Date(post.create_at).toISOString();

    const channelName = await this.getChannelName(post.channel_id);
    const channelType = event.data?.channel_type;
    const isGroup = channelType !== 'D';

    this.opts.onChatMetadata(
      chatJid,
      timestamp,
      channelName,
      'mattermost',
      isGroup,
    );

    this.opts.onMessage(chatJid, {
      id: post.id,
      chat_jid: chatJid,
      sender: post.user_id,
      sender_name: senderName,
      content: post.message,
      timestamp,
      is_from_me: false,
    });

    logger.info(
      { chatJid, channelName, sender: senderName },
      'Mattermost message stored',
    );
  }

  async connect(): Promise<void> {
    await this.login();
    this.connectWebSocket();

    // Refresh token every 6 hours
    setInterval(() => this.refreshToken(), 6 * 60 * 60 * 1000);

    console.log(`\n  Mattermost: ${this.serverUrl}`);
    console.log(`  User: ${this.loginId}\n`);
  }

  async sendMessage(jid: string, text: string): Promise<void> {
    const channelId = jid.replace(/^mm:/, '');
    const MAX_LENGTH = 16383; // Mattermost max post length

    try {
      if (text.length <= MAX_LENGTH) {
        const resp = await this.api('/posts', {
          method: 'POST',
          body: JSON.stringify({ channel_id: channelId, message: text }),
        });
        if (!resp.ok) {
          const err = await resp.text();
          logger.error({ channelId, status: resp.status, err }, 'Mattermost send failed');
          return;
        }
      } else {
        // Split long messages
        for (let i = 0; i < text.length; i += MAX_LENGTH) {
          await this.api('/posts', {
            method: 'POST',
            body: JSON.stringify({ channel_id: channelId, message: text.slice(i, i + MAX_LENGTH) }),
          });
        }
      }
      logger.info({ jid, length: text.length }, 'Mattermost message sent');
    } catch (err) {
      logger.error(
        { jid, err: err instanceof Error ? err.message : String(err) },
        'Mattermost send error',
      );
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  ownsJid(jid: string): boolean {
    return jid.startsWith('mm:');
  }

  async disconnect(): Promise<void> {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.connected = false;
    logger.info('Mattermost disconnected');
  }

  async setTyping(jid: string, _isTyping: boolean): Promise<void> {
    if (!this.connected) return;
    try {
      const channelId = jid.replace(/^mm:/, '');
      this.ws?.send(JSON.stringify({
        action: 'user_typing',
        seq: this.wsSeq++,
        data: { channel_id: channelId, parent_id: '' },
      }));
    } catch { /* ignore */ }
  }
}

registerChannel('mattermost', (opts: ChannelOpts) => {
  const envVars = readEnvFile([
    'MATTERMOST_URL',
    'MATTERMOST_USERNAME',
    'MATTERMOST_PASSWORD',
  ]);
  const url = process.env.MATTERMOST_URL || envVars.MATTERMOST_URL || '';
  const username = process.env.MATTERMOST_USERNAME || envVars.MATTERMOST_USERNAME || '';
  const password = process.env.MATTERMOST_PASSWORD || envVars.MATTERMOST_PASSWORD || '';

  if (!url || !username || !password) {
    logger.debug('Mattermost: credentials not configured, skipping');
    return null;
  }

  return new MattermostChannel(url, username, password, opts);
});
