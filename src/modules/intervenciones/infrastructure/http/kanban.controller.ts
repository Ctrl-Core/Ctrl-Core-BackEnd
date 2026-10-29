import { Request, Response } from 'express';
import { dbPool } from '../../../../shared/database/connection';

export const getKanbanBoard = async (req: Request, res: Response) => {
  const tenantId = req.tenantId;

  try {
    const [rows]: any = await dbPool.execute(`
      SELECT p.id, p.titulo, p.estado, p.orden_kanban, p.progreso, p.fecha_limite,
             e.nombre_comercial AS empresa,
             IFNULL(c.nombre, 'General') AS eje
      FROM planes_accion p
      JOIN empresas e ON e.tenant_id = p.tenant_id AND e.id = p.empresa_id
      LEFT JOIN catalogo_items c ON c.id = p.eje_id
      WHERE p.tenant_id = ?
      ORDER BY p.estado, p.orden_kanban ASC
    `, [tenantId]);

    // Agrupamos por columnas para la vista Kanban
    const columnas: Record<string, any[]> = {
      pendiente: [],
      en_ejecucion: [],
      en_validacion_cde: [],
      completado_con_impacto: []
    };

    rows.forEach((tarea: any) => {
      if (columnas[tarea.estado]) {
        columnas[tarea.estado].push(tarea);
      }
    });

    res.json({
      success: true,
      tenant_id: tenantId,
      data: columnas
    });
  } catch (error) {
    console.error('[KanbanController] Error:', error);
    res.status(500).json({ success: false, message: 'Error al cargar el Kanban' });
  }
};

export const moveKanbanTask = async (req: Request, res: Response) => {
  const tenantId = req.tenantId;
  const taskId = req.params.id;
  const { nuevo_estado, nuevo_orden } = req.body;

  try {
    await dbPool.execute(`
      UPDATE planes_accion 
      SET estado = ?, orden_kanban = ?, updated_at = NOW(3)
      WHERE tenant_id = ? AND id = ?
    `, [nuevo_estado, nuevo_orden || 0, tenantId, taskId]);

    res.json({ success: true, message: 'Tarea reubicada con éxito' });
  } catch (error) {
    console.error('[KanbanController] Error al mover tarea:', error);
    res.status(500).json({ success: false, message: 'Error al mover tarea' });
  }
};