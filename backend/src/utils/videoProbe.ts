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
// Baileys mide las imágenes (`originalImageDimensions`) pero de un video sólo
// saca la miniatura: `width`/`height`/`seconds` quedan vacíos. Sin `seconds` la
// burbuja del cliente dice 0:00, y el eco `fromMe` —de donde salen
// mediaWidth/Height/Duration en Firestore— deja la burbuja saliente de WhatHero
// en 16:9 y 0:00.
export interface VideoInfo {
  width?: number;
  height?: number;
  seconds?: number;
}

// "54:109" → 54/109. null si falta o no sirve: "0:1" es la forma de ffprobe de
// decir que el archivo no declara proporción de píxel.
function parseRatio(value: unknown): number | null {
  if (typeof value !== 'string') return null;
  const [num, den] = value.split(':').map(Number);
  return num > 0 && den > 0 ? num / den : null;
}

// Interpreta el JSON de `ffprobe -show_streams -show_format`. Pura a propósito:
// es la parte con reglas sutiles y se puede probar sin el binario.
//
// ffprobe da los píxeles GUARDADOS; WhatsApp necesita la forma en que el video
// SE VE. Dos marcas del archivo separan una cosa de la otra:
// - Píxeles no cuadrados (`sample_aspect_ratio`): el ancho visible es el
//   guardado por esa proporción. Ver "video cuadrado en iPhone" en CLAUDE.md.
// - Rotación: un vertical de la cámara del iPhone viene como 1920×1080 más una
//   marca de -90°. Sin intercambiar ancho y alto llegaría horizontal.
//
// Un campo inválido o ≤0 se omite: preferimos que WhatsApp use su default a
// mandarle un 0.
export function videoInfoFromProbe(probe: any): VideoInfo {
  const stream = probe?.streams?.[0];
  const info: VideoInfo = {};

  const pixelAspect = parseRatio(stream?.sample_aspect_ratio) ?? 1;
  let width = Math.round(Number(stream?.width) * pixelAspect);
  let height = Number(stream?.height);
  if (width > 0 && height > 0) {
    const rotation = Number(
      stream?.side_data_list?.find((d: any) => d?.rotation != null)?.rotation ?? 0,
    );
    if (Math.abs(rotation) % 180 === 90) {
      [width, height] = [height, width];
    }
    info.width = width;
    info.height = height;
  }

  const duration = Number(probe?.format?.duration);
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
      { timeout: 10_000 },
    );
    const probe = JSON.parse(stdout);

    // Píxeles no cuadrados: las medidas salen bien, pero el reproductor de
    // WhatsApp en iPhone dibuja los píxeles guardados y el video se ve
    // aplastado. No tiene arreglo desde acá; este log es el diagnóstico cuando
    // un cliente lo reporta.
    const sar = probe?.streams?.[0]?.sample_aspect_ratio;
    const pixelAspect = parseRatio(sar);
    if (pixelAspect !== null && pixelAspect !== 1) {
      console.warn(`[probeVideo] Video anamórfico (SAR ${sar}): en iPhone se verá aplastado. Hay que reexportarlo sin anamórfico.`);
    }

    return videoInfoFromProbe(probe);
  } catch (error) {
    console.warn(`[probeVideo] No se pudo medir el video, sale sin width/height:`, (error as any)?.message);
    return {};
  } finally {
    await unlink(path).catch(() => {});
  }
}
