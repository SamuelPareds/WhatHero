# 🏠 WhatHero Backend - Setup Local

## Configuración Inicial (Primera vez)

### 1️⃣ Instalar dependencias
```bash
cd backend
npm install
```

### 2️⃣ Crear `.env` local
```bash
# Copiar plantilla
cp .env.example .env
```

### 3️⃣ Configurar Firebase

**Opción A (Recomendado - Simula Producción):**
1. Abre `serviceAccountKey.json` (tu archivo de Firebase)
2. Copia TODO el contenido JSON
3. En `.env`, reemplaza `FIREBASE_CONFIG` con ese JSON completo
```
FIREBASE_CONFIG={"type":"service_account","project_id":"..."}
```

**Opción B (Más Simple - Archivo Local):**
1. Coloca `serviceAccountKey.json` en la carpeta `/backend`
2. No configures `FIREBASE_CONFIG` en `.env`
3. El backend lo encontrará automáticamente

### 4️⃣ Listo para desarrollar

```bash
npm run dev
```

El backend:
- ✅ Carga `.env` automáticamente (dotenv)
- ✅ Escucha en puerto 3000
- ✅ Hot-reload con `tsx watch`
- ✅ Crea `auth_info/` si no existe

---

## 📋 Workflow Normal

```bash
# Desarrollo con watch
npm run dev

# Build TypeScript (para testing)
npm run build

# Producción (después de build)
npm start
```

---

## 🔧 Variables de Entorno

| Variable | Requerida | Defecto | Descripción |
|----------|-----------|---------|------------|
| `FIREBASE_CONFIG` | ❌ | - | JSON stringificado de Firebase (Railway) |
| `PORT` | ❌ | 3000 | Puerto del servidor |
| `NODE_ENV` | ❌ | development | development \| production |

---

## ⚠️ Importante

- **No commits `.env`** (está en `.gitignore`)
- **`.env.example` SÍ se commitea** (es la plantilla)
- Para Railway, configura `FIREBASE_CONFIG` en el dashboard (no uses `.env`)
- `serviceAccountKey.json` nunca debe estar en el repo (está en `.gitignore`)

---

## 🐛 Troubleshooting

### "Firebase configuration not found"
- Verifica que `FIREBASE_CONFIG` esté en `.env`
- O que `serviceAccountKey.json` exista en `/backend`

### ".env no se carga"
- Asegúrate de que existe el archivo `.env` (no `.env.example`)
- Reinicia el servidor (`npm run dev`)

### Puerto ya en uso
```bash
# Usa otro puerto
PORT=8000 npm run dev
```
