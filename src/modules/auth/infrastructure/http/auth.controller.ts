import { Request, Response } from 'express';
import { dbPool } from '../../../../shared/database/connection';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';

export const login = async (req: Request, res: Response) => {
  const { email, password } = req.body;

  try {
    // 1. Buscar al usuario
    const [rows]: any = await dbPool.execute(
      'SELECT id, tenant_id, password_hash, rol, empresa_id, activo FROM usuarios WHERE email = ?',
      [email]
    );

    if (rows.length === 0) {
      return res.status(401).json({ success: false, message: 'Credenciales incorrectas' });
    }

    const user = rows[0];

    if (!user.activo) {
      return res.status(403).json({ success: false, message: 'Tu cuenta está inactiva' });
    }

    // 2. Verificar contraseña
    const isValid = await bcrypt.compare(password, user.password_hash);
    if (!isValid) {
      return res.status(401).json({ success: false, message: 'Credenciales incorrectas' });
    }

    // 3. Generar JWT (Incluimos toda la data que nos pide la rúbrica)
    const token = jwt.sign(
      {
        userId: user.id,
        tenantId: user.tenant_id,
        rol: user.rol,
        empresaId: user.empresa_id
      },
      process.env.JWT_SECRET || 'super_secreto_hackaton_unab_cde_2026',
      { expiresIn: '12h' }
    );

    // 4. Actualizar el último acceso
    await dbPool.execute('UPDATE usuarios SET ultimo_login_at = NOW(3) WHERE id = ?', [user.id]);

    res.json({
      success: true,
      token,
      data: {
        id: user.id,
        tenant_id: user.tenant_id,
        rol: user.rol,
        empresa_id: user.empresa_id
      }
    });

  } catch (error) {
    console.error('[AuthController] Error en login:', error);
    res.status(500).json({ success: false, message: 'Error interno del servidor' });
  }
};

// Endpoint temporal para crear tu primer usuario rápido sin hacer INSERT manuales en BD
export const registerDemo = async (req: Request, res: Response) => {
  const { email, password, rol, tenant_id } = req.body;
  
  try {
    const salt = await bcrypt.genSalt(10);
    const hash = await bcrypt.hash(password, salt);

    const [result]: any = await dbPool.execute(
      `INSERT INTO usuarios (tenant_id, email, password_hash, nombre_mostrar, rol, activo) 
       VALUES (?, ?, ?, 'Demo User', ?, 1)`,
      [tenant_id || 1, email, hash, rol || 'admin_cde']
    );

    res.json({ success: true, message: 'Usuario demo creado con éxito', insertId: result.insertId });
  } catch (error) {
    console.error('Error al crear demo:', error);
    res.status(500).json({ success: false, message: 'Error al registrar' });
  }
};