// Middleware de autorización para HTTP y Socket.io.
//
// Antes de esta capa, el backend confiaba ciegamente en el `accountId` que
// el cliente enviaba (en el body o en el handshake). Cualquiera con un
// accountId válido podía leer/escribir cuentas ajenas. Con multi-usuario
// esto se vuelve crítico: necesitamos validar que el `uid` real del
// requester (extraído del Firebase ID Token) tenga membresía en el
// `accountId` solicitado.
//
// Fuente de verdad: Firestore `users/{uid}.memberOfAccounts`.
//
// Cache en memoria: para no pegarle a Firestore en cada request, cacheamos
// la membresía 60s. Cuando un owner agrega/quita un sub-user, también
// llamamos a `setCustomUserClaims` para que el siguiente token traiga la
// info embebida (y para que las Storage Rules puedan validar sin Firestore).

import type { Request, Response, NextFunction } from 'express';
import type { Socket } from 'socket.io';
import admin from 'firebase-admin';

// Inyectamos `auth` en req para que los handlers puedan leer uid/accountIds
// sin re-decodificar el token.
export interface AuthInfo {
  uid: string;
  email?: string;
  memberOfAccounts: string[];
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      auth?: AuthInfo;
    }
  }
}

// Cache uid → { memberOfAccounts, expiresAt }. TTL corto: si un owner
// modifica miembros, el cambio toma efecto en máximo 60s (o inmediatamente
// si el cliente refresca su token vía /auth/refresh-claims).
const membershipCache = new Map<
  string,
  { memberOfAccounts: string[]; expiresAt: number }
>();
const CACHE_TTL_MS = 60_000;

async function loadMembership(uid: string): Promise<string[]> {
  const cached = membershipCache.get(uid);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.memberOfAccounts;
  }
  const snap = await admin.firestore().collection('users').doc(uid).get();
  const memberOfAccounts: string[] =
    (snap.exists && (snap.data()?.memberOfAccounts as string[])) || [];
  membershipCache.set(uid, {
    memberOfAccounts,
    expiresAt: Date.now() + CACHE_TTL_MS,
  });
  return memberOfAccounts;
}

/// Invalidación manual del cache (cuando un owner agrega/quita miembros).
export function invalidateMembershipCache(uid: string) {
  membershipCache.delete(uid);
}

/// Extrae y verifica el ID token. Retorna AuthInfo o null si inválido.
async function decodeToken(idToken: string): Promise<AuthInfo | null> {
  try {
    const decoded = await admin.auth().verifyIdToken(idToken);
    // Si el token trae `memberOf` como custom claim, la usamos como
    // primera fuente (más rápido). Si no, leemos Firestore.
    const claimMemberOf = decoded['memberOf'];
    let memberOfAccounts: string[];
    if (Array.isArray(claimMemberOf)) {
      memberOfAccounts = claimMemberOf as string[];
    } else {
      memberOfAccounts = await loadMembership(decoded.uid);
    }
    return {
      uid: decoded.uid,
      email: decoded.email,
      memberOfAccounts,
    };
  } catch (e) {
    console.warn('[auth] verifyIdToken falló:', (e as Error).message);
    return null;
  }
}

/// Middleware Express: exige Authorization Bearer y valida que el accountId
/// del body esté en la membresía del requester. Si el endpoint no manda
/// accountId (caso raro: rutas tipo `/auth/refresh-claims`), basta con
/// que el token sea válido.
export function verifyHttpAuth(opts: { requireAccountId?: boolean } = {}) {
  const requireAccountId = opts.requireAccountId !== false;
  return async (req: Request, res: Response, next: NextFunction) => {
    const header = req.headers.authorization || '';
    const match = header.match(/^Bearer\s+(.+)$/i);
    if (!match) {
      return res
        .status(401)
        .json({ error: 'Missing Authorization Bearer token' });
    }
    const idToken = match[1];
    const auth = await decodeToken(idToken);
    if (!auth) {
      return res.status(401).json({ error: 'Invalid token' });
    }
    req.auth = auth;

    if (requireAccountId) {
      const accountId = req.body?.accountId as string | undefined;
      if (!accountId) {
        return res
          .status(400)
          .json({ error: 'Missing accountId in body' });
      }
      if (!auth.memberOfAccounts.includes(accountId)) {
        console.warn(
          `[auth] uid=${auth.uid} intentó acceder a accountId=${accountId} sin membresía`,
        );
        return res
          .status(403)
          .json({ error: 'Not a member of this account' });
      }
    }

    next();
  };
}

/// Middleware Socket.io: valida idToken en el handshake y guarda la lista
/// de cuentas permitidas en `socket.data.allowedAccountIds`. El handshake
/// también trae un `accountId` (el "activo" para esa conexión); si no está
/// en la membresía, rechazamos.
export async function verifySocketAuth(
  socket: Socket,
  next: (err?: Error) => void,
) {
  try {
    const idToken = socket.handshake.auth.idToken as string | undefined;
    const accountId = socket.handshake.auth.accountId as string | undefined;
    if (!idToken || !accountId) {
      return next(new Error('Missing idToken or accountId in handshake'));
    }
    const auth = await decodeToken(idToken);
    if (!auth) {
      return next(new Error('Invalid token'));
    }
    if (!auth.memberOfAccounts.includes(accountId)) {
      console.warn(
        `[auth] socket uid=${auth.uid} intentó unirse a accountId=${accountId} sin membresía`,
      );
      return next(new Error('Not a member of this account'));
    }
    socket.data.uid = auth.uid;
    socket.data.allowedAccountIds = auth.memberOfAccounts;
    next();
  } catch (e) {
    console.error('[auth] error en verifySocketAuth:', e);
    next(new Error('Auth error'));
  }
}

/// Helper para que handlers Socket.io sepan si un accountId arbitrario
/// (ej. el del payload de un evento) está permitido para este socket.
export function socketCanAccess(socket: Socket, accountId: string): boolean {
  const allowed = socket.data.allowedAccountIds as string[] | undefined;
  return Array.isArray(allowed) && allowed.includes(accountId);
}
