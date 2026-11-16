// init_db.js
require('dotenv').config();
const mysql = require('mysql2/promise');
const fs = require('fs');
const path = require('path');

async function main() {
  const connection = await mysql.createConnection({
    host: process.env.DB_HOST,
    port: process.env.DB_PORT,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
  });

  // Create database if it does not exist
  await connection.query(`CREATE DATABASE IF NOT EXISTS \\\`${process.env.DB_NAME}\\\`;`);
  await connection.query(`USE \\\`${process.env.DB_NAME}\\\`;`);

  // Countries table
  await connection.query(`
    CREATE TABLE IF NOT EXISTS countries (
      id INT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(100) NOT NULL UNIQUE
    );
  `);

  // Items table – each cultural entry
  await connection.query(`
    CREATE TABLE IF NOT EXISTS items (
      id INT AUTO_INCREMENT PRIMARY KEY,
      country_id INT NOT NULL,
      title VARCHAR(200) NOT NULL,
      description TEXT,
      video_url VARCHAR(255),
      FOREIGN KEY (country_id) REFERENCES countries(id) ON DELETE CASCADE
    );
  `);

  // Load country list from the existing JSON file
  const countries = JSON.parse(fs.readFileSync(path.join(__dirname, 'countries.json'), 'utf8'));

  // Insert countries (ignore duplicates)
  for (const name of countries) {
    await connection.query(`
      INSERT IGNORE INTO countries (name) VALUES (?);
    `, [name]);
  }

  console.log('✅ Database initialized – countries loaded.');
  await connection.end();
}

main().catch(err => console.error(err));