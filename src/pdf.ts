/**
 * PDF text extraction for Telegram documents.
 * Downloads via Grammy's getFile, saves to workspace, stores path for container.
 */
import fs from 'fs';
import path from 'path';
import { Api } from 'grammy';
import { logger } from './logger.js';

/**
 * Download a document from Telegram and return a workspace-relative path.
 * The container can then use pdftotext or read the file directly.
 */
export async function downloadDocument(
  api: Api,
  botToken: string,
  fileId: string,
  fileName: string,
  groupFolder: string,
): Promise<{ hostPath: string; content: string } | null> {
  try {
    const file = await api.getFile(fileId);
    if (!file.file_path) {
      logger.warn('Telegram getFile returned no file_path for document');
      return null;
    }

    const url = `https://api.telegram.org/file/bot${botToken}/${file.file_path}`;
    const response = await fetch(url);
    if (!response.ok) {
      logger.warn({ status: response.status }, 'Document download failed');
      return null;
    }

    const buffer = Buffer.from(await response.arrayBuffer());

    // Save to group media directory
    const mediaDir = path.join(groupFolder, 'media');
    fs.mkdirSync(mediaDir, { recursive: true });

    const safeName = fileName.replace(/[^a-zA-Z0-9._-]/g, '_');
    const timestamp = Date.now();
    const filePath = path.join(mediaDir, `${timestamp}-${safeName}`);
    fs.writeFileSync(filePath, buffer);

    logger.info(
      { fileName, size: buffer.length, path: filePath },
      'Downloaded document attachment',
    );

    // For PDFs, include the file path so the container agent can read it
    return {
      hostPath: filePath,
      content: `[Document saved: ${safeName}, ${buffer.length} bytes]`,
    };
  } catch (err) {
    logger.error(
      { err: err instanceof Error ? err.message : String(err) },
      'Document download failed',
    );
    return null;
  }
}
