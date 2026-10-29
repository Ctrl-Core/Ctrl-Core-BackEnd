import mysql from 'mysql2/promise';
import dotenv from 'dotenv';

dotenv.config();

export const dbPool = mysql.createPool({
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT) || 3306,
  user: process.env.DB_USER || 'unab_cde_user',
  password: process.env.DB_PASSWORD || 'hackaton_2026',
  database: process.env.DB_NAME || 'ctrl_core_db',
  // Optimizaciones Críticas
  connectionLimit: 20,
  waitForConnections: true,
  queueLimit: 0,
  enableKeepAlive: true,
  keepAliveInitialDelay: 10000,
  // Parsea DECIMAL y NUMERIC de MySQL a Number nativo de JS (Vital para XP e Impactos)
  decimalNumbers: true,
  // Sincroniza la zona horaria exacta definida en tu DDL
  timezone: '-05:00',
  // Mapea los resultados como objetos clave-valor (por defecto)
  namedPlaceholders: true
});

// Autoevaluación rápida para que Node.js no arranque ciego
export async function testConnection() {
  try {
    const connection = await dbPool.getConnection();
    console.log('✅ [MySQL] Conexión establecida con éxito a ctrl_core_db');
    connection.release();
  } catch (error) {
    console.error('❌ [MySQL] Error fatal al conectar con la base de datos:', error);
    process.exit(1); // Falla rápido para que Docker/Nodemon te avise de inmediato
  }
}