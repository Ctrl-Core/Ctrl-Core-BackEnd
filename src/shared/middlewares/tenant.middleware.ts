import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';

// Extendemos Request para incluir los claims del JWT
declare global {
  namespace Express {
    interface Request {
      tenantId: number;
      userId?: number;
      rol?: string;
      empresaId?: number;
    }
  }
}

export const tenantMiddleware = (req: Request, res: Response, next: NextFunction) => {
  const authHeader = req.headers.authorization;

  // 1. Verificación del JWT (Flujo de Producción)
  if (authHeader && authHeader.startsWith('Bearer ')) {
    const token = authHeader.split(' ')[1];
    try {
      const decoded = jwt.verify(token, process.env.JWT_SECRET || 'super_secreto_hackaton_unab_cde_2026') as any;
      
      req.tenantId = decoded.tenantId;
      req.userId = decoded.userId;
      req.rol = decoded.rol;
      req.empresaId = decoded.empresaId;
      
      return next();
    } catch (error) {
      return res.status(401).json({ success: false, message: 'Token inválido o expirado' });
    }
  }

  // 2. Fallback de Pruebas (Flujo de Desarrollo Rápido con Header manual)
  const headerTenantId = req.headers['x-tenant-id'];
  if (headerTenantId && !isNaN(Number(headerTenantId))) {
    req.tenantId = Number(headerTenantId);
    req.rol = 'super_admin_demo'; // Rol ficticio para pasar validaciones
    return next();
  }

  return res.status(401).json({ success: false, message: 'Acceso denegado: Se requiere autenticación JWT' });
};