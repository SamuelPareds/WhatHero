// Service Worker para Firebase Cloud Messaging (web push).
//
// Vive fuera del Flutter engine: corre en un contexto independiente del
// navegador y recibe los pushes incluso cuando la pestaña de la app está
// cerrada (mientras Chrome/Edge sigan vivos en background).
//
// Reglas:
// - DEBE estar en la raíz (`/firebase-messaging-sw.js`) para que el scope
//   cubra toda la app. Flutter web sirve `web/` como raíz, así que aquí va.
// - La firebaseConfig está duplicada respecto a `lib/firebase_options.dart`
//   porque el SW no comparte código con la app — es un mundo aparte.
// - Las versiones de los scripts importados se pinean a propósito: cambios
//   en la API de Firebase JS pueden romper el SW en silencio.

importScripts('https://www.gstatic.com/firebasejs/10.13.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.13.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyDfyvi_DDSU0TeZOuaONVXuDqd_GIXEzw8',
  appId: '1:316753391709:web:ecb77f62e869e21a641db4',
  messagingSenderId: '316753391709',
  projectId: 'whathero-73605',
  authDomain: 'whathero-73605.firebaseapp.com',
  storageBucket: 'whathero-73605.firebasestorage.app',
  measurementId: 'G-88TYGL0JHL',
});

const messaging = firebase.messaging();

// Cuando llega un push con la pestaña en background, mostramos la
// notificación del SO. Si la pestaña está activa, el SW NO muestra notif —
// `onMessage` en el cliente la maneja para evitar duplicados.
messaging.onBackgroundMessage((payload) => {
  // Log explícito: este mensaje aparece en chrome://serviceworker-internals
  // o en DevTools → Application → Service Workers (botón "inspect") cuando
  // el SW recibe un push. Si no lo ves, FCM no está entregando.
  console.log('[FCM-SW] Background message recibido:', payload);

  const title = payload.notification?.title || 'WhatHero';
  const options = {
    body: payload.notification?.body || '',
    icon: '/icons/Icon-192.png',
    badge: '/favicon.png',
    // tag agrupa notificaciones del mismo chat (collapse_key del backend).
    // Sin tag, el browser apila spam si llegan varios mensajes seguidos.
    tag: payload.data?.chatId
      ? `whathero:${payload.data.sessionPhone || ''}:${payload.data.chatId}`
      : 'whathero',
    renotify: true,
    data: payload.data || {},
  };
  return self.registration.showNotification(title, options);
});

// Click en la notificación → enfocar pestaña existente o abrir una.
// Deep-link granular (saltar al chat exacto) llegará en Fase 4 — por ahora
// el usuario aterriza en la lista de chats, que ya muestra el badge.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientsArr) => {
      const existing = clientsArr.find((c) => c.url.includes(self.location.origin));
      if (existing) {
        return existing.focus();
      }
      return self.clients.openWindow('/');
    })
  );
});
