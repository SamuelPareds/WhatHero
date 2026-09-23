import { execFile } from 'child_process';
import { promisify } from 'util';
import { writeFile, unlink } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { randomUUID } from 'crypto';

const execFileAsync = promisify(execFile);

// Tamaño y duración de un video saliente, con los nombres de campo de
// `videoMessage` para poder esparcirlos directo en el contenido de Baileys.
//
// Baileys mide las imágenes (`originalImageDimensions`) pero NO los videos: saca
// la miniatura con ffmpeg y deja `width`/`height`/`seconds` sin llenar. Sin esas
// medidas WhatsApp iOS dibuja la burbuja en un cuadro 1:1 y sin duración; sólo
// al pasarlo a Picture-in-Picture se ve con su proporción real. El eco `fromMe`
// hereda estos mismos campos (mediaWidth/Height/Duration en Firestore), así que
// también es lo que usa la burbuja saliente de WhatHero.
export interface VideoInfo {
  width?: number;
  height?: number;
  seconds?: number;
}

// Interpreta el JSON de `ffprobe -show_streams -show_format`. Pura a propósito:
// es la parte con reglas sutiles y se puede probar sin el binario.
//
// La rotación es la trampa: un video vertical de iPhone viene codificado como
// 1920×1080 con una marca de "girar -90°". Si no se intercambian ancho y alto,
// el vertical llega horizontal — el mismo bug al revés. ffmpeg ≥5 la expone en
// `side_data_list[].rotation`; las versiones viejas en `tags.rotate`.
//
// Un campo inválido o ≤0 se omite: preferimos que WhatsApp use su default a
// mandarle un 0.
export function videoInfoFromProbe(probe: any): VideoInfo {
  const stream = probe?.streams?.[0];
  const info: VideoInfo = {};

  let width = Number(stream?.width);
  let height = Number(stream?.height);
  if (width > 0 && height > 0) {
    const sideRotation = Array.isArray(stream?.side_data_list)
      ? stream.side_data_list.find((d: any) => d?.rotation != null)?.rotation
      : undefined;
    const rotation = Number(sideRotation ?? stream?.tags?.rotate ?? 0);
    if (Math.abs(rotation) % 180 === 90) {
      [width, height] = [height, width];
    }
    info.width = width;
    info.height = height;
  }

  // ffprobe escribe "N/A" (no null) cuando el contenedor no declara duración,
  // así que el respaldo al stream va por validez numérica, no por `??`.
  const formatDuration = Number(probe?.format?.duration);
  const duration = formatDuration > 0 ? formatDuration : Number(stream?.duration);
  if (duration > 0) {
    info.seconds = Math.max(1, Math.round(duration));
  }

  return info;
}

// Mide el video con `ffprobe`, que viene en el paquete `ffmpeg` de la imagen
// Docker (el mismo que Baileys usa para la miniatura).
//
// Va por archivo temporal y no por stdin: los .mov/.mp4 de iPhone suelen traer
// el `moov` (donde viven las medidas) al final, y por un pipe no se puede saltar
// hasta ahí.
//
// Fail-open: si algo falla (sin ffprobe en dev, timeout, JSON roto) devuelve {}
// y el video sale igual que antes de existir esto. El warn es el único rastro.
export async function probeVideo(buffer: Buffer): Promise<VideoInfo> {
  const path = join(tmpdir(), `probe-${randomUUID()}`);
  try {
    await writeFile(path, buffer);
    const { stdout } = await execFileAsync(
      'ffprobe',
      ['-v', 'error', '-select_streams', 'v:0', '-show_streams', '-show_format', '-of', 'json', path],
      { timeout: 10_000, maxBuffer: 1024 * 1024 },
    );
    return videoInfoFromProbe(JSON.parse(stdout));
  } catch (error) {
    console.warn(`[probeVideo] No se pudo medir el video, sale sin width/height:`, (error as any)?.message);
    return {};
  } finally {
    await unlink(path).catch(() => {});
  }
}
