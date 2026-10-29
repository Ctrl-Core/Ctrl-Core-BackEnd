// src/app.ts
import { testConnection } from './src/shared/database/connection.ts';
// ... tus otras importaciones

async function bootstrap() {
  await testConnection();
  
  // app.listen(...)
}

bootstrap();