#!/bin/bash
set -e

echo "Installing backend dependencies..."
cd backend
npm install

echo "Building backend..."
npm run build

echo "Starting backend server..."
npm start
