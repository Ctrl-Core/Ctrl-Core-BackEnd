import { Request, Response } from 'express';
import { dbPool } from '../../../../shared/database/connection';

export const getInitCatalogos = async (req: Request, res: Response) => {
  const tenantId = req.tenantId;

  try {
    // 1. Traer todos los catálogos activos (globales + propios del tenant)
    const [items]: any = await dbPool.execute(
      `SELECT id, tipo, codigo, nombre, valor, orden 
       FROM catalogo_items 
       WHERE activo = 1 AND (tenant_id IS NULL OR tenant_id = ?)
       ORDER BY tipo, orden ASC`,
      [tenantId]
    );

    // Agrupar por tipo (sector, tamano, nivel, medalla, area_asesoria, tipo_evento, formalizacion, brecha...)
    const catalogosAgrupados: Record<string, any[]> = {};
    for (const item of items) {
      if (!catalogosAgrupados[item.tipo]) {
        catalogosAgrupados[item.tipo] = [];
      }
      catalogosAgrupados[item.tipo].push(item);
    }

    // 2. Traer las misiones activas de la Academia
    const [misiones]: any = await dbPool.execute(
      `SELECT id, tipo, eje_id, nivel_minimo_id, titulo, pasos, xp_recompensa, duracion_min 
       FROM misiones 
       WHERE tenant_id = ? AND activa = 1`,
      [tenantId]
    );

    // 3. Traer la cola de duplicados candidatos (conflicts) generada por el ETL
    const [conflicts]: any = await dbPool.execute(
      `SELECT d.id, d.score, d.estado,
              ea.id AS empresa_a_id, ea.nit AS nit_a, ea.razon_social AS nombre_a,
              eb.id AS empresa_b_id, eb.nit AS nit_b, eb.razon_social AS nombre_b
       FROM duplicados_candidatos d
       JOIN empresas ea ON ea.tenant_id = d.tenant_id AND ea.id = d.empresa_a_id
       JOIN empresas eb ON eb.tenant_id = d.tenant_id AND eb.id = d.empresa_b_id
       WHERE d.tenant_id = ? AND d.estado = 'por_revisar'
       ORDER BY d.score DESC`,
      [tenantId]
    );

    res.json({
      success: true,
      tenant_id: tenantId,
      data: {
        catalogos: catalogosAgrupados,
        misiones,
        conflicts
      }
    });
  } catch (error) {
    console.error('[CatalogosController] Error:', error);
    res.status(500).json({ success: false, message: 'Error al cargar catálogos iniciales' });
  }
};