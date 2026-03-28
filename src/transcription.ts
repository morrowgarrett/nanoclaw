/**
 * Voice message transcription via OpenAI Whisper API.
 * Downloads voice messages from Telegram, sends to Whisper, returns text.
 */
import fs from 'fs';
import path from 'path';
import { Api } from 'grammy';
import { logger } from './logger.js';

const WHISPER_API_URL = 'https://api.openai.com/v1/audio/transcriptions';

/**
 * Download a voice message from Telegram and transcribe it via Whisper.
 */
export async function transcribeVoice(
  api: Api,
  botToken: string,
  fileId: string,
  duration: number,
): Promise<string | null> {
  const openaiKey = process.env.OPENAI_API_KEY;
  if (!openaiKey) {
    logger.warn('OPENAI_API_KEY not set — cannot transcribe voice messages');
    return null;
  }

  try {
    // Download the voice file from Telegram
    const file = await api.getFile(fileId);
    if (!file.file_path) {
      logger.warn('Telegram getFile returned no file_path for voice');
      return null;
    }

    const url = `https://api.telegram.org/file/bot${botToken}/${file.file_path}`;
    const response = await fetch(url);
    if (!response.ok) {
      logger.warn({ status: response.status }, 'Voice download failed');
      return null;
    }

    const buffer = Buffer.from(await response.arrayBuffer());

    // Save to tmp for the API call
    const tmpPath = `/tmp/voice-${Date.now()}.ogg`;
    fs.writeFileSync(tmpPath, buffer);

    // Call Whisper API
    const formData = new FormData();
    const blob = new Blob([buffer], { type: 'audio/ogg' });
    formData.append('file', blob, 'voice.ogg');
    formData.append('model', 'whisper-1');

    const whisperResponse = await fetch(WHISPER_API_URL, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${openaiKey}` },
      body: formData,
    });

    // Clean up
    try { fs.unlinkSync(tmpPath); } catch { /* ignore */ }

    if (!whisperResponse.ok) {
      const errText = await whisperResponse.text();
      logger.warn({ status: whisperResponse.status, error: errText }, 'Whisper API error');
      return null;
    }

    const result = await whisperResponse.json() as { text: string };
    logger.info(
      { duration, textLength: result.text.length },
      'Voice message transcribed',
    );

    return result.text;
  } catch (err) {
    logger.error(
      { err: err instanceof Error ? err.message : String(err) },
      'Voice transcription failed',
    );
    return null;
  }
}
