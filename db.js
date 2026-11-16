'use strict';

const fs = require('node:fs');
const path = require('node:path');

const dotenvPath = path.join(__dirname, fs.existsSync(path.join(__dirname, '.env')) ? '.env' : 'env');
require('dotenv').config({ path: dotenvPath });

const mysql = require('mysql2/promise');

const requiredEnvironmentVariable = (name) => {
    const value = process.env[name];
    if (!value) {
        throw new Error(`Missing required environment variable: ${name}`);
    }
    return value;
};

const port = Number(process.env.DB_PORT || 3306);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('DB_PORT must be an integer between 1 and 65535');
}

const pool = mysql.createPool({
    host: process.env.DB_HOST || '127.0.0.1',
    port,
    user: requiredEnvironmentVariable('DB_USER'),
    password: process.env.DB_PASSWORD || '',
    database: process.env.DB_NAME || 'inganzo',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
    charset: 'utf8mb4'
});

async function testConnection() {
    const connection = await pool.getConnection();
    try {
        await connection.query('SELECT 1');
        console.log('Connected to the inganzo database.');
    } finally {
        connection.release();
    }
}

module.exports = { pool, testConnection };

if (require.main === module) {
    testConnection()
        .catch((error) => {
            console.error('Database connection failed:', error.message);
            process.exitCode = 1;
        })
        .finally(() => pool.end());
}
