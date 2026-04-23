// Configuración central de entorno para WhatHero backend.
//
// Separa los datos de desarrollo y producción en colecciones distintas
// dentro del mismo proyecto Firebase. Esto evita que al correr el backend
// en local el HealthCheck marque como desvinculadas las sesiones reales
// de producción (y viceversa al reiniciar Railway).
//
// Railway debe tener NODE_ENV=production para escribir en "accounts".
// En local, NODE_ENV=development (por defecto si no se define) escribe
// en "accounts_dev".

export const IS_PRODUCTION = process.env.NODE_ENV === 'production';

export const ACCOUNTS_COLLECTION = IS_PRODUCTION ? 'accounts' : 'accounts_dev';
