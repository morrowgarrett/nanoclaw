/**
 * Image processing for Telegram photos.
 * Downloads via Grammy's getFile, resizes with sharp, returns base64.
 */
import sharp from 'sharp';
import { Api } from 'grammy';
import { logger } from './logger.js';

const MAX_DIMENSION = 1024;
const JPEG_QUALITY = 80;

/**
 * Download a photo from Telegram, resize it, and return base64-encoded JPEG.
 * Telegram photos come as an array of PhotoSize — we pick the largest one.
 */
export async function downloadAndProcessPhoto(
  api: Api,
  botToken: string,
  photoSizes: Array<{ file_id: string; width?: number; height?: number }>,
): Promise<{ base64: string; mimeType: string } | null> {
  try {
    // Pick the largest photo size (last in the array per Telegram API convention)
    const photo = photoSizes[photoSizes.length - 1];
    if (!photo) return null;

    // Get the file path from Telegram
    const file = await api.getFile(photo.file_id);
    if (!file.file_path) {
      logger.warn('Telegram getFile returned no file_path');
      return null;
    }

    // Download the file
    const url = `https://api.telegram.org/file/bot${botToken}/${file.file_path}`;
    const response = await fetch(url);
    if (!response.ok) {
      logger.warn({ status: response.status }, 'Image download failed');
      return null;
    }

    const buffer = Buffer.from(await response.arrayBuffer());

    // Resize with sharp — fit within MAX_DIMENSION, preserve aspect ratio
    const resized = await sharp(buffer)
      .resize(MAX_DIMENSION, MAX_DIMENSION, { fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: JPEG_QUALITY })
      .toBuffer();

    const base64 = resized.toString('base64');
    logger.info(
      { originalSize: buffer.length, resizedSize: resized.length },
      'Processed image attachment',
    );

    return { base64, mimeType: 'image/jpeg' };
  } catch (err) {
    logger.error(
      { err: err instanceof Error ? err.message : String(err) },
      'Image processing failed',
    );
    return null;
  }
}
