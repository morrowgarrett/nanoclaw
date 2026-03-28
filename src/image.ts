/**
 * Image processing for Telegram photos.
 * Downloads via Grammy's getFile, resizes with sharp, saves to group workspace.
 * The agent reads images via its Read tool (Claude natively understands images).
 */
import fs from 'fs';
import path from 'path';
import sharp from 'sharp';
import { Api } from 'grammy';
import { logger } from './logger.js';

const MAX_DIMENSION = 1568;
const JPEG_QUALITY = 85;

/**
 * Download a photo from Telegram, resize it, and save to the group workspace.
 * Returns the host file path so the container can read it via its mounted workspace.
 */
export async function downloadAndSavePhoto(
  api: Api,
  botToken: string,
  photoSizes: Array<{ file_id: string; width?: number; height?: number }>,
  groupFolder: string,
): Promise<{ hostPath: string; containerPath: string; mimeType: string } | null> {
  try {
    const photo = photoSizes[photoSizes.length - 1];
    if (!photo) return null;

    const file = await api.getFile(photo.file_id);
    if (!file.file_path) {
      logger.warn('Telegram getFile returned no file_path');
      return null;
    }

    const url = `https://api.telegram.org/file/bot${botToken}/${file.file_path}`;
    const response = await fetch(url);
    if (!response.ok) {
      logger.warn({ status: response.status }, 'Image download failed');
      return null;
    }

    const buffer = Buffer.from(await response.arrayBuffer());

    // Resize with sharp — fit within MAX_DIMENSION, preserve aspect ratio
    const resized = await sharp(buffer)
      .resize(MAX_DIMENSION, MAX_DIMENSION, {
        fit: 'inside',
        withoutEnlargement: true,
      })
      .jpeg({ quality: JPEG_QUALITY })
      .toBuffer();

    // Save to group media directory
    const mediaDir = path.join(groupFolder, 'media');
    fs.mkdirSync(mediaDir, { recursive: true });

    const filename = `photo-${Date.now()}.jpg`;
    const hostPath = path.join(mediaDir, filename);
    fs.writeFileSync(hostPath, resized);

    // Container path: the group folder is mounted at /workspace/group/
    const containerPath = `/workspace/group/media/${filename}`;

    logger.info(
      { originalSize: buffer.length, resizedSize: resized.length, hostPath, containerPath },
      'Saved image attachment',
    );

    return { hostPath, containerPath, mimeType: 'image/jpeg' };
  } catch (err) {
    logger.error(
      { err: err instanceof Error ? err.message : String(err) },
      'Image processing failed',
    );
    return null;
  }
}
