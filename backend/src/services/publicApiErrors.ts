// ============================================
// Errores del API pública: el contrato con los sistemas externos.
//
// Cada error lleva un `code` estable y una `action` que le dice a quien llama
// qué hacer con ESE contacto, sin tener que conocer cada código:
//   - stop:  detén el lote. Es configuración (llave, sesión, plantilla) y el
//            siguiente contacto va a fallar igual.
//   - skip:  sigue con el siguiente contacto y no reintentes éste.
//   - retry: reintenta este mismo envío más tarde, con la misma idempotencyKey.
//
// Los códigos y sus acciones no se cambian una vez publicados: hay sistemas
// decidiendo con ellos. Agregar uno nuevo sí se puede. Ver CLAUDE.md, "🔑 API pública".
// ============================================

export type ApiAction = 'stop' | 'skip' | 'retry';

export const PUBLIC_API_ERRORS = {
  unauthorized: { http: 401, action: 'stop' },
  forbidden_session: { http: 403, action: 'stop' },
  invalid_request: { http: 400, action: 'stop' },
  invalid_phone: { http: 400, action: 'skip' },
  session_not_found: { http: 404, action: 'stop' },
  session_not_cloud_api: { http: 422, action: 'stop' },
  session_unavailable: { http: 503, action: 'stop' },
  template_not_found: { http: 404, action: 'stop' },
  template_not_approved: { http: 409, action: 'stop' },
  template_paused: { http: 409, action: 'stop' },
  template_unsupported: { http: 422, action: 'stop' },
  missing_variables: { http: 422, action: 'stop' },
  invalid_variable_value: { http: 422, action: 'skip' },
  recipient_opted_out: { http: 409, action: 'skip' },
  recipient_unreachable: { http: 422, action: 'skip' },
  recipient_marketing_limited: { http: 422, action: 'skip' },
  idempotency_conflict: { http: 409, action: 'stop' },
  in_progress: { http: 409, action: 'retry' },
  send_in_doubt: { http: 409, action: 'skip' },
  rate_limited: { http: 429, action: 'retry' },
  meta_rate_limited: { http: 429, action: 'retry' },
  session_credentials_invalid: { http: 502, action: 'stop' },
  account_restricted: { http: 403, action: 'stop' },
  template_rejected_by_meta: { http: 422, action: 'stop' },
  meta_unavailable: { http: 503, action: 'retry' },
  meta_rejected: { http: 422, action: 'stop' },
  internal_error: { http: 500, action: 'retry' },
} as const satisfies Record<string, { http: number; action: ApiAction }>;

export type PublicApiErrorCode = keyof typeof PUBLIC_API_ERRORS;

export interface PublicApiErrorExtra {
  /** Para pisar el HTTP del catálogo (un `send_in_doubt` por timeout es 504). */
  httpStatus?: number;
  retryAfterSeconds?: number;
  metaCode?: number;
  templateStatus?: string;
  variables?: string[];
  details?: string[];
}

export class PublicApiError extends Error {
  readonly code: PublicApiErrorCode;
  readonly httpStatus: number;
  readonly action: ApiAction;
  readonly extra: Omit<PublicApiErrorExtra, 'httpStatus'>;

  constructor(code: PublicApiErrorCode, message: string, extra: PublicApiErrorExtra = {}) {
    super(message);
    this.name = 'PublicApiError';
    this.code = code;
    const { httpStatus, ...rest } = extra;
    this.httpStatus = httpStatus ?? PUBLIC_API_ERRORS[code].http;
    this.action = PUBLIC_API_ERRORS[code].action;
    this.extra = rest;
  }

  toJSON() {
    return { error: { code: this.code, message: this.message, action: this.action, ...this.extra } };
  }
}

// Códigos de Meta al enviar (developers.facebook.com → Cloud API → Error codes),
// agrupados por lo que significan para quien llama.
const META_RATE = new Set([4, 80007, 130429, 131056]);
const META_CREDENTIALS = new Set([3, 10, 190, 200, 131005]);
const META_ACCOUNT = new Set([368, 131031, 131042, 131048, 133010]);
const META_TEMPLATE = new Set([132000, 132001, 132005, 132007, 132012]);
const META_RECIPIENT = new Set([131021, 131026, 131030]);
const META_DOWN = new Set([1, 2, 131000, 131016]);
// Meta usa ambos para "este usuario dejó de recibir marketing de tu negocio".
export const META_MARKETING_OPT_OUT = new Set([131050, 498]);

/** Un error de Meta que SÍ respondió (el mensaje no salió), en el contrato del API. */
export function mapMetaSendError(err: { code?: number; httpStatus?: number; message?: string; details?: string }): PublicApiError {
  const code = err.code;
  const metaText = err.details || err.message || 'Meta rechazó el envío.';
  const extra = code !== undefined ? { metaCode: code } : {};

  if (code !== undefined && META_RATE.has(code)) {
    return new PublicApiError('meta_rate_limited', 'Meta está limitando los envíos de este número. Reintenta en unos minutos.', {
      ...extra,
      retryAfterSeconds: 60,
    });
  }
  if (code !== undefined && META_CREDENTIALS.has(code)) {
    return new PublicApiError(
      'session_credentials_invalid',
      'El Access Token de Meta de esta sesión venció o no tiene permiso. El owner tiene que actualizar las credenciales en WhatHero.',
      extra,
    );
  }
  if (code !== undefined && META_ACCOUNT.has(code)) {
    return new PublicApiError('account_restricted', `Meta tiene restringido este número o su cuenta: ${metaText}`, extra);
  }
  if (code === 132015) {
    return new PublicApiError('template_paused', 'Meta pausó esta plantilla por su calidad.', { ...extra, templateStatus: 'PAUSED' });
  }
  if (code === 132016) {
    return new PublicApiError('template_not_approved', 'Meta desactivó esta plantilla.', { ...extra, templateStatus: 'DISABLED' });
  }
  if (code !== undefined && META_TEMPLATE.has(code)) {
    return new PublicApiError('template_rejected_by_meta', `Meta rechazó la plantilla al enviar: ${metaText}`, extra);
  }
  if (code !== undefined && META_MARKETING_OPT_OUT.has(code)) {
    return new PublicApiError('recipient_opted_out', 'Este contacto pidió no recibir marketing de tu negocio.', extra);
  }
  if (code === 131049) {
    return new PublicApiError(
      'recipient_marketing_limited',
      'Meta no entregó el mensaje para cuidar la experiencia del usuario (límite de marketing por persona).',
      extra,
    );
  }
  if (code !== undefined && META_RECIPIENT.has(code)) {
    return new PublicApiError('recipient_unreachable', `Meta no puede entregarle a este número: ${metaText}`, extra);
  }
  if ((code !== undefined && META_DOWN.has(code)) || (err.httpStatus ?? 0) >= 500) {
    return new PublicApiError('meta_unavailable', 'Meta tuvo un error y no envió el mensaje. Reintenta más tarde.', {
      ...extra,
      retryAfterSeconds: 60,
    });
  }
  return new PublicApiError('meta_rejected', metaText, extra);
}
