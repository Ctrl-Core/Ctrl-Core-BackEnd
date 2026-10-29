import { Router } from 'express';
import { getEmpresas, getExpediente360 } from './company.controller';

const router = Router();

// GET /api/v1/empresas
router.get('/', getEmpresas);

// GET /api/v1/empresas/:id/expediente-360
router.get('/:id/expediente-360', getExpediente360);

export default router;