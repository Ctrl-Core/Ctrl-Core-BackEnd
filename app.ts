import express, { Request, Response } from 'express';
import cors from 'cors';
import { testConnection } from './src/shared/database/connection';
import { tenantMiddleware } from './src/shared/middlewares/tenant.middleware';
import companyRoutes from './src/modules/empresas/infrastructure/http/company.routes';
import authRoutes from './src/modules/auth/infrastructure/http/auth.routes';
import analyticsRoutes from './src/modules/analytics/infrastructure/http/analytics.routes';
import kanbanRoutes from './src/modules/intervenciones/infrastructure/http/kanban.routes';

const app = express();
const PORT = process.env.PORT || 3000;

// Configuración global
app.use(cors());
app.use(express.json()); 
app.use(express.urlencoded({ extended: true }));


// ==============================================================
// RUTAS PÚBLICAS (NO requieren Token)
// ==============================================================
app.get('/api/v1/health', (req: Request, res: Response) => {
  res.json({ success: true, message: 'CTRL+CORE API Online' });
});

app.use('/api/v1/auth', authRoutes);

// ==============================================================
// MIDDLEWARE GLOBAL MULTITENANT
// ==============================================================
app.use('/api/v1', tenantMiddleware);

// ==============================================================
// RUTAS PROTEGIDAS (SÍ requieren Token o Header de prueba)
// ==============================================================
app.use('/api/v1/empresas', companyRoutes);
app.use('/api/v1/analytics', analyticsRoutes);
app.use('/api/v1/intervenciones/kanban', kanbanRoutes);

async function bootstrap() {
  await testConnection();
  app.listen(PORT, () => console.log(`🚀 [Server] API corriendo en http://localhost:${PORT}`));
}
bootstrap();