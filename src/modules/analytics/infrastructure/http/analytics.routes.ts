import { Router } from 'express';
import { getDashboardBI } from './analytics.controller';

const router = Router();
router.get('/dashboard-bi', getDashboardBI);
export default router;