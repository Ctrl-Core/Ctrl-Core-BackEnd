import { Router } from 'express';
import { login, registerDemo } from './auth.controller';

const router = Router();

router.post('/login', login);
router.post('/register-demo', registerDemo);

export default router;