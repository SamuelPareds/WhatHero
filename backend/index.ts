import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import makeWASocket, { 
  DisconnectReason, 
  useMultiFileAuthState, 
  fetchLatestBaileysVersion,
  ConnectionState
} from '@whiskeysockets/baileys';
import pino from 'pino';
import path from 'path';

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

const logger = pino({ level: 'info' }, pino.destination({ sync: false }));

let currentQR: string | undefined;
let isReady = false;

async function connectToWhatsApp() {
  const { state, saveCreds } = await useMultiFileAuthState('auth_info');
  const { version } = await fetchLatestBaileysVersion();

  const sock = makeWASocket({
    version,
    auth: state,
    logger: logger.child({ class: 'baileys' }),
    printQRInTerminal: true
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', (update: Partial<ConnectionState>) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      console.log('QR Code received');
      currentQR = qr;
      isReady = false;
      io.emit('qr', qr);
    }

    if (connection === 'close') {
      const shouldReconnect = (lastDisconnect?.error as any)?.output?.statusCode !== DisconnectReason.loggedOut;
      console.log('connection closed due to ', lastDisconnect?.error, ', reconnecting ', shouldReconnect);
      isReady = false;
      if (shouldReconnect) {
        connectToWhatsApp();
      }
    } else if (connection === 'open') {
      console.log('opened connection');
      isReady = true;
      currentQR = undefined;
      io.emit('ready', true);
    }
  });

  return sock;
}

io.on('connection', (socket) => {
  console.log('Socket.io client connected:', socket.id);
  console.log('Current status - isReady:', isReady, 'hasQR:', !!currentQR);
  
  if (isReady) {
    socket.emit('ready', true);
  } else if (currentQR) {
    socket.emit('qr', currentQR);
  }
});

httpServer.listen(3000, () => {
  console.log('Server running on port 3000');
  connectToWhatsApp();
});
