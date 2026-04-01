/**
 * Credential proxy for container isolation.
 * Containers connect here instead of directly to the Anthropic API.
 * The proxy injects real credentials so containers never see them.
 *
 * Three auth modes:
 *   api-key:  Proxy injects x-api-key on every request.
 *   oauth:    Proxy injects Bearer token + oauth beta header on every
 *             request, matching how OpenClaw handles OAuth tokens.
 *             The oat token does not actually expire server-side, so
 *             no refresh is needed.
 *   legacy:   Reads from ~/.claude/.credentials.json (fallback).
 */
import { createServer, Server } from 'http';
import { readFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { request as httpsRequest } from 'https';
import { request as httpRequest, RequestOptions } from 'http';

import { readEnvFile } from './env.js';
import { logger } from './logger.js';

export type AuthMode = 'api-key' | 'oauth';

export interface ProxyConfig {
  authMode: AuthMode;
}

/** Required beta header for OAuth token auth on the Anthropic API. */
const OAUTH_BETA = 'oauth-2025-04-20';

/**
 * Read the current OAuth access token from Claude Code's credentials file.
 * Returns null if the file doesn't exist or can't be parsed.
 */
function readClaudeCredentialsToken(): string | null {
  try {
    const credPath = join(homedir(), '.claude', '.credentials.json');
    const data = JSON.parse(readFileSync(credPath, 'utf-8'));
    const token = data?.claudeAiOauth?.accessToken;
    if (typeof token === 'string' && token.length > 0) return token;
  } catch {
    // File missing or malformed — fall through
  }
  return null;
}

/**
 * Append a beta flag to the anthropic-beta header if not already present.
 */
function ensureBeta(
  headers: Record<string, string | number | string[] | undefined>,
  beta: string,
): void {
  const existing = (headers['anthropic-beta'] as string) || '';
  const betas = existing ? existing.split(',').map((b) => b.trim()) : [];
  if (!betas.includes(beta)) {
    betas.push(beta);
  }
  headers['anthropic-beta'] = betas.join(',');
}

/**
 * Credential pool with round-robin and cooldown support (#10).
 * Supports multiple OAuth tokens via comma-separated CLAUDE_CODE_OAUTH_TOKEN.
 */
interface CredentialEntry {
  token: string;
  cooldownUntil: number;
  errorCount: number;
}

class CredentialPool {
  private entries: CredentialEntry[] = [];
  private index = 0;

  constructor(tokens: string[]) {
    this.entries = tokens.map((t) => ({
      token: t.trim(),
      cooldownUntil: 0,
      errorCount: 0,
    }));
  }

  get size(): number {
    return this.entries.length;
  }

  /** Get next available token (round-robin, skipping cooled-down entries). */
  getToken(): string | undefined {
    if (this.entries.length === 0) return undefined;
    const now = Date.now();
    for (let i = 0; i < this.entries.length; i++) {
      const idx = (this.index + i) % this.entries.length;
      const entry = this.entries[idx];
      if (entry.cooldownUntil <= now) {
        this.index = (idx + 1) % this.entries.length;
        return entry.token;
      }
    }
    // All on cooldown — use the one with earliest expiry
    const earliest = this.entries.reduce((a, b) =>
      a.cooldownUntil < b.cooldownUntil ? a : b,
    );
    return earliest.token;
  }

  /** Mark a token as having an error (rate limit, auth failure). */
  markError(token: string, cooldownMs = 60_000): void {
    const entry = this.entries.find((e) => e.token === token);
    if (entry) {
      entry.errorCount++;
      entry.cooldownUntil = Date.now() + cooldownMs;
      logger.warn(
        { errorCount: entry.errorCount, cooldownMs },
        'Credential marked with cooldown',
      );
    }
  }
}

export function startCredentialProxy(
  port: number,
  host = '127.0.0.1',
): Promise<Server> {
  const secrets = readEnvFile([
    'ANTHROPIC_API_KEY',
    'CLAUDE_CODE_OAUTH_TOKEN',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
  ]);

  // Build credential pool from comma-separated tokens
  const tokenStr =
    secrets.CLAUDE_CODE_OAUTH_TOKEN || secrets.ANTHROPIC_AUTH_TOKEN || '';
  const tokenList = tokenStr
    .split(',')
    .map((t) => t.trim())
    .filter(Boolean);
  const pool = new CredentialPool(tokenList);
  const authMode: AuthMode = secrets.ANTHROPIC_API_KEY ? 'api-key' : 'oauth';

  function getOauthToken(): string | undefined {
    return pool.getToken() || readClaudeCredentialsToken() || undefined;
  }

  const upstreamUrl = new URL(
    secrets.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
  );
  const isHttps = upstreamUrl.protocol === 'https:';
  const makeRequest = isHttps ? httpsRequest : httpRequest;

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks);
        const headers: Record<string, string | number | string[] | undefined> =
          {
            ...(req.headers as Record<string, string>),
            host: upstreamUrl.host,
            'content-length': body.length,
          };

        // Strip hop-by-hop headers that must not be forwarded by proxies
        delete headers['connection'];
        delete headers['keep-alive'];
        delete headers['transfer-encoding'];

        if (authMode === 'api-key') {
          // API key mode: inject x-api-key on every request
          delete headers['x-api-key'];
          headers['x-api-key'] = secrets.ANTHROPIC_API_KEY;
        } else {
          // OAuth mode: unconditionally strip whatever auth the container
          // sends and replace with the real oat token + required beta.
          // This prevents the container's Claude Code from trying its own
          // OAuth exchange flow, which fails through the proxy.
          const token = getOauthToken();
          if (token) {
            delete headers['authorization'];
            delete headers['x-api-key'];
            headers['authorization'] = `Bearer ${token}`;
            ensureBeta(headers, OAUTH_BETA);
          } else {
            logger.warn('OAuth mode but no token available');
          }
        }

        // Track which token was used for error handling
        const usedToken = authMode === 'oauth' ? getOauthToken() : undefined;

        const upstream = makeRequest(
          {
            hostname: upstreamUrl.hostname,
            port: upstreamUrl.port || (isHttps ? 443 : 80),
            path: req.url,
            method: req.method,
            headers,
          } as RequestOptions,
          (upRes) => {
            // On 429 rate limit, cool down the token for 60s
            if (upRes.statusCode === 429 && authMode === 'oauth' && usedToken) {
              pool.markError(usedToken, 60_000);
            }

            // If upstream returns 401 in oauth mode, log and cool down token
            if (upRes.statusCode === 401 && authMode === 'oauth') {
              if (usedToken) pool.markError(usedToken, 3600_000); // 1hr cooldown
              const errChunks: Buffer[] = [];
              upRes.on('data', (c) => errChunks.push(c));
              upRes.on('end', () => {
                const errBody = Buffer.concat(errChunks).toString();
                logger.error(
                  { status: 401, path: req.url, body: errBody.slice(0, 300) },
                  'Credential proxy: upstream 401 — token may need replacement',
                );
                if (!res.headersSent) {
                  res.writeHead(401, upRes.headers);
                  res.end(errBody);
                }
              });
              return;
            }
            res.writeHead(upRes.statusCode!, upRes.headers);
            upRes.pipe(res);
          },
        );

        upstream.on('error', (err) => {
          logger.error(
            { err, url: req.url },
            'Credential proxy upstream error',
          );
          if (!res.headersSent) {
            res.writeHead(502);
            res.end('Bad Gateway');
          }
        });

        upstream.write(body);
        upstream.end();
      });
    });

    server.listen(port, host, () => {
      logger.info(
        { port, host, authMode, hasToken: !!getOauthToken() },
        'Credential proxy started',
      );
      resolve(server);
    });

    server.on('error', reject);
  });
}

/** Detect which auth mode the host is configured for. */
export function detectAuthMode(): AuthMode {
  const secrets = readEnvFile(['ANTHROPIC_API_KEY']);
  return secrets.ANTHROPIC_API_KEY ? 'api-key' : 'oauth';
}
