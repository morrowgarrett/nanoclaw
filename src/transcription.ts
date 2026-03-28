/**
 * Voice message transcription via local whisper.cpp.
 * Downloads voice messages from Telegram, converts to WAV, runs whisper.cpp locally.
 */
import fs from 'fs';
import path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { Api } from 'grammy';
import { logger } from './logger.js';

const execFileAsync = promisify(execFile);

const WHISPER_BIN = '/home/garrett/whisper.cpp/build/bin/whisper-cli';
const WHISPER_MODEL = '/home/garrett/whisper.cpp/models/ggml-base.en.bin';

/**
 * Download a voice message from Telegram and transcribe it via local whisper.cpp.
 */
export async function transcribeVoice(
  api: Api,
  botToken: string,
  fileId: string,
  duration: number,
): Promise<string | null> {
  const tmpOgg = `/tmp/voice-${Date.now()}.ogg`;
  const tmpWav = `/tmp/voice-${Date.now()}.wav`;

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
    fs.writeFileSync(tmpOgg, buffer);

    // Convert OGG to 16kHz mono WAV for whisper.cpp
    await execFileAsync('ffmpeg', [
      '-i',
      tmpOgg,
      '-ar',
      '16000',
      '-ac',
      '1',
      '-c:a',
      'pcm_s16le',
      '-y',
      tmpWav,
    ]);

    // Run whisper.cpp locally
    const { stdout } = await execFileAsync(
      WHISPER_BIN,
      ['-m', WHISPER_MODEL, '-f', tmpWav, '--no-timestamps', '-nt'],
      { timeout: 60_000 },
    );

    const text = stdout.trim();

    if (!text) {
      logger.warn('whisper.cpp returned empty transcription');
      return null;
    }

    logger.info(
      { duration, textLength: text.length },
      'Voice message transcribed (local whisper.cpp)',
    );

    return text;
  } catch (err) {
    logger.error(
      { err: err instanceof Error ? err.message : String(err) },
      'Voice transcription failed',
    );
    return null;
  } finally {
    // Clean up temp files
    try {
      fs.unlinkSync(tmpOgg);
    } catch {
      /* ignore */
    }
    try {
      fs.unlinkSync(tmpWav);
    } catch {
      /* ignore */
    }
  }
}
