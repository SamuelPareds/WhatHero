# Baileys v7.0 uses ESM - run directly with tsx in both dev and prod
FROM node:20-alpine

WORKDIR /app

# Create auth_info directory with proper permissions
RUN mkdir -p auth_info && chmod 755 auth_info

# Copy package files
COPY package*.json ./
COPY tsconfig.json ./

# Install dependencies
RUN npm ci

# Copy source code
COPY src ./src
COPY index.ts ./

# Expose port 3000
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000', (r) => {if (r.statusCode !== 404) throw new Error(r.statusCode)})"

# Start the application
CMD ["npm", "start"]
