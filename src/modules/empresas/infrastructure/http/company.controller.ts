import { Request, Response } from 'express';
import { dbPool } from '../../../../shared/database/connection';

export const getEmpresas = async (req: Request, res: Response) => {
  const tenantId = req.tenantId;

  try {
    // Ordenamos por empresa_id (columna real de la vista)
    const [rows]: any = await dbPool.execute(
      'SELECT * FROM vw_empresa_resumen WHERE tenant_id = ? ORDER BY empresa_id DESC LIMIT 50',
      [tenantId]
    );

    res.json({
      success: true,
      tenant_id: tenantId,
      total: rows.length,
      data: rows
    });
  } catch (error) {
    console.error('❌ [CompanyController] Error al listar empresas:', error);
    res.status(500).json({ success: false, message: 'Error al listar empresas' });
  }
};

export const getExpediente360 = async (req: Request, res: Response) => {
  const tenantId = req.tenantId;
  const empresaId = req.params.id;

  try {
    const startTime = performance.now();

    // 1. Resumen de la empresa
    const [empresaRows]: any = await dbPool.execute(
      'SELECT * FROM vw_empresa_resumen WHERE tenant_id = ? AND empresa_id = ?',
      [tenantId, empresaId]
    );

    if (empresaRows.length === 0) {
      return res.status(404).json({ success: false, message: 'Empresa no encontrada en este tenant' });
    }

    // 2. Línea de tiempo cronológica
    const [timelineRows]: any = await dbPool.execute(
      'SELECT * FROM vw_expediente_360 WHERE tenant_id = ? AND empresa_id = ? ORDER BY fecha DESC',
      [tenantId, empresaId]
    );

    // 3. Estado de gamificación
    const [gamificacionRows]: any = await dbPool.execute(
      'SELECT * FROM vw_empresa_gamificacion WHERE tenant_id = ? AND empresa_id = ?',
      [tenantId, empresaId]
    );

    const executionTime = Math.round(performance.now() - startTime);

    res.json({
      success: true,
      tenant_id: tenantId,
      execution_time_ms: executionTime,
      data: {
        perfil: empresaRows[0],
        gamificacion: gamificacionRows[0] || null,
        timeline: timelineRows
      }
    });
  } catch (error) {
    console.error('❌ [CompanyController] Error al obtener el Expediente 360:', error);
    res.status(500).json({ success: false, message: 'Error interno del servidor' });
  }
};