# 🚂 WhatHero Backend - Railway Setup Guide

## Configuración en Railway

### 1. Variables de Entorno

Agrega estas variables en el dashboard de Railway:

```
FIREBASE_CONFIG=<tu-json-aqui>
```

Para obtener el valor de `FIREBASE_CONFIG`:
1. Abre tu archivo `serviceAccountKey.json` localmente
2. Copia TODO el contenido JSON
3. En Railway, en Variables, establece `FIREBASE_CONFIG` = al contenido JSON completo (sin espacios si quieres minimizar)

Ejemplo (estructura, no valores reales):
```json
{
  "type": "service_account",
  "project_id": "whathero-73605",
  "private_key_id": "...",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "client_email": "firebase-adminsdk-xxxxx@whathero-73605.iam.gserviceaccount.com",
  "client_id": "...",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "..."
}
```

### 2. Volúmenes de Persistencia

En Railway, configura un volumen para la carpeta `auth_info/`:

- **Path en contenedor:** `/app/auth_info`
- **Path en volumen:** `/app/auth_info` (Railway lo asigna automáticamente)

Esto asegura que las credenciales de WhatsApp (archivos de sesión) persistan entre reinicios.

### 3. Dockerfile

El proyecto incluye un `Dockerfile` multi-stage optimizado que:
- Compila TypeScript en la etapa de build
- Instala solo dependencias de producción en la imagen final
- Crea la carpeta `auth_info` con permisos correctos
- Expone el puerto `3000`

### 4. Build & Deploy

Railway detectará automáticamente el `Dockerfile` en la raíz del servicio (`/backend`). 

Para desplegar:
1. Conecta tu repositorio GitHub a Railway
2. Selecciona la rama `main` (o la que uses)
3. En el panel de Railway, ve a "Settings" > "Build Settings"
4. Asegúrate de que el contexto sea `/backend` (no la raíz del monorepo)
5. O usa `railway up` desde la CLI

### 5. CORS y Socket.io

El backend está configurado con CORS abierto (`*`) para funcionar sin restricciones:
- Express: `cors: { origin: "*" }`
- Socket.io: `cors: { origin: "*", methods: ["GET", "POST"] }`

Esto permite que Flutter Web y otras aplicaciones cliente se conecten sin bloqueos.

### 6. Health Check

El Dockerfile incluye un health check que verifica la disponibilidad del puerto 3000 cada 30 segundos.

### 7. Puertos

- Backend escucha en el puerto `3000` (TCP)
- Railway asigna automáticamente una URL pública (ej: `https://whathero-backend-prod.railway.app`)

---

## Troubleshooting

### "Firebase configuration not found"
- Verifica que `FIREBASE_CONFIG` está definida en Railway
- Asegúrate de que el JSON es válido (sin saltos de línea extras)

### "ENOENT: no such file or directory, open 'auth_info/...'"
- Verifica que el volumen de Railway está montado correctamente
- Haz redeploy después de configurar el volumen

### Conexión Socket.io rechazada
- Comprueba que CORS está permitido (`origin: "*"`)
- Verifica que las URLs del cliente coinciden con la URL pública de Railway

---

## Desarrollo Local

```bash
cd backend

# Con serviceAccountKey.json local
npm run dev

# O con variable de entorno
FIREBASE_CONFIG='{"type":"service_account",...}' npm run dev
```

## Build Local

```bash
cd backend
npm run build
# Genera dist/index.js
```
